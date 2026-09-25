#!/usr/bin/env bash
#
# reaper.sh — the TTL reaper on a Churner preview host (design spec §7).
#
# Fired hourly by `churner-preview-reaper.timer`. For every preview container
# whose `churner.preview.expires_at` label is in the past it:
#
#   1. removes the container,
#   2. drops the `preview_<pr>` database on the module's RDS instance,
#   3. removes the container's route from the reverse proxy and reloads it,
#   4. posts `destroyed` to Churner with the project's preview token.
#
# ## Why the container's labels are the source of truth
#
# The reaper runs on a host that may have been rebooted, re-bootstrapped, or
# had its disk replaced; the only durable record of what a preview IS lives on
# the container itself, written by the deploy workflow at `docker run`:
#
#   --label churner.preview=true
#   --label churner.preview.pr=<pr number>
#   --label churner.preview.sha=<head sha>
#   --label churner.preview.expires_at=<ISO-8601 UTC, e.g. 2026-09-07T12:00:00Z>
#   --label churner.preview.db=<database name, usually preview_<pr>>
#
# A side file would be a second record that can disagree with the first.
#
# ## Why the sweep is `docker ps -a`
#
# A crashed preview still owns its database, its route and its `building`
# state in Churner. Sweeping only RUNNING containers would leave all three
# behind forever — the exact leak the reaper exists to prevent — so an exited
# container past its TTL is reaped exactly like a live one.
#
# ## Why the fields are `|`-delimited and split by parameter expansion
#
# `read` with `IFS=$'\t'` COALESCES runs of the delimiter, so a container with
# an empty `sha` label shifts `expires_at` into `sha`'s place: the instant is
# then read as "unreadable", the container is skipped, and it is never reaped.
# Splitting a `|`-delimited line with `${x%%|*}` / `${x#*|}` preserves empty
# fields, and `|` cannot occur in any of the five values.
#
# ## Why expiry is a string comparison
#
# `expires_at` is UTC ISO-8601 with a `Z` suffix, and that format sorts
# lexicographically in the same order it sorts chronologically. Comparing
# strings avoids `date -d` (GNU) versus `date -r` (BSD) entirely, and a label
# that does NOT match the expected shape is skipped with a warning rather
# than parsed into an arbitrary instant — the failure mode of a misparse here
# is destroying a live preview. `LC_ALL=C` below makes the collation the
# byte order that reasoning assumes.
#
# ## Failure posture
#
# Every step of one preview is attempted independently and a failure is
# logged, never fatal: a database that is already gone must not leave the
# container running, and an unreachable tracker must not leave the host full.
# The container is removed FIRST — it is what holds the memory and the port —
# and the `destroyed` post is last, so a post that fails describes work that
# actually happened.
#
# Written for bash 3.2 so `bash -n` on a developer's macOS is CI's check.

set -euo pipefail

# Byte collation for the `\>` comparison below, and a stable `grep`/`date`.
export LC_ALL=C

CONFIG_FILE="${CHURNER_PREVIEW_CONFIG:-/etc/churner-preview/env}"

log() { echo "[churner-preview-reaper] $*"; }
warn() { echo "[churner-preview-reaper] $*" >&2; }

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

TRACKER_URL="${CHURNER_TRACKER_URL:-https://churner.ai}"
PROJECT_KEY="${CHURNER_PROJECT_KEY:-}"
DB_SECRET_NAME="${CHURNER_DB_SECRET_NAME:-}"
TOKEN_SECRET_NAME="${CHURNER_TOKEN_SECRET_NAME:-}"
ROUTES_DIR="${CHURNER_ROUTES_DIR:-/etc/caddy/preview-routes}"
AWS_REGION_NAME="${CHURNER_AWS_REGION:-}"

if [ -z "$PROJECT_KEY" ]; then
  warn "no CHURNER_PROJECT_KEY (is ${CONFIG_FILE} present?) — nothing to do"
  exit 0
fi

AWS_ARGS=""
if [ -n "$AWS_REGION_NAME" ]; then
  AWS_ARGS="--region $AWS_REGION_NAME"
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRY_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
# A pull-request number and a Postgres identifier. Both are written by the
# deploy workflow, which is a customer's own CI — but a label is the one input
# here that reaches a `DROP DATABASE`, a filesystem path and a JSON body, so
# it is checked rather than trusted.
PR_RE='^[0-9]+$'
DB_NAME_RE='^[A-Za-z0-9_]+$'
SHA_RE='^[0-9a-fA-F]{7,64}$'

# --- Secrets ----------------------------------------------------------------
#
# Read ONCE per sweep and never echoed. Both are optional in the sense that
# their absence degrades one step rather than the whole run: with no database
# secret the drop is skipped, with no token the post is skipped, and in both
# cases the container still goes away.

read_secret() {
  # shellcheck disable=SC2086
  aws $AWS_ARGS secretsmanager get-secret-value \
    --secret-id "$1" --query SecretString --output text 2>/dev/null || true
}

DB_SECRET_JSON=""
if [ -n "$DB_SECRET_NAME" ]; then
  DB_SECRET_JSON="$(read_secret "$DB_SECRET_NAME")"
  [ -n "$DB_SECRET_JSON" ] || warn "could not read ${DB_SECRET_NAME}; preview databases will not be dropped"
fi

PREVIEW_TOKEN=""
if [ -n "$TOKEN_SECRET_NAME" ]; then
  # Two places, in order: the secret the stack itself creates when it is
  # applied with a PreviewToken (`<name>-stack`), then the one a customer
  # created by hand under the original name. The stack-created one wins —
  # it is the token Churner last handed the stack.
  for candidate in "${TOKEN_SECRET_NAME}-stack" "$TOKEN_SECRET_NAME"; do
    PREVIEW_TOKEN="$(read_secret "$candidate")"
    # A plain-string secret is used as-is; a JSON one is expected to carry
    # `token`. Anything else leaves the post skipped and said so.
    case "$PREVIEW_TOKEN" in
      \{*) PREVIEW_TOKEN="$(printf '%s' "$PREVIEW_TOKEN" | jq -r '.token // empty' 2>/dev/null || true)" ;;
    esac
    if [ -n "$PREVIEW_TOKEN" ]; then break; fi
  done
  [ -n "$PREVIEW_TOKEN" ] || warn "could not read ${TOKEN_SECRET_NAME}-stack or ${TOKEN_SECRET_NAME}; destroyed events will not be posted"
fi

db_field() {
  [ -n "$DB_SECRET_JSON" ] || return 1
  printf '%s' "$DB_SECRET_JSON" | jq -r ".$1 // empty" 2>/dev/null
}

drop_database() {
  db_name="$1"
  [ -n "$db_name" ] || return 0
  [ -n "$DB_SECRET_JSON" ] || return 0

  # Checked here rather than at the call site so no path into `psql` can skip
  # it. A name is interpolated into DDL; nothing else about it is trusted.
  if ! printf '%s' "$db_name" | grep -Eq "$DB_NAME_RE"; then
    warn "refusing to drop database with an unacceptable name: ${db_name}"
    return 0
  fi

  db_host="$(db_field host || true)"
  db_port="$(db_field port || true)"
  db_user="$(db_field username || true)"
  db_pass="$(db_field password || true)"
  if [ -z "$db_host" ] || [ -z "$db_user" ] || [ -z "$db_pass" ]; then
    warn "database secret is missing host/username/password; not dropping ${db_name}"
    return 0
  fi
  [ -n "$db_port" ] || db_port=5432

  log "dropping database ${db_name}"
  # `WITH (FORCE)` terminates sessions the container may have left open;
  # without it a lingering connection makes the drop fail and the database
  # survives every sweep. Postgres 13+.
  PGPASSWORD="$db_pass" psql \
    --host "$db_host" --port "$db_port" --username "$db_user" \
    --dbname postgres --quiet --no-psqlrc \
    --command "DROP DATABASE IF EXISTS \"${db_name}\" WITH (FORCE);" \
    >/dev/null 2>&1 || warn "failed to drop database ${db_name}"
}

remove_route() {
  pr="$1"
  route_file="${ROUTES_DIR}/pr-${pr}.caddy"
  if [ -f "$route_file" ]; then
    log "removing route ${route_file}"
    rm -f "$route_file"
    # `systemctl reload` sends SIGUSR1 (see the unit bootstrap.sh installs),
    # which is how a `caddy run` with `admin off` re-reads its config.
    systemctl reload caddy >/dev/null 2>&1 || warn "caddy reload failed after removing pr-${pr}"
  fi
}

post_destroyed() {
  pr="$1"
  sha="$2"
  [ -n "$PREVIEW_TOKEN" ] || return 0
  if ! printf '%s' "$sha" | grep -Eq "$SHA_RE"; then
    warn "preview #${pr} carries no usable sha label; not posting destroyed"
    return 0
  fi

  endpoint="${TRACKER_URL%/}/api/projects/${PROJECT_KEY}/previews/events"
  body="{\"type\":\"destroyed\",\"pr\":\"${pr}\",\"sha\":\"${sha}\"}"
  # The Authorization header is fed to curl over STDIN (`-H @-`, curl >=
  # 7.55). `-H "Authorization: Bearer $PREVIEW_TOKEN"` would put the
  # credential in curl's argv, where `ps` shows it to every other process on
  # the customer's preview host — including the preview containers' own
  # workloads, which are the untrusted party this token is scoped away from.
  status="$(
    printf 'Authorization: Bearer %s\n' "$PREVIEW_TOKEN" \
      | curl --silent --show-error --location --max-time 30 \
          -o /dev/null -w '%{http_code}' \
          -X POST "$endpoint" \
          -H @- \
          -H 'Content-Type: application/json' \
          --data-binary "$body" 2>/dev/null || echo 0
  )"
  case "$status" in
    2*) log "posted destroyed for #${pr}" ;;
    *)  warn "posting destroyed for #${pr} returned HTTP ${status}" ;;
  esac
}

# --- Sweep ------------------------------------------------------------------

log "sweep at ${NOW}"

CONTAINERS="$(
  docker ps -a --filter 'label=churner.preview=true' \
    --format '{{.ID}}|{{.Label "churner.preview.pr"}}|{{.Label "churner.preview.sha"}}|{{.Label "churner.preview.expires_at"}}|{{.Label "churner.preview.db"}}' \
    2>/dev/null || true
)"

if [ -z "$CONTAINERS" ]; then
  log "no preview containers found"
  exit 0
fi

reaped=0
# A here-string would need bash 4 semantics nobody guarantees on a minimal
# image; a pipe would run the loop in a subshell and lose `reaped`.
while IFS= read -r line; do
  [ -n "$line" ] || continue

  # Split by parameter expansion, NOT by `read -d`: empty fields must keep
  # their position (see the header).
  cid="${line%%|*}"; rest="${line#*|}"
  pr="${rest%%|*}"; rest="${rest#*|}"
  sha="${rest%%|*}"; rest="${rest#*|}"
  expires_at="${rest%%|*}"; db_name="${rest#*|}"

  [ -n "$cid" ] || continue

  if ! printf '%s' "$pr" | grep -Eq "$PR_RE"; then
    warn "container ${cid} has no usable churner.preview.pr label (${pr:-none}); leaving it alone"
    continue
  fi

  if ! printf '%s' "$expires_at" | grep -Eq "$EXPIRY_RE"; then
    warn "preview #${pr} has an unreadable expires_at (${expires_at:-none}); leaving it alone"
    continue
  fi

  # Lexicographic on two `YYYY-MM-DDTHH:MM:SSZ` strings IS chronological.
  if [ "$expires_at" \> "$NOW" ]; then
    continue
  fi

  log "preview #${pr} expired at ${expires_at}; destroying"
  docker rm -f "$cid" >/dev/null 2>&1 || warn "failed to remove container ${cid} for #${pr}"
  drop_database "$db_name"
  remove_route "$pr"
  post_destroyed "$pr" "$sha"
  reaped=$(( reaped + 1 ))
done <<EOF
$CONTAINERS
EOF

log "sweep done; destroyed ${reaped} preview(s)"
