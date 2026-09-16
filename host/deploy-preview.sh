#!/usr/bin/env bash
#
# deploy-preview.sh — bring one pull-request preview up on a Churner preview
# host (design spec §7). Run BY SSM, as root, from `workflow.yml`.
#
# It is a FILE, fetched from a pinned tag and checksum-verified by the SSM
# command body, rather than a heredoc inside the workflow YAML: shell embedded
# in YAML can only be tested by re-parsing the YAML, and a test that re-derives
# the thing under test is testing its own parser. This file is executed by
# `shared/tests/preview-workflow.test.ts` against shimmed `docker` / `aws` /
# `psql` / `systemctl`.
#
# ## Why the secrets are read HERE and not on the runner
#
# The database master password and the application's own secrets are read on
# this host, with the host's instance profile, and exported into this
# process's environment. They never cross the GitHub runner, so they cannot
# reach a step output, a workflow log, or an argv on a machine a pull request
# controls. The deployer role can read them — its `<prefix>/*` grant is real —
# but a credential that never travels is one fewer place to leak from.
#
# ## Why `docker run -e NAME` and not `-e NAME=value`
#
# `-e NAME` with no `=` tells docker to take the VALUE from this process's
# environment. `-e NAME=value` puts the value in docker's argv, where `ps`
# shows it to every other process on the host. Both forms reach the container
# identically; only one of them is readable from outside.
#
# ## What the reaper needs from us
#
# The five `churner.preview.*` labels are the ONLY durable record of what a
# preview is — see `infrastructure/customer/preview-stack/host/reaper.sh`. A
# container missing `expires_at` is never reaped, and its database, its route
# and its `building` state in Churner survive forever.
#
# Written for bash 3.2 (no associative arrays, no `mapfile`, no `${x^^}`) so
# `bash -n` on a developer's macOS is the same check CI runs.

set -euo pipefail

export LC_ALL=C

log() { echo "[churner-preview-deploy] $*"; }
warn() { echo "[churner-preview-deploy] $*" >&2; }
die() { echo "[churner-preview-deploy] $*" >&2; exit 1; }

CONFIG_FILE="${CHURNER_PREVIEW_CONFIG:-/etc/churner-preview/env}"

# Captured BEFORE the config file is sourced: sourcing ASSIGNS, so a value
# the workflow sent would be silently overwritten by the host's own copy.
# The workflow's value wins because it comes from the same `secrets-prefix`
# input the caller configured this run with, and the file was written once at
# first boot — if the two disagree, the newer one is the one the operator
# just typed.
SECRETS_PREFIX_INPUT="${CHURNER_SECRETS_PREFIX:-}"

# Same reasoning, for the open-preview cap: a changed `PreviewMaxOpenPreviews`
# only reaches an EXISTING host through this workflow's own `max-open-previews`
# input (the module's own value is baked into UserData at first boot only —
# changing it either does nothing, under Terraform, or replaces the host,
# under CloudFormation). Captured before sourcing for the same reason.
MAX_OPEN_PREVIEWS_INPUT="${CHURNER_MAX_OPEN_PREVIEWS:-}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# --- Inputs -----------------------------------------------------------------
#
# The first five come from the SSM command body the workflow builds; the rest
# from the host's own config file, written once by `bootstrap.sh`. Nothing
# here is re-derived: the deploy and the reaper have to agree about where
# routes live and what the zone is called, and one file is how they do.

PR="${CHURNER_PR:-}"
SHA="${CHURNER_SHA:-}"
IMAGE_URI="${CHURNER_IMAGE_URI:-}"
TTL_HOURS="${CHURNER_TTL_HOURS:-48}"
SECRET_KEYS="${CHURNER_SECRET_KEYS:-}"
SEED_B64="${CHURNER_SEED_B64:-}"

PREVIEW_DOMAIN="${CHURNER_PREVIEW_DOMAIN:-}"
SECRETS_PREFIX="${SECRETS_PREFIX_INPUT:-${CHURNER_SECRETS_PREFIX:-}}"
DB_SECRET_NAME="${CHURNER_DB_SECRET_NAME:-}"
ROUTES_DIR="${CHURNER_ROUTES_DIR:-/etc/caddy/preview-routes}"
AWS_REGION_NAME="${CHURNER_AWS_REGION:-}"

# --- Validation -------------------------------------------------------------
#
# Every one of these reaches a shell word, a filesystem path, a Caddy config
# or a `CREATE DATABASE`. They arrive from a customer's own CI, which is
# trusted — and checked anyway, because "trusted" is a statement about intent
# and these are the inputs a mistake turns into a DDL statement. All of it
# happens BEFORE the first side effect, so a refusal leaves the host untouched.

PR_RE='^[0-9]+$'
SHA_RE='^[0-9a-fA-F]{7,64}$'
ENV_NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'
IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$'
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'

printf '%s' "$PR" | grep -Eq "$PR_RE" || die "CHURNER_PR must be digits (got '${PR}')"
printf '%s' "$SHA" | grep -Eq "$SHA_RE" || die "CHURNER_SHA must be 7-64 hex characters (got '${SHA}')"
printf '%s' "$IMAGE_URI" | grep -Eq "$IMAGE_RE" || die "CHURNER_IMAGE_URI is not a tagged image reference (got '${IMAGE_URI}')"
[ -n "$PREVIEW_DOMAIN" ] || die "CHURNER_PREVIEW_DOMAIN is required (is ${CONFIG_FILE} present?)"
[ -n "$DB_SECRET_NAME" ] || die "CHURNER_DB_SECRET_NAME is required (is ${CONFIG_FILE} present?)"
[ -n "$SECRETS_PREFIX" ] || die "CHURNER_SECRETS_PREFIX is required (is ${CONFIG_FILE} present?)"
printf '%s' "$SECRETS_PREFIX" | grep -Eq '^[A-Za-z0-9_/-]+$' \
  || die "CHURNER_SECRETS_PREFIX is not a usable Secrets Manager prefix (got '${SECRETS_PREFIX}')"
[ -d "$ROUTES_DIR" ] || die "routes directory ${ROUTES_DIR} does not exist — was the host bootstrapped?"

# Every requested key, checked before the FIRST one is fetched: a partial
# apply that dies halfway would leave the container running on some of its
# configuration, which is worse than not running at all.
for key in $SECRET_KEYS; do
  printf '%s' "$key" | grep -Eq "$ENV_NAME_RE" \
    || die "secret key '${key}' is not a usable environment-variable name"
done

DB_NAME="preview_${PR}"
# 20000 ports from 30000: two open pull requests collide only if their numbers
# differ by exactly 20000, and the same pull request always lands on the same
# port, which is what makes a redeploy idempotent.
HOST_PORT="${CHURNER_HOST_PORT:-$(( 30000 + PR % 20000 ))}"
CONTAINER="churner-preview-pr-${PR}"
HOSTNAME_FQDN="${PR}.${PREVIEW_DOMAIN}"

AWS_ARGS=""
if [ -n "$AWS_REGION_NAME" ]; then
  AWS_ARGS="--region $AWS_REGION_NAME"
fi

# --- Open-preview cap -------------------------------------------------------
#
# Counted HERE, in the validation block, so a refusal leaves the host exactly
# as it found it: no database, no image pull, no container, no route. The count
# excludes THIS pull request, because a redeploy replaces its own container
# (`docker rm -f` below) rather than taking a second slot — without that, the
# cap would lock out the very branch it had already admitted.
#
# The reaper is deliberately not involved: every removal it makes today is
# TTL-justified, and evicting the oldest preview to make room would report
# "destroyed" about one nobody's TTL had reached.
#
# The per-run value (this workflow call's OWN `max-open-previews` input, saved
# above as `MAX_OPEN_PREVIEWS_INPUT` before the config file could overwrite
# `CHURNER_MAX_OPEN_PREVIEWS`) wins over the bootstrap file's — that is what
# makes a cap change land on the NEXT PUSH rather than only a freshly-created
# host. An empty per-run value is what an un-upgraded caller workflow ALSO
# produces (GitHub Actions cannot distinguish "the caller omitted this input"
# from "the caller wants no cap" — both resolve to the schema default), so it
# defers to whatever the host was bootstrapped with instead of silently
# clearing an existing cap.
MAX_OPEN="${MAX_OPEN_PREVIEWS_INPUT:-${CHURNER_MAX_OPEN_PREVIEWS:-}}"
case "$MAX_OPEN" in
  '') ;;
  *[!0-9]*) die "churner-preview-cap-reached: CHURNER_MAX_OPEN_PREVIEWS is not a whole number (${MAX_OPEN})" ;;
  *)
    OPEN_PRS="$(
      docker ps -a --filter 'label=churner.preview=true' \
        --format '{{.Label "churner.preview.pr"}}' 2>/dev/null || true
    )"
    OPEN_COUNT=0
    for open_pr in $OPEN_PRS; do
      [ "$open_pr" = "$PR" ] && continue
      OPEN_COUNT=$(( OPEN_COUNT + 1 ))
    done
    if [ "$OPEN_COUNT" -ge "$MAX_OPEN" ]; then
      die "churner-preview-cap-reached: ${OPEN_COUNT} previews are already open and the limit is ${MAX_OPEN}. Close a pull request, or raise the limit on the Previews settings card."
    fi
    ;;
esac

# --- Expiry -----------------------------------------------------------------
#
# `YYYY-MM-DDTHH:MM:SSZ` exactly — the reaper compares the label as a STRING
# and skips anything else with a warning, so a preview whose label is a
# millisecond off its shape is never reaped at all. GNU and BSD `date` spell
# relative time differently and this file is executed by a test on macOS, so
# both are tried rather than assumed.

expires_at_in_hours() {
  hours="$1"
  if out="$(date -u -d "+${hours} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  if out="$(date -u -v "+${hours}H" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

EXPIRES_AT="$(expires_at_in_hours "$TTL_HOURS")" \
  || die "could not compute an expiry ${TTL_HOURS} hours from now"

# --- Secrets ----------------------------------------------------------------

# Returns 0 with the SecretString on stdout, NON-ZERO if the call itself
# failed. The distinction is the point: an IAM denial, a wrong region and a
# secret that does not exist all make the call fail, and treating those as
# "the secret is empty" is how a deploy comes up silently misconfigured —
# the container starts, the variable is unset, and the app fails somewhere
# else entirely. An empty `SecretString` is a different fact (someone stored
# an empty value) and is left for the caller to warn about.
#
# `--output json` + `jq`, not `--query … --output text`: text output strips a
# trailing newline and renders a literal `None` for a binary-only secret,
# either of which silently corrupts a value the container then runs on.
read_secret() {
  # shellcheck disable=SC2086
  if ! secret_response="$(aws $AWS_ARGS secretsmanager get-secret-value \
      --secret-id "$1" --output json 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$secret_response" | jq -r '.SecretString // empty'
}

if ! DB_SECRET_JSON="$(read_secret "$DB_SECRET_NAME")"; then
  die "reading ${DB_SECRET_NAME} failed — the host's role was denied, or the secret does not exist in this region"
fi
[ -n "$DB_SECRET_JSON" ] || die "${DB_SECRET_NAME} holds no SecretString; the preview database cannot be reached"

db_field() {
  printf '%s' "$DB_SECRET_JSON" | jq -r ".$1 // empty" 2>/dev/null
}

DB_HOST="$(db_field host || true)"
DB_PORT="$(db_field port || true)"
DB_USER="$(db_field username || true)"
DB_PASS="$(db_field password || true)"
[ -n "$DB_HOST" ] || die "${DB_SECRET_NAME} carries no host"
[ -n "$DB_USER" ] || die "${DB_SECRET_NAME} carries no username"
[ -n "$DB_PASS" ] || die "${DB_SECRET_NAME} carries no password"
[ -n "$DB_PORT" ] || DB_PORT=5432
printf '%s' "$DB_HOST" | grep -Eq "$HOST_RE" || die "${DB_SECRET_NAME} carries an unusable host"

# Percent-encoded: a generated password containing `@`, `/` or `#` would
# otherwise produce a URL whose authority is not the one we meant.
#
# Over STDIN, not `--arg`: `--arg s "$password"` puts the master password in
# jq's argv, which `ps` shows to every other process on a host that is
# already running pull-request-authored containers.
urlencode() { printf '%s' "$1" | jq -sRr '@uri'; }

DATABASE_URL="postgresql://$(urlencode "$DB_USER"):$(urlencode "$DB_PASS")@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export DATABASE_URL
export PORT="$HOST_PORT"

# `-e NAME` reads these from here. The loop exports; nothing echoes.
ENV_FLAGS="-e PORT -e DATABASE_URL"
for key in $SECRET_KEYS; do
  case "$key" in
    PORT|DATABASE_URL)
      warn "secret key ${key} would shadow a value this script derives; skipping it"
      continue
      ;;
  esac
  if ! value="$(read_secret "${SECRETS_PREFIX}/${key}")"; then
    die "reading ${SECRETS_PREFIX}/${key} failed — the host's role was denied, or the secret does not exist. It is named in .churner/preview/secrets, so starting without it would be a container running on configuration nobody asked for."
  fi
  if [ -z "$value" ]; then
    warn "secret ${SECRETS_PREFIX}/${key} holds an empty value; ${key} will not be set"
    continue
  fi
  export "${key}=${value}"
  ENV_FLAGS="${ENV_FLAGS} -e ${key}"
done
unset value

# --- Database ---------------------------------------------------------------
#
# Created ONLY when absent. A second push to the same pull request re-runs
# this whole script, and re-creating the database each time would wipe
# whatever a reviewer typed into the preview between the two pushes — which
# looks, from outside, exactly like the app losing data.

psql_admin() {
  PGPASSWORD="$DB_PASS" psql \
    --host "$DB_HOST" --port "$DB_PORT" --username "$DB_USER" \
    --dbname postgres --quiet --no-psqlrc "$@"
}

EXISTS="$(psql_admin --tuples-only --no-align --command \
  "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" 2>/dev/null || true)"

if [ -z "$EXISTS" ]; then
  log "creating database ${DB_NAME}"
  psql_admin --command "CREATE DATABASE \"${DB_NAME}\";" >/dev/null \
    || die "could not create database ${DB_NAME}"

  if [ -n "$SEED_B64" ]; then
    SEED_FILE="$(mktemp)"
    trap 'rm -f "$SEED_FILE"' EXIT
    printf '%s' "$SEED_B64" | base64 -d > "$SEED_FILE" 2>/dev/null \
      || printf '%s' "$SEED_B64" | base64 --decode > "$SEED_FILE"
    log "seeding ${DB_NAME} from .churner/preview/seed.sql"
    PGPASSWORD="$DB_PASS" psql \
      --host "$DB_HOST" --port "$DB_PORT" --username "$DB_USER" \
      --dbname "$DB_NAME" --quiet --no-psqlrc \
      --set ON_ERROR_STOP=1 --file "$SEED_FILE" >/dev/null \
      || die "seeding ${DB_NAME} failed"
  fi
else
  log "database ${DB_NAME} already exists; leaving its contents alone"
fi

# --- Image ------------------------------------------------------------------

REGISTRY="${IMAGE_URI%%/*}"
log "logging in to ${REGISTRY}"
# shellcheck disable=SC2086
aws $AWS_ARGS ecr get-login-password \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
  || die "could not authenticate to ${REGISTRY}"

log "pulling ${IMAGE_URI}"
docker pull "$IMAGE_URI" >/dev/null || die "could not pull ${IMAGE_URI}"

# --- Container --------------------------------------------------------------

log "replacing any previous container for #${PR}"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

log "starting ${CONTAINER} on 127.0.0.1:${HOST_PORT}, expiring ${EXPIRES_AT}"
#
# The hardening flags are not optional here. Every open pull request's
# container shares ONE small host with every other one and with the proxy, and
# the image is built from a branch anyone with push access authored. So:
#
#   --memory / --memory-swap  one runaway preview cannot OOM its neighbours
#                             (equal values disable swap, which otherwise
#                             lets a leak thrash the whole host's disk)
#   --pids-limit              a fork bomb costs one container, not the host
#   --cap-drop ALL            a preview needs no kernel capability; it binds
#                             a high port docker publishes for it
#   --security-opt no-new-privileges
#                             a setuid binary in the image cannot escalate
#   --read-only + tmpfs /tmp  the image's filesystem is not a place to keep
#                             anything: the container is destroyed at its TTL
#
# `--read-only` is the one an application can notice. A framework that writes
# a build cache or a socket outside /tmp needs a `--tmpfs` of its own, and the
# README says so — a preview that cannot start is a visible, diagnosable
# failure, which a writable root shared with eleven other branches is not.
# shellcheck disable=SC2086
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --publish "127.0.0.1:${HOST_PORT}:${HOST_PORT}" \
  --memory 1g \
  --memory-swap 1g \
  --pids-limit 512 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --label churner.preview=true \
  --label "churner.preview.pr=${PR}" \
  --label "churner.preview.sha=${SHA}" \
  --label "churner.preview.expires_at=${EXPIRES_AT}" \
  --label "churner.preview.db=${DB_NAME}" \
  $ENV_FLAGS \
  "$IMAGE_URI" >/dev/null \
  || die "could not start ${CONTAINER}"

# --- Route ------------------------------------------------------------------
#
# One file per open preview, in the directory the Caddyfile globs. Written
# atomically: a half-written file in an imported glob is a proxy that refuses
# to load its config at all, which would take down every OTHER preview too.

ROUTE_FILE="${ROUTES_DIR}/pr-${PR}.caddy"
ROUTE_TMP="${ROUTE_FILE}.tmp"
{
  printf '# %s — pull request #%s, expires %s\n' "$HOSTNAME_FQDN" "$PR" "$EXPIRES_AT"
  printf 'http://%s {\n' "$HOSTNAME_FQDN"
  printf '\treverse_proxy 127.0.0.1:%s\n' "$HOST_PORT"
  printf '}\n'
} > "$ROUTE_TMP"
mv "$ROUTE_TMP" "$ROUTE_FILE"

# `systemctl reload caddy` sends SIGUSR1 (the unit `bootstrap.sh` installs).
# `caddy reload` would POST to the admin API, which the Caddyfile turns off,
# and would silently do nothing — the preview would 404 with no error anywhere.
systemctl reload caddy || warn "caddy reload failed; the route for #${PR} may not be live yet"

log "preview #${PR} is registered at https://${HOSTNAME_FQDN}"
