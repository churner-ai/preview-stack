#!/usr/bin/env bash
#
# destroy-preview.sh — tear one pull-request preview down on a Churner preview
# host (design spec §7). Run BY SSM, as root, from `workflow.yml`'s teardown
# job when the pull request closes.
#
# The TTL reaper would eventually do the same work; this exists because
# "eventually" is up to `ttl_hours` after the pull request was merged, and a
# merged branch's preview holding a database and a port for two more days is
# the leak previews are supposed to avoid. Closing a pull request is an
# explicit end, so it gets an explicit teardown.
#
# ## Failure posture
#
# Every step is attempted independently and a failure is logged, never fatal.
# A database that is already gone must not leave the container running, and a
# missing route file must not leave the database behind. The one thing that
# IS fatal is a pull-request number this script cannot vouch for: it reaches a
# filesystem path and a `DROP DATABASE`, so a value that is not digits stops
# everything rather than being interpreted.
#
# Written for bash 3.2 so `bash -n` on a developer's macOS is CI's check.

set -euo pipefail

export LC_ALL=C

log() { echo "[churner-preview-destroy] $*"; }
warn() { echo "[churner-preview-destroy] $*" >&2; }
die() { echo "[churner-preview-destroy] $*" >&2; exit 1; }

CONFIG_FILE="${CHURNER_PREVIEW_CONFIG:-/etc/churner-preview/env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

PR="${CHURNER_PR:-}"
DB_SECRET_NAME="${CHURNER_DB_SECRET_NAME:-}"
ROUTES_DIR="${CHURNER_ROUTES_DIR:-/etc/caddy/preview-routes}"
AWS_REGION_NAME="${CHURNER_AWS_REGION:-}"

printf '%s' "$PR" | grep -Eq '^[0-9]+$' || die "CHURNER_PR must be digits (got '${PR}')"

DB_NAME="preview_${PR}"
CONTAINER="churner-preview-pr-${PR}"

AWS_ARGS=""
if [ -n "$AWS_REGION_NAME" ]; then
  AWS_ARGS="--region $AWS_REGION_NAME"
fi

# --- Container --------------------------------------------------------------
#
# First, as in the reaper: it is what holds the memory and the port, and every
# later step is recoverable while a container left running is not.

log "removing ${CONTAINER}"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || log "no container ${CONTAINER} to remove"

# --- Database ---------------------------------------------------------------

DB_SECRET_JSON=""
if [ -n "$DB_SECRET_NAME" ]; then
  # `--output json` + `jq`, not `--query … --output text`: text output strips
  # a trailing newline and prints a literal `None` for a secret with no
  # string value, and a password mangled either way makes the drop fail in a
  # way that reads as "the database is gone" when it is not.
  #
  # A failed CALL is warned about rather than fatal, unlike the deploy path:
  # the container is already removed by this point, and dying here would
  # leave the route file behind too. The TTL reaper is the backstop.
  # shellcheck disable=SC2086
  if secret_response="$(aws $AWS_ARGS secretsmanager get-secret-value \
      --secret-id "$DB_SECRET_NAME" --output json 2>/dev/null)"; then
    DB_SECRET_JSON="$(printf '%s' "$secret_response" | jq -r '.SecretString // empty')"
  else
    warn "reading ${DB_SECRET_NAME} failed — denied, or absent in this region"
  fi
fi

if [ -n "$DB_SECRET_JSON" ]; then
  db_field() { printf '%s' "$DB_SECRET_JSON" | jq -r ".$1 // empty" 2>/dev/null; }
  DB_HOST="$(db_field host || true)"
  DB_PORT="$(db_field port || true)"
  DB_USER="$(db_field username || true)"
  DB_PASS="$(db_field password || true)"
  [ -n "$DB_PORT" ] || DB_PORT=5432
  if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]; then
    log "dropping database ${DB_NAME}"
    # `WITH (FORCE)` terminates sessions the container may have left open;
    # without it a lingering connection makes the drop fail and the database
    # survives. The password goes to `psql` in PGPASSWORD, never on argv.
    PGPASSWORD="$DB_PASS" psql \
      --host "$DB_HOST" --port "$DB_PORT" --username "$DB_USER" \
      --dbname postgres --quiet --no-psqlrc \
      --command "DROP DATABASE IF EXISTS \"${DB_NAME}\" WITH (FORCE);" \
      >/dev/null 2>&1 || warn "failed to drop database ${DB_NAME}"
  else
    warn "${DB_SECRET_NAME} is missing host/username/password; not dropping ${DB_NAME}"
  fi
else
  warn "could not read a database secret; not dropping ${DB_NAME}"
fi

# --- Route ------------------------------------------------------------------

ROUTE_FILE="${ROUTES_DIR}/pr-${PR}.caddy"
if [ -f "$ROUTE_FILE" ]; then
  log "removing route ${ROUTE_FILE}"
  rm -f "$ROUTE_FILE"
  # SIGUSR1 via the unit's ExecReload — `caddy reload` would POST to an admin
  # API the Caddyfile turns off, and the destroyed preview would keep serving.
  systemctl reload caddy || warn "caddy reload failed after removing pr-${PR}"
else
  log "no route file for #${PR}"
fi

log "preview #${PR} is gone"
