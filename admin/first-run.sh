#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# admin/first-run.sh
#
# Purpose:
#   Bootstrap ARCS on a fresh install (or perform a controlled warm start).
#
# Author: Edward Moss - N0LJD
#
# Key rules:
#   - Secrets rotation happens ONLY with --coldstart + (--rotate-secrets or --force).
#   - Warm starts must NOT rewrite secrets if volumes are preserved.
#
# High-level flow (happy path):
#   1) Optional coldstart wipe (down + remove named volumes)
#   2) Optional secrets rotation (only if coldstart)
#   3) Start MariaDB only; wait healthy
#   4) Run importer (schema + data + views)
#   5) Ensure DB user `xml_api` exists with least privilege (SELECT on uls.v_callbook only)
#   6) Start xml-api + web-ui
#   7) Run canonical sanity checks (admin/sanity-check.sh)
#   8) Completion information saved in admin/.bootstrap_complete
# -----------------------------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# -----------------------------
# Defaults / flags
# -----------------------------
FORCE="no"
COLDSTART="no"
ROTATE_SECRETS="no"
CI="no"
LOG_SANITY="no"
STATUS_ONLY="no"

# Heartbeat interval seconds (dots).
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-1}"

# -----------------------------
# Logging helpers
# -----------------------------
log()  { printf '[first-run] %s\n' "$*"; }
warn() { printf '[first-run] WARN: %s\n' "$*" >&2; }
die()  { printf '[first-run] ERROR: %s\n' "$*" >&2; exit 2; }

need_file() {
  local f="$1"
  [ -f "$f" ] || die "Missing required file: $f"
}

usage() {
  # Avoid heredocs here to prevent paste/clipboard issues from corrupting delimiters.
  printf '%s\n' \
'Usage: ./admin/first-run.sh [--coldstart] [--rotate-secrets] [--force] [--ci] [--log-sanity] [--status]' \
'' \
'Flags:' \
'  --coldstart        Stop stack and wipe named volumes (fresh install workflow)' \
'  --rotate-secrets   Generate new local secrets (allowed only with --coldstart)' \
'  --force            Non-interactive; implies --rotate-secrets (still requires --coldstart)' \
'  --ci               Non-interactive style output; also enables sanity-check logging' \
'  --log-sanity       Enable sanity-check logging even when not using --ci' \
'  --status           Print bootstrap metadata and exit' \
'' \
'Env:' \
'  HEARTBEAT_INTERVAL=1   Seconds between progress dots for long steps'
}

# -----------------------------
# Timing helpers (total only)
# -----------------------------
SCRIPT_START_EPOCH="$(date +%s)"

fmt_seconds() {
  local s="$1"
  local h=$((s / 3600))
  local m=$(((s % 3600) / 60))
  local r=$((s % 60))
  if (( h > 0 )); then
    printf '%d:%02d:%02d' "$h" "$m" "$r"
  else
    printf '%02d:%02d' "$m" "$r"
  fi
}

# -----------------------------
# Heartbeat helpers
# -----------------------------
HEARTBEAT_PID=""

start_heartbeat() {
  # Prints a dot every HEARTBEAT_INTERVAL seconds on the same line.
  # Used to show the script is still processing.
  #
  # In CI mode, we suppress heartbeat dots to keep logs clean.
  local msg="${1:-Processing}"
  stop_heartbeat || true

  if [ "${CI:-no}" = "yes" ]; then
    return 0
  fi

  printf '[first-run] %s ' "$msg"
  (
    while true; do
      printf '.'
      sleep "${HEARTBEAT_INTERVAL}"
    done
  ) &
  HEARTBEAT_PID="$!"
}

stop_heartbeat() {
  # Stop the heartbeat and ensure subsequent output starts on a fresh line.
  if [ -n "${HEARTBEAT_PID:-}" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
    printf '\n'
  fi
}

cleanup() {
  stop_heartbeat || true
}
trap cleanup EXIT

# -----------------------------
# Arg parsing
# -----------------------------
for arg in "$@"; do
  case "$arg" in
    --force) FORCE="yes"; ROTATE_SECRETS="yes" ;;
    --coldstart) COLDSTART="yes" ;;
    --rotate-secrets) ROTATE_SECRETS="yes" ;;
    --ci) CI="yes" ;;
    --log-sanity) LOG_SANITY="yes" ;;
    --status) STATUS_ONLY="yes" ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) die "Unknown arg: $arg" ;;
  esac
done

# Guard: rotate secrets ONLY on coldstart
if [ "$ROTATE_SECRETS" = "yes" ] && [ "$COLDSTART" != "yes" ]; then
  die "Refusing to rotate secrets without --coldstart. Use: ./admin/first-run.sh --coldstart --rotate-secrets (or --force)."
fi

# ---------------------------------------------------------------------------
# First-time install convenience:
# If secrets are missing, assume a brand-new install and:
#   - enable --coldstart (safe even if nothing exists yet)
#   - enable --rotate-secrets (generate secrets)
#
# This does NOT rotate existing secrets; it only triggers when secrets are absent.
# ---------------------------------------------------------------------------
if [ "$COLDSTART" != "yes" ] && [ "$ROTATE_SECRETS" != "yes" ]; then
  if [ ! -f "$ROOT_DIR/secrets/mariadb_root_password.txt" ] \
  || [ ! -f "$ROOT_DIR/secrets/mariadb_user_password.txt" ] \
  || [ ! -f "$ROOT_DIR/secrets/xml_api_password.txt" ]; then
    log "Secrets not found (first run). Assuming fresh install: enabling --coldstart and generating secrets."
    COLDSTART="yes"
    ROTATE_SECRETS="yes"
  fi
fi

if [ "$ROTATE_SECRETS" = "yes" ] && [ "$COLDSTART" != "yes" ]; then
  die "Internal flag state invalid: rotate-secrets requires coldstart."
fi

# ---------------------------------------------------------------------------
# Log resolved execution mode (after implicit first-run detection)
# ---------------------------------------------------------------------------

# A "fresh install" is defined as: no prior successful bootstrap recorded.
FRESH_INSTALL="no"
if [ ! -f "$ROOT_DIR/admin/.bootstrap_complete" ]; then
  FRESH_INSTALL="yes"
fi

log "Mode resolved: fresh-install=${FRESH_INSTALL} coldstart=${COLDSTART} rotate-secrets=${ROTATE_SECRETS} ci=${CI}"

# Inform the user early if this is a coldstart (fresh install).
if [ "$COLDSTART" = "yes" ]; then
  printf '\n[first-run] NOTE: A coldstart (fresh install) may take up to 10 minutes to complete.\n\n'
fi

# -----------------------------
# Paths / service names
# -----------------------------
SECRETS_DIR="$ROOT_DIR/secrets"
MDB_ROOT_PW_FILE="$SECRETS_DIR/mariadb_root_password.txt"
MDB_USER_PW_FILE="$SECRETS_DIR/mariadb_user_password.txt"   # reserved (uls), not directly used here
XML_API_PW_FILE="$SECRETS_DIR/xml_api_password.txt"

# Compose/service/container names
SVC_DB="uls-mariadb"
SVC_IMPORTER="uls-importer"
SVC_API="xml-api"
SVC_UI="web-ui"

# Container name used by docker inspect for health (matches compose container_name)
CTR_DB="arcs-uls-mariadb"

print_status() {
  local f="$ROOT_DIR/admin/.bootstrap_complete"

  log "Status requested (--status)."
  if [ -f "$f" ]; then
    log "Bootstrap metadata: admin/.bootstrap_complete"
    sed 's/^/[first-run]   /' "$f"
  else
    warn "No bootstrap metadata found at admin/.bootstrap_complete"
    warn "Run: ./admin/first-run.sh (or ./admin/first-run.sh --coldstart) to perform bootstrap."
  fi
}

# Exit early for status mode (no Docker actions)
if [ "$STATUS_ONLY" = "yes" ]; then
  print_status
  exit 0
fi

# -----------------------------
# Core helpers
# -----------------------------
random_pw() {
  # Generate a 32-char password with conservative, URL-safe-ish characters.
  tr -dc 'A-Za-z0-9_@#%+=.,:-' </dev/urandom | head -c 32
}

rotate_secrets() {
  # Coldstart-only operation: generate fresh local secrets.
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
  # Coldstart wipe: stop containers and remove named volumes to force a fresh DB/cache.
  log "Coldstart requested: stopping stack + wiping named volumes..."
  docker compose down --remove-orphans || true

  docker volume rm arcs_uls_db_data 2>/dev/null || true
  docker volume rm arcs_uls_cache   2>/dev/null || true

  log "Coldstart wipe complete."
}

wait_mariadb_healthy() {
  # Wait until the MariaDB container reports healthy via Docker healthcheck.
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

run_importer() {
  # Importer is the long-running step. We:
  #   - capture importer output to a logfile
  #   - show a heartbeat on-screen so users know we're still working
  #   - on failure, print last lines from the log for fast diagnosis
  log "Running importer (schema + data + views; this may take a while)..."

  mkdir -p "$ROOT_DIR/logs"
  local log_file="$ROOT_DIR/logs/importer_$(date +%Y%m%d_%H%M%S).log"
  log "Importer output: $log_file"

  start_heartbeat "Importer running (still processing)"
  set +e
  docker compose run --rm "$SVC_IMPORTER" >"$log_file" 2>&1
  local rc=$?
  set -e
  stop_heartbeat

  # Phase separator: ensures the next log entry is visually distinct after dots.
  printf '\n'

  if [ "$rc" -ne 0 ]; then
    log "Importer failed (exit=$rc). Last 50 lines:"
    tail -n 50 "$log_file" | sed 's/^/[first-run]   /'
    die "Importer failed. See full log: $log_file"
  fi

  log "Importer complete."
  log "Housekeeping..."
}

ensure_xml_api_user() {
  # Enforce least-privilege runtime credentials.
  # Based on code scan, xml-api reads ONLY from: uls.v_callbook
  need_file "$MDB_ROOT_PW_FILE"
  need_file "$XML_API_PW_FILE"

  local rootpw xmlpw
  rootpw="$(cat "$MDB_ROOT_PW_FILE")"
  xmlpw="$(cat "$XML_API_PW_FILE")"

  log "Ensuring DB user 'xml_api' exists, password is synchronized, and privileges are view-only (uls.v_callbook)..."

  # Create/sync user credentials (idempotent).
  docker compose exec -T "$SVC_DB" \
    mariadb -uroot -p"$rootpw" -e "
      CREATE USER IF NOT EXISTS 'xml_api'@'%' IDENTIFIED BY '${xmlpw}';
      ALTER USER 'xml_api'@'%' IDENTIFIED BY '${xmlpw}';
      FLUSH PRIVILEGES;
    " >/dev/null

  # Enforce least privilege: revoke everything, then grant SELECT only on the view.
  docker compose exec -T "$SVC_DB" \
    mariadb -uroot -p"$rootpw" -e "
      REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'xml_api'@'%';
      GRANT SELECT ON \`uls\`.\`v_callbook\` TO 'xml_api'@'%';
      FLUSH PRIVILEGES;
    " >/dev/null

  # Confirm required view exists (import/schema completeness check).
  if ! docker compose exec -T "$SVC_DB" \
      mariadb -uroot -p"$rootpw" -N -e "USE \`uls\`; SHOW FULL TABLES LIKE 'v_callbook';" \
      | grep -qi 'v_callbook'; then
    die "Required view 'uls.v_callbook' was not found. Import/schema may be incomplete."
  fi

  # On interactive runs, show grants for transparency.
  if [ "${CI:-no}" != "yes" ]; then
    log "xml_api grants now set to:"
    docker compose exec -T "$SVC_DB" \
      mariadb -uroot -p"$rootpw" -N -e "SHOW GRANTS FOR 'xml_api'@'%';" \
      | sed 's/^/[first-run]   /'
  fi

  log "DB user 'xml_api' OK (restricted to SELECT on uls.v_callbook)."
}

start_services() {
  # Bring up the DB first, wait for health, run importer, enforce grants, then start runtime services.
  log "Starting MariaDB..."
  docker compose up -d "$SVC_DB"

  wait_mariadb_healthy 90 2

  # Importer creates schema + views (including v_callbook).
  run_importer

  # Enforce least privilege AFTER views exist.
  ensure_xml_api_user

  log "Starting runtime services (xml-api + web-ui)..."
  docker compose up -d "$SVC_API" "$SVC_UI"
}

run_sanity_check() {
  # Execute canonical sanity checks (can be run manually too).
  local sanity="$ROOT_DIR/admin/sanity-check.sh"
  local log_flag=""

  if [ "${CI:-no}" = "yes" ] || [ "${LOG_SANITY:-no}" = "yes" ]; then
    log_flag="--log"
  fi

  if [ -x "$sanity" ]; then
    log "Running sanity checks: admin/sanity-check.sh ${log_flag}"
    echo
    "$sanity" W1AW ${log_flag} || die "sanity-check.sh reported failure"
  else
    warn "admin/sanity-check.sh not found or not executable; skipping."
  fi
}

# -----------------------------
# Main
# -----------------------------

# Banner: make logs self-describing and easy to correlate in pasted output.
log "ARCS first-run starting..."
log "Project root: $ROOT_DIR"

# Coldstart: stop and wipe state so MariaDB re-initializes cleanly.
if [ "$COLDSTART" = "yes" ]; then
  coldstart_wipe
fi

# Secrets:
# - If rotating (coldstart only), write new secrets.
# - Otherwise, require existing secrets and be explicit that we're using them.
if [ "$ROTATE_SECRETS" = "yes" ]; then
  rotate_secrets
else
  need_file "$MDB_ROOT_PW_FILE"
  need_file "$MDB_USER_PW_FILE"
  need_file "$XML_API_PW_FILE"
  log "Using existing secrets (no rotation):"
  log "  $MDB_ROOT_PW_FILE"
  log "  $MDB_USER_PW_FILE"
  log "  $XML_API_PW_FILE"
fi

# Orchestration: DB -> importer -> privilege enforcement -> runtime -> verification.
start_services
run_sanity_check

TOTAL_END_EPOCH="$(date +%s)"
TOTAL_ELAPSED=$((TOTAL_END_EPOCH - SCRIPT_START_EPOCH))
log "Done. Total elapsed $(fmt_seconds "$TOTAL_ELAPSED")."

# ---------------------------------------------------------------------------
# Record successful bootstrap completion metadata
# ---------------------------------------------------------------------------
BOOTSTRAP_MARKER="$ROOT_DIR/admin/.bootstrap_complete"

{
  echo "bootstrap_completed_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "elapsed_seconds=${TOTAL_ELAPSED}"
  echo "elapsed_human=$(fmt_seconds "$TOTAL_ELAPSED")"
  echo "fresh_install=${FRESH_INSTALL:-unknown}"
  echo "coldstart=${COLDSTART}"
  echo "rotate_secrets=${ROTATE_SECRETS}"
  echo "ci_mode=${CI}"
} > "$BOOTSTRAP_MARKER"

log "Bootstrap metadata written to admin/.bootstrap_complete"
