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
# Importer behavior:
#   - Importer is ALWAYS run with --lock --skip-if-unchanged.
#   - This makes bootstrap idempotent and safe for repeated execution.
#   - To force a re-import, run the importer container manually or use --coldstart.
#
# High-level flow (happy path):
#   1) Optional coldstart wipe (down + remove named volumes)
#   2) Optional secrets rotation (only if coldstart)
#   3) Start MariaDB only; wait healthy
#   4) Run importer (schema + data + views)
#   5) Ensure DB user `xml_api` exists with least privilege (SELECT on uls.v_callbook only)
#   6) Start xml-api + web-ui
#   7) Run canonical sanity checks (admin/sanity-check.sh)
#   8) Completion information saved in logs/arcs-state.json (canonical) + admin/.bootstrap_complete (legacy)
#
# Status mode:
#   --status prints a concise view from logs/arcs-state.json (canonical),
#   and falls back to admin/.bootstrap_complete (legacy) if needed.
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
  cat <<'USAGE'
ARCS first-run bootstrap script

Usage:
  ./admin/first-run.sh [options]

Options:
  --coldstart
      Stop the stack and wipe named Docker volumes (fresh install workflow).

  --rotate-secrets
      Generate new local secrets.
      Allowed only with --coldstart.

  --force
      Non-interactive mode; implies --rotate-secrets.
      Still requires --coldstart.

  --ci
      CI-friendly output and enables sanity-check logging.

  --log-sanity
      Enable sanity-check logging even when not using --ci.

  --status
      Print canonical ARCS status (logs/arcs-state.json) and exit.

  --help, -h
      Show this help and exit.
USAGE
}

# -----------------------------
# Timing helpers
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
    *) die "Unknown arg: $arg (use --help)" ;;
  esac
done

# Guard: rotate secrets ONLY on coldstart
if [ "$ROTATE_SECRETS" = "yes" ] && [ "$COLDSTART" != "yes" ]; then
  die "Refusing to rotate secrets without --coldstart."
fi

# -----------------------------
# Paths / service names
# -----------------------------
SECRETS_DIR="$ROOT_DIR/secrets"
MDB_ROOT_PW_FILE="$SECRETS_DIR/mariadb_root_password.txt"
MDB_USER_PW_FILE="$SECRETS_DIR/mariadb_user_password.txt"
XML_API_PW_FILE="$SECRETS_DIR/xml_api_password.txt"

SVC_DB="uls-mariadb"
SVC_IMPORTER="uls-importer"
SVC_API="xml-api"
SVC_UI="web-ui"

CTR_DB="arcs-uls-mariadb"

LOGS_DIR="$ROOT_DIR/logs"
mkdir -p "$LOGS_DIR"

# -----------------------------
# Status-only mode
# -----------------------------
if [ "$STATUS_ONLY" = "yes" ]; then
  ./admin/first-run.sh --status
  exit 0
fi

# -----------------------------
# Core helpers
# -----------------------------
random_pw() {
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
}

wait_mariadb_healthy() {
  log "Waiting for MariaDB health..."
  for _ in $(seq 1 90); do
    if docker inspect --format '{{.State.Health.Status}}' "$CTR_DB" 2>/dev/null | grep -qx healthy; then
      return 0
    fi
    sleep 2
  done
  die "MariaDB did not become healthy in time."
}

run_importer() {
  log "Running importer (locked, skip-if-unchanged)..."

  local log_file="$LOGS_DIR/importer_$(date +%Y%m%d_%H%M%S).log"
  log "Importer output: $log_file"

  start_heartbeat "Importer running"
  set +e
  docker compose run --rm "$SVC_IMPORTER" --lock --skip-if-unchanged \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  stop_heartbeat

  if [ "$rc" -ne 0 ]; then
    tail -n 50 "$log_file" | sed 's/^/[first-run]   /'
    die "Importer failed."
  fi
}

start_services() {
  docker compose up -d "$SVC_DB"
  wait_mariadb_healthy
  run_importer
  docker compose up -d "$SVC_API" "$SVC_UI"
}

# -----------------------------
# Main
# -----------------------------
log "ARCS first-run starting..."

if [ "$COLDSTART" = "yes" ]; then
  docker compose down --remove-orphans || true
fi

if [ "$ROTATE_SECRETS" = "yes" ]; then
  rotate_secrets
fi

start_services

log "ARCS first-run complete."
