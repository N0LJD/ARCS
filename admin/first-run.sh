#!/usr/bin/env bash
set -euo pipefail

# admin/first-run.sh
# ------------------
# First-run bootstrap for ARCS.
#
# Key rules:
#   - Warm starts should NOT rewrite secrets if DB volumes are preserved.
#   - Secrets rotation happens ONLY with --coldstart + (--rotate-secrets or --force).
#
# What it does (happy path):
#   1) Optional coldstart wipe (down + remove named volumes)
#   2) Optional secrets rotation (only if coldstart)
#   3) Start MariaDB only; wait healthy
#   4) Ensure DB user `xml_api` exists and has SELECT on uls.*
#   5) Run importer (loads schema + data)
#   6) Start xml-api + web-ui
#   7) Crash-loop check (restart-count observation)
#   8) Sanity curls (timed retry; warnings only)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# -----------------------------
# Defaults / flags
# -----------------------------
FORCE="no"
COLDSTART="no"
ROTATE_SECRETS="no"
CI="no"

usage() {
  cat <<'USAGE'
Usage: ./admin/first-run.sh [--coldstart] [--rotate-secrets] [--force] [--ci]

Default behavior (warm start):
  - does NOT rotate secrets
  - starts MariaDB, waits healthy
  - ensures xml_api DB user permissions
  - runs importer (schema + data)
  - starts xml-api + web-ui
  - verifies containers are not crash-looping
  - runs timed sanity curls (warnings only)

--coldstart:
  - docker compose down --remove-orphans
  - removes named volumes arcs_uls_db_data + arcs_uls_cache (wipe DB/cache)

--rotate-secrets:
  - generates new secrets files in ./secrets/
  - GUARD: only allowed with --coldstart

--force:
  - non-interactive
  - implies --rotate-secrets
  - still requires --coldstart to rotate secrets

--ci:
  - non-interactive style output (still runs same bootstrap)
USAGE
}

log() { printf '[first-run] %s\n' "$*"; }
warn() { printf '[first-run] WARN: %s\n' "$*" >&2; }
die() { printf '[first-run] ERROR: %s\n' "$*" >&2; exit 2; }

need_file() {
  local f="$1"
  [ -f "$f" ] || die "Missing required file: $f"
}

# -----------------------------
# Arg parsing (SAFE with no args)
# -----------------------------
for arg in "$@"; do
  case "$arg" in
    --force) FORCE="yes"; ROTATE_SECRETS="yes" ;;
    --coldstart) COLDSTART="yes" ;;
    --rotate-secrets) ROTATE_SECRETS="yes" ;;
    --ci) CI="yes" ;;
    -h|--help) usage; exit 0 ;;
    "") ;; # ignore empty args defensively
    *) die "Unknown arg: $arg" ;;
  esac
done

# Enforce: rotate secrets ONLY on coldstart
if [ "$ROTATE_SECRETS" = "yes" ] && [ "$COLDSTART" != "yes" ]; then
  die "Refusing to rotate secrets without --coldstart. Use: ./admin/first-run.sh --coldstart --rotate-secrets (or --force)."
fi

# -----------------------------
# Paths
# -----------------------------
SECRETS_DIR="$ROOT_DIR/secrets"
MDB_ROOT_PW_FILE="$SECRETS_DIR/mariadb_root_password.txt"
MDB_USER_PW_FILE="$SECRETS_DIR/mariadb_user_password.txt"   # uls
XML_API_PW_FILE="$SECRETS_DIR/xml_api_password.txt"         # xml_api

# Compose/service/container names (normalize here)
SVC_DB="uls-mariadb"
SVC_IMPORTER="uls-importer"
SVC_API="xml-api"
SVC_UI="web-ui"

CTR_DB="arcs-uls-mariadb"
CTR_API="arcs-xml-api"
CTR_UI="arcs-web-ui"

# -----------------------------
# Helpers
# -----------------------------
random_pw() {
  # 32 chars, URL-safe-ish
  tr -dc 'A-Za-z0-9_@#%+=.,:-' </dev/urandom | head -c 32
}

rotate_secrets() {
  log "Rotating secrets (coldstart only)..."
  mkdir -p "$SECRETS_DIR"
  umask 077

  printf '%s\n' "$(random_pw)" > "$MDB_ROOT_PW_FILE"
  printf '%s\n' "$(random_pw)" > "$MDB_USER_PW_FILE"
  printf '%s\n' "$(random_pw)" > "$XML_API_PW_FILE"

  chmod 600 "$MDB_ROOT_PW_FILE" "$MDB_USER_PW_FILE" "$XML_API_PW_FILE" || true
  log "Secrets written:"
  log "  $MDB_ROOT_PW_FILE"
  log "  $MDB_USER_PW_FILE"
  log "  $XML_API_PW_FILE"
}

coldstart_wipe() {
  log "Coldstart requested: stopping stack + wiping named volumes..."
  docker compose down --remove-orphans || true

  # Named volumes (match docker-compose.yml names)
  docker volume rm arcs_uls_db_data 2>/dev/null || true
  docker volume rm arcs_uls_cache   2>/dev/null || true

  log "Coldstart wipe complete."
}

container_exists() {
  local c="$1"
  docker inspect "$c" >/dev/null 2>&1
}

restart_count() {
  local c="$1"
  docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo "0"
}

container_state() {
  local c="$1"
  docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "unknown"
}

wait_mariadb_healthy() {
  local tries="${1:-90}"
  local delay="${2:-2}"

  log "Waiting for MariaDB health (tries=$tries delay=${delay}s)..."
  for _i in $(seq 1 "$tries"); do
    if docker inspect --format '{{.State.Health.Status}}' "$CTR_DB" 2>/dev/null | grep -qx healthy; then
      log "MariaDB is healthy."
      return 0
    fi
    sleep "$delay"
  done
  die "MariaDB did not become healthy in time."
}

ensure_xml_api_user() {
  # Creates/ensures user exists and has SELECT on uls.*
  need_file "$MDB_ROOT_PW_FILE"
  need_file "$XML_API_PW_FILE"

  local rootpw xmlpw
  rootpw="$(cat "$MDB_ROOT_PW_FILE")"
  xmlpw="$(cat "$XML_API_PW_FILE")"

  log "Ensuring DB user 'xml_api' exists and password is synchronized..."

  # Note: ALTER USER keeps DB aligned with secret file if it ever changes on coldstart.
  docker compose exec -T "$SVC_DB" \
    mariadb -uroot -p"$rootpw" -e "
      CREATE USER IF NOT EXISTS 'xml_api'@'%' IDENTIFIED BY '${xmlpw}';
      ALTER USER 'xml_api'@'%' IDENTIFIED BY '${xmlpw}';
      GRANT SELECT ON uls.* TO 'xml_api'@'%';
      FLUSH PRIVILEGES;
    " >/dev/null

  log "DB user 'xml_api' OK."
}

run_importer() {
  log "Running importer (this may take a while)..."
  docker compose run --rm "$SVC_IMPORTER"
  log "Importer complete."
}

wait_http_ok() {
  # wait_http_ok URL tries delay_seconds
  local url="$1"
  local tries="${2:-30}"
  local delay="${3:-1}"

  for _i in $(seq 1 "$tries"); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

curl_sanity() {
  # curl_sanity LABEL URL tries delay
  local label="$1"
  local url="$2"
  local tries="${3:-25}"
  local delay="${4:-1}"

  log "Sanity: $label -> $url (tries=$tries delay=${delay}s)"
  if wait_http_ok "$url" "$tries" "$delay"; then
    log "Sanity OK: $label"
  else
    warn "Sanity FAILED (timed out): $label -> $url"
  fi
}

check_crash_loop() {
  # Observes restart count for a container over a short interval.
  # If restart count increases, we treat as crash-loop/instability.
  #
  # check_crash_loop CONTAINER LABEL seconds poll_interval
  local c="$1"
  local label="$2"
  local seconds="${3:-10}"
  local poll="${4:-2}"

  if ! container_exists "$c"; then
    warn "Crash-loop check skipped: container not found: $c ($label)"
    return 0
  fi

  local state0 rc0 state1 rc1
  state0="$(container_state "$c")"
  rc0="$(restart_count "$c")"

  log "Crash-loop check: $label ($c) initial state=$state0 restarts=$rc0; observing ${seconds}s..."
  local elapsed=0
  while [ "$elapsed" -lt "$seconds" ]; do
    sleep "$poll"
    elapsed=$((elapsed + poll))
  done

  state1="$(container_state "$c")"
  rc1="$(restart_count "$c")"

  # If restarts increased during observation, flag it.
  if [ "$rc1" -gt "$rc0" ]; then
    warn "Crash-loop suspected: $label ($c) restart count increased ${rc0} -> ${rc1} over ${seconds}s (state now: $state1)"
    warn "Suggested next step: docker compose logs --tail=200 $SVC_API (and/or $SVC_UI)"
    return 1
  fi

  # If container isn't running, also flag.
  if [ "$state1" != "running" ]; then
    warn "Container not running: $label ($c) state=$state1 restarts=$rc1"
    return 1
  fi

  log "Crash-loop check OK: $label ($c) state=$state1 restarts=$rc1"
  return 0
}

start_services() {
  log "Starting MariaDB..."
  docker compose up -d "$SVC_DB"

  wait_mariadb_healthy 90 2
  ensure_xml_api_user
  run_importer

  log "Starting xml-api + web-ui..."
  docker compose up -d "$SVC_API" "$SVC_UI"
}

post_start_validation() {
  # Give the services a moment to bind ports before we start observing restarts.
  sleep 2

  # First: wait for API health to become available (this reduces false-positive curl noise)
  if wait_http_ok "http://127.0.0.1:8080/health" 30 1; then
    log "API health is responding."
  else
    warn "API health did not respond within expected time."
  fi

  # Crash-loop checks (non-fatal, but loud)
  # - API is the most important (both UI + direct access depend on it)
  # - UI next (proxy)
  check_crash_loop "$CTR_API" "xml-api" 12 2 || true
  check_crash_loop "$CTR_UI"  "web-ui"  12 2 || true
}

sanity() {
  log "Sanity checks (timed retries; warnings only):"
  curl_sanity "API /health"      "http://127.0.0.1:8080/health" 30 1
  curl_sanity "API XML (W1AW)"   "http://127.0.0.1:8080/xml.php?callsign=W1AW" 30 1
  curl_sanity "Web UI /api/health" "http://127.0.0.1:8081/api/health" 30 1
}

# -----------------------------
# Main
# -----------------------------
if [ "$COLDSTART" = "yes" ]; then
  coldstart_wipe
fi

if [ "$ROTATE_SECRETS" = "yes" ]; then
  rotate_secrets
else
  # Ensure secrets exist for normal operation
  need_file "$MDB_ROOT_PW_FILE"
  need_file "$MDB_USER_PW_FILE"
  need_file "$XML_API_PW_FILE"
fi

start_services
post_start_validation
sanity

log "Done."
