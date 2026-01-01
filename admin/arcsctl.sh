#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# admin/arcsctl.sh
#
# Purpose:
#   ARCS control script (install, update, reconciliation).
#
# Author: Edward Moss - N0LJD
#
# Key rules:
#   - Secrets rotation happens ONLY with --coldstart + (--rotate-secrets or --force).
#   - Re-running arcsctl.sh on an existing system is expected and safe.
#
# High-level flow:
#   1) Optional coldstart wipe (down + remove named volumes)
#   2) Optional secrets rotation (coldstart only)
#   3) Start MariaDB only; wait healthy
#   4) Run importer (schema + data + views; importer handles "skip if unchanged")
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
log()  { printf '[arcsctl] %s\n' "$*"; }
warn() { printf '[arcsctl] WARN: %s\n' "$*" >&2; }
die()  { printf '[arcsctl] ERROR: %s\n' "$*" >&2; exit 2; }

need_file() {
  local f="$1"
  [ -f "$f" ] || die "Missing required file: $f"
}

usage() {
  printf '%s\n' \
"Usage: ./admin/arcsctl.sh [--status] [--coldstart] [--rotate-secrets] [--force] [--ci] [--log-sanity]" \
"" \
"Modes:" \
"  (no args)         Reconcile/update ARCS safely (start DB, run importer, start services, sanity-check)" \
"  --status          Print canonical state (logs/arcs-state.json) and exit" \
"" \
"Flags:" \
"  --coldstart       Stop stack and wipe named volumes (fresh install / rebuild workflow)" \
"  --rotate-secrets  Generate new local secrets (allowed only with --coldstart)" \
"  --force           Non-interactive; implies --rotate-secrets (still requires --coldstart)" \
"  --ci              Non-interactive style output; also enables sanity-check logging" \
"  --log-sanity      Enable sanity-check logging even when not using --ci" \
"  -h, --help        Show this help and exit" \
"" \
"Env:" \
"  HEARTBEAT_INTERVAL=1   Seconds between progress dots for long steps"
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
  local msg="${1:-Processing}"
  stop_heartbeat || true

  if [ "${CI:-no}" = "yes" ]; then
    return 0
  fi

  printf '[arcsctl] %s ' "$msg"
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
    *) die "Unknown arg: $arg" ;;
  esac
done

# Guard: rotate secrets ONLY on coldstart
if [ "$ROTATE_SECRETS" = "yes" ] && [ "$COLDSTART" != "yes" ]; then
  die "Refusing to rotate secrets without --coldstart. Use: ./admin/arcsctl.sh --coldstart --rotate-secrets (or --force)."
fi

# ---------------------------------------------------------------------------
# First-time install convenience:
# If secrets are missing, assume a brand-new install and enable:
#   - --coldstart
#   - --rotate-secrets
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

# ---------------------------------------------------------------------------
# Mode resolution
# ---------------------------------------------------------------------------
FRESH_INSTALL="no"
if [ ! -f "$ROOT_DIR/admin/.bootstrap_complete" ]; then
  FRESH_INSTALL="yes"
fi

log "Mode resolved: fresh-install=${FRESH_INSTALL} coldstart=${COLDSTART} rotate-secrets=${ROTATE_SECRETS} ci=${CI}"

if [ "$COLDSTART" = "yes" ]; then
  printf '\n[arcsctl] NOTE: A coldstart (fresh install) may take several minutes to complete.\n\n'
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

# Canonical state/log paths
LOGS_DIR="$ROOT_DIR/logs"
ARCS_STATE_JSON="$LOGS_DIR/arcs-state.json"
BOOTSTRAP_MARKER_LEGACY="$ROOT_DIR/admin/.bootstrap_complete"

mkdir -p "$LOGS_DIR"

# -----------------------------
# Canonical state writer (JSON merge)
# -----------------------------
merge_bootstrap_state_json() {
  local started_at="$1"
  local finished_at="$2"
  local result="$3"
  local elapsed_seconds="$4"
  local elapsed_human="$5"

  python3 - <<PY
import json
from pathlib import Path

p = Path(${ARCS_STATE_JSON@Q})
obj = {}
if p.exists():
    try:
        obj = json.loads(p.read_text(encoding="utf-8", errors="replace") or "{}")
        if not isinstance(obj, dict):
            obj = {}
    except Exception:
        obj = {}

obj.setdefault("bootstrap", {})
obj["bootstrap"].update({
    "started_at_utc": ${started_at@Q},
    "completed_at_utc": ${finished_at@Q},
    "result": ${result@Q},
    "elapsed_seconds": str(${elapsed_seconds@Q}),
    "elapsed_human": ${elapsed_human@Q},
    "fresh_install": ${FRESH_INSTALL@Q},
    "coldstart": ${COLDSTART@Q},
    "rotate_secrets": ${ROTATE_SECRETS@Q},
    "ci_mode": ${CI@Q},
})

p.parent.mkdir(parents=True, exist_ok=True)
tmp = p.with_suffix(p.suffix + ".tmp")
tmp.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
tmp.replace(p)
PY
}

print_status() {
  log "Status requested (--status)."

  if [ -f "$ARCS_STATE_JSON" ]; then
    log "Canonical state: logs/arcs-state.json"
    python3 - <<PY
import json
from pathlib import Path

p = Path(${ARCS_STATE_JSON@Q})
obj = json.loads(p.read_text(encoding="utf-8", errors="replace") or "{}")
if not isinstance(obj, dict):
    obj = {}

def get(ns, k, d=""):
    v = obj.get(ns, {}).get(k, d)
    return "" if v is None else str(v)

def pick(ns, *keys, default=""):
    d = obj.get(ns, {})
    if not isinstance(d, dict):
        return default
    for k in keys:
        v = d.get(k)
        if v not in (None, "", []):
            return str(v)
    return default

def short(s, n=12):
    s = str(s or "")
    return (s[:n] + "…") if len(s) > n else s

print("[arcsctl] --- bootstrap ---")
print(f"[arcsctl]   result: {get('bootstrap','result','')}")
print(f"[arcsctl]   started_at_utc: {get('bootstrap','started_at_utc','')}")
print(f"[arcsctl]   completed_at_utc: {get('bootstrap','completed_at_utc','')}")
eh = get('bootstrap','elapsed_human','')
es = get('bootstrap','elapsed_seconds','')
print(f"[arcsctl]   elapsed: {eh} ({es}s)")
print(f"[arcsctl]   coldstart: {get('bootstrap','coldstart','')} rotate_secrets: {get('bootstrap','rotate_secrets','')} ci_mode: {get('bootstrap','ci_mode','')}")
print()

ui = obj.get("uls_import", {})
print("[arcsctl] --- uls_import ---")
if isinstance(ui, dict) and ui:
    # Prefer canonical "clear" fields, fallback to legacy names if needed
    last_result = pick("uls_import", "last_run_result", "result", default="")
    last_skip   = pick("uls_import", "last_run_skip_reason", "skip_reason", default="")
    last_start  = pick("uls_import", "last_run_started_at", "import_started", default="")
    last_end    = pick("uls_import", "last_run_finished_at", "import_finished", default="")
    local_upd   = pick("uls_import", "local_data_updated_at", default="")
    src_url     = pick("uls_import", "source_url", "download_url", default="")
    src_lm      = pick("uls_import", "source_last_modified_at", "http_last_modified", default="")
    src_etag    = pick("uls_import", "source_etag", "http_etag", default="")
    src_sha     = pick("uls_import", "source_zip_sha256", "zip_sha256", default="")
    src_bytes   = pick("uls_import", "source_zip_bytes", "zip_bytes", default="")

    print(f"[arcsctl]   last_run_result: {last_result}")
    print(f"[arcsctl]   last_run_skip_reason: {last_skip}")
    print(f"[arcsctl]   last_run_started_at: {last_start}")
    print(f"[arcsctl]   last_run_finished_at: {last_end}")
    if local_upd:
        print(f"[arcsctl]   local_data_updated_at: {local_upd}")
    print(f"[arcsctl]   source_url: {src_url}")
    print(f"[arcsctl]   source_last_modified_at: {src_lm}")
    print(f"[arcsctl]   source_etag: {src_etag}")
    print(f"[arcsctl]   source_zip_sha256: {src_sha} (short: {short(src_sha)})")
    print(f"[arcsctl]   source_zip_bytes: {src_bytes}")
else:
    print("[arcsctl]   (no importer state found yet in arcs-state.json)")
PY
    return 0
  fi

  warn "No canonical state file found at logs/arcs-state.json"
  if [ -f "$BOOTSTRAP_MARKER_LEGACY" ]; then
    log "Legacy bootstrap metadata: admin/.bootstrap_complete"
    sed 's/^/[arcsctl]   /' "$BOOTSTRAP_MARKER_LEGACY"
  else
    warn "No legacy bootstrap metadata found at admin/.bootstrap_complete"
    warn "Run: ./admin/arcsctl.sh (or ./admin/arcsctl.sh --coldstart) to perform bootstrap."
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

  docker volume rm arcs_uls_db_data 2>/dev/null || true
  docker volume rm arcs_uls_cache   2>/dev/null || true

  log "Coldstart wipe complete."
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

run_importer() {
  log "Running importer (schema + data + views; may take a while)..."

  mkdir -p "$LOGS_DIR"
  local log_file="$LOGS_DIR/importer_$(date +%Y%m%d_%H%M%S).log"
  log "Importer output: $log_file"

  start_heartbeat "Importer running (still processing)"
  set +e
  docker compose run --rm "$SVC_IMPORTER" >"$log_file" 2>&1
  local rc=$?
  set -e
  stop_heartbeat

  printf '\n'

  if [ "$rc" -ne 0 ]; then
    log "Importer failed (exit=$rc). Last 50 lines:"
    tail -n 50 "$log_file" | sed 's/^/[arcsctl]   /'
    die "Importer failed. See full log: $log_file"
  fi

  log "Importer complete."
}

ensure_xml_api_user() {
  need_file "$MDB_ROOT_PW_FILE"
  need_file "$XML_API_PW_FILE"

  local rootpw xmlpw
  rootpw="$(cat "$MDB_ROOT_PW_FILE")"
  xmlpw="$(cat "$XML_API_PW_FILE")"

  log "Ensuring DB user 'xml_api' exists, password is synchronized, and privileges are view-only (uls.v_callbook)..."

  docker compose exec -T "$SVC_DB" \
    mariadb -uroot -p"$rootpw" -e "
      CREATE USER IF NOT EXISTS 'xml_api'@'%' IDENTIFIED BY '${xmlpw}';
      ALTER USER 'xml_api'@'%' IDENTIFIED BY '${xmlpw}';
      FLUSH PRIVILEGES;
    " >/dev/null

  docker compose exec -T "$SVC_DB" \
    mariadb -uroot -p"$rootpw" -e "
      REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'xml_api'@'%';
      GRANT SELECT ON \`uls\`.\`v_callbook\` TO 'xml_api'@'%';
      FLUSH PRIVILEGES;
    " >/dev/null

  if ! docker compose exec -T "$SVC_DB" \
      mariadb -uroot -p"$rootpw" -N -e "USE \`uls\`; SHOW FULL TABLES LIKE 'v_callbook';" \
      | grep -qi 'v_callbook'; then
    die "Required view 'uls.v_callbook' was not found. Import/schema may be incomplete."
  fi

  if [ "${CI:-no}" != "yes" ]; then
    log "xml_api grants now set to:"
    docker compose exec -T "$SVC_DB" \
      mariadb -uroot -p"$rootpw" -N -e "SHOW GRANTS FOR 'xml_api'@'%';" \
      | sed 's/^/[arcsctl]   /'
  fi

  log "DB user 'xml_api' OK (restricted to SELECT on uls.v_callbook)."
}

start_services() {
  log "Starting MariaDB..."
  docker compose up -d "$SVC_DB"

  wait_mariadb_healthy 90 2

  run_importer
  ensure_xml_api_user

  log "Starting runtime services (xml-api + web-ui)..."
  docker compose up -d "$SVC_API" "$SVC_UI"
}

run_sanity_check() {
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
BOOTSTRAP_STARTED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log "ARCS control starting..."
log "Project root: $ROOT_DIR"

if [ "$COLDSTART" = "yes" ]; then
  coldstart_wipe
fi

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

start_services
run_sanity_check

TOTAL_END_EPOCH="$(date +%s)"
TOTAL_ELAPSED=$((TOTAL_END_EPOCH - SCRIPT_START_EPOCH))
BOOTSTRAP_FINISHED_UTC="$(date -u '+%Y-%m-%dT%H%M%SZ')"

# Fix timestamp format typo if any (keep it strict RFC3339 with Z)
BOOTSTRAP_FINISHED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log "Done. Total elapsed $(fmt_seconds "$TOTAL_ELAPSED")."

# Legacy: admin/.bootstrap_complete (quick grepping)
{
  echo "bootstrap_started_at_utc=${BOOTSTRAP_STARTED_UTC}"
  echo "bootstrap_completed_at_utc=${BOOTSTRAP_FINISHED_UTC}"
  echo "result=success"
  echo "elapsed_seconds=${TOTAL_ELAPSED}"
  echo "elapsed_human=$(fmt_seconds "$TOTAL_ELAPSED")"
  echo "fresh_install=${FRESH_INSTALL:-unknown}"
  echo "coldstart=${COLDSTART}"
  echo "rotate_secrets=${ROTATE_SECRETS}"
  echo "ci_mode=${CI}"
} > "$BOOTSTRAP_MARKER_LEGACY"

# Canonical: logs/arcs-state.json (bootstrap namespace)
merge_bootstrap_state_json \
  "$BOOTSTRAP_STARTED_UTC" \
  "$BOOTSTRAP_FINISHED_UTC" \
  "success" \
  "${TOTAL_ELAPSED}" \
  "$(fmt_seconds "$TOTAL_ELAPSED")"

log "Bootstrap metadata written:"
log "  Canonical: logs/arcs-state.json (bootstrap)"
log "  Legacy:    admin/.bootstrap_complete"
