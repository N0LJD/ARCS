#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# admin/arcsctl.sh
#
# ARCS Control Script (modernized: no legacy/back-compat artifacts)
#
# Modes:
#   (no args)         Reconcile/update ARCS safely (start DB, run importer, start services, sanity-check)
#   --status          Print canonical state (logs/arcs-state.json) and exit
#
# Flags:
#   --coldstart       Stop stack and wipe named volumes (fresh install / rebuild workflow)
#   --rotate-secrets  Generate new local secrets (allowed only with --coldstart)
#   --force           Non-interactive; implies --rotate-secrets (still requires --coldstart)
#   --ci              Non-interactive style output; also enables sanity-check logging
#   --log-sanity      Enable sanity-check logging even when not using --ci
#   -h, --help        Show this help and exit
#
# Canonical state:
#   logs/arcs-state.json
#
# Importer behavior:
#   Invoked with: --skip-if-unchanged --meta-path /logs/.last_import
#
# Scheduler behavior (cron):
#   - Uses the SAME user that runs this script (no -u; installs into that user's crontab)
#   - If crontab is missing, warns and continues
#   - If no arcsctl entry exists, installs daily job at 03:00 local time
# -----------------------------------------------------------------------------

HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_DIR="${PROJECT_ROOT}/logs"
SECRETS_DIR="${PROJECT_ROOT}/secrets"
STATE_FILE="${LOG_DIR}/arcs-state.json"
IMPORT_META_PATH="/logs/.last_import"

# Compose service names
SVC_DB="uls-mariadb"
SVC_IMPORTER="uls-importer"
SVC_API="xml-api"
SVC_UI="web-ui"

# Named volumes (baseline)
VOL_DB_DATA="arcs_uls_db_data"
VOL_CACHE="arcs_uls_cache"

# Secrets
SECRET_DB_ROOT="${SECRETS_DIR}/mariadb_root_password.txt"
SECRET_DB_USER="${SECRETS_DIR}/mariadb_user_password.txt"
SECRET_XML_API="${SECRETS_DIR}/xml_api_password.txt"

# DB policy
DB_XML_API_USER="xml_api"
DB_NAME="uls"
DB_VIEW="v_callbook"

log()  { echo "[arcsctl] $*"; }
warn() { echo "[arcsctl] WARN: $*" >&2; }
err()  { echo "[arcsctl] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./admin/arcsctl.sh [--status] [--coldstart] [--rotate-secrets] [--force] [--ci] [--log-sanity]

Modes:
  (no args)         Reconcile/update ARCS safely (start DB, run importer, start services, sanity-check)
  --status          Print canonical state (logs/arcs-state.json) and exit

Flags:
  --coldstart       Stop stack and wipe named volumes (fresh install / rebuild workflow)
  --rotate-secrets  Generate new local secrets (allowed only with --coldstart)
  --force           Non-interactive; implies --rotate-secrets (still requires --coldstart)
  --ci              Non-interactive style output; also enables sanity-check logging
  --log-sanity      Enable sanity-check logging even when not using --ci
  -h, --help        Show this help and exit

Env:
  HEARTBEAT_INTERVAL=1   Seconds between progress dots for long steps
USAGE
}

utc_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

ensure_dirs() {
  mkdir -p "${LOG_DIR}" "${SECRETS_DIR}"
  chmod 700 "${LOG_DIR}" || true
}

compose() { (cd "${PROJECT_ROOT}" && docker compose "$@"); }

compose_ps_q() { compose ps -q "$1" 2>/dev/null || true; }

container_health() {
  local cid="$1"
  docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown"
}

wait_for_db_healthy() {
  local tries="$1"
  local delay="$2"
  log "Waiting for MariaDB health (tries=${tries} delay=${delay}s)..."
  local i=0
  while [ "$i" -lt "$tries" ]; do
    local cid
    cid="$(compose_ps_q "${SVC_DB}")"
    if [ -n "${cid}" ]; then
      local h
      h="$(container_health "${cid}")"
      if [ "${h}" = "healthy" ]; then
        log "MariaDB is healthy."
        return 0
      fi
    fi
    i=$((i+1))
    sleep "${delay}"
  done
  die "MariaDB did not become healthy in time."
}

volume_rm_if_exists() {
  local v="$1"
  if docker volume inspect "${v}" >/dev/null 2>&1; then
    docker volume rm -f "${v}" >/dev/null 2>&1 || true
  fi
}

gen_secret() { openssl rand -base64 32 | tr -d '\n'; }

write_secrets() {
  umask 077
  echo "$(gen_secret)" > "${SECRET_DB_ROOT}"
  echo "$(gen_secret)" > "${SECRET_DB_USER}"
  echo "$(gen_secret)" > "${SECRET_XML_API}"
  chmod 600 "${SECRET_DB_ROOT}" "${SECRET_DB_USER}" "${SECRET_XML_API}" || true
}

require_secrets_exist() {
  [ -f "${SECRET_DB_ROOT}" ] || die "Missing secret: ${SECRET_DB_ROOT}"
  [ -f "${SECRET_DB_USER}" ] || die "Missing secret: ${SECRET_DB_USER}"
  [ -f "${SECRET_XML_API}" ] || die "Missing secret: ${SECRET_XML_API}"
}

json_write_bootstrap() {
  local started_at="$1"
  local completed_at="$2"
  local elapsed_seconds="$3"
  local elapsed_human="$4"
  local coldstart="$5"
  local rotate_secrets="$6"
  local ci_mode="$7"
  local result="$8"

  python3 - "${STATE_FILE}" \
    "${result}" "${started_at}" "${completed_at}" \
    "${elapsed_seconds}" "${elapsed_human}" \
    "${coldstart}" "${rotate_secrets}" "${ci_mode}" <<'PY'
import json, sys, os

path = sys.argv[1]
result = sys.argv[2]
started_at = sys.argv[3]
completed_at = sys.argv[4]
elapsed_seconds = sys.argv[5]
elapsed_human = sys.argv[6]
coldstart = sys.argv[7]
rotate_secrets = sys.argv[8]
ci_mode = sys.argv[9]

doc = {}
if os.path.exists(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      doc = json.load(f)
  except Exception:
    doc = {}

doc.setdefault("bootstrap", {})
doc["bootstrap"].update({
  "result": result,
  "started_at_utc": started_at,
  "completed_at_utc": completed_at,
  "elapsed_seconds": str(elapsed_seconds),
  "elapsed_human": elapsed_human,
  "coldstart": coldstart,
  "rotate_secrets": rotate_secrets,
  "ci_mode": ci_mode
})

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
  json.dump(doc, f, indent=2, sort_keys=True)
  f.write("\n")
PY
}

json_merge_scheduler() {
  # Merge scheduler metadata into logs/arcs-state.json under "scheduler"
  local crontab_available="$1"   # yes/no
  local entry_present="$2"       # yes/no
  local entry_installed="$3"     # yes/no
  local entry_line="$4"          # string (may be empty)
  local owner_user="$5"          # who ran arcsctl (effective user)
  local owner_uid="$6"
  local owner_gid="$7"

  python3 - "${STATE_FILE}" \
    "${crontab_available}" "${entry_present}" "${entry_installed}" "${entry_line}" \
    "${owner_user}" "${owner_uid}" "${owner_gid}" <<'PY'
import json, sys, os

path = sys.argv[1]
crontab_available = sys.argv[2]
entry_present = sys.argv[3]
entry_installed = sys.argv[4]
entry_line = sys.argv[5]
owner_user = sys.argv[6]
owner_uid = sys.argv[7]
owner_gid = sys.argv[8]

doc = {}
if os.path.exists(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      doc = json.load(f)
  except Exception:
    doc = {}

doc.setdefault("scheduler", {})
doc["scheduler"].update({
  "crontab_available": crontab_available,
  "daily_3am_entry_present": entry_present,
  "daily_3am_entry_installed_this_run": entry_installed,
  "daily_3am_entry": entry_line,
  "installed_for_user": owner_user,
  "installed_for_uid": owner_uid,
  "installed_for_gid": owner_gid
})

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
  json.dump(doc, f, indent=2, sort_keys=True)
  f.write("\n")
PY
}

ensure_cron_daily() {
  # Install into the SAME user's crontab that runs arcsctl.sh.
  # Never hard-fail the run; this is a convenience + auto-update path.

  local owner_user owner_uid owner_gid
  owner_user="$(id -un 2>/dev/null || echo unknown)"
  owner_uid="$(id -u 2>/dev/null || echo -1)"
  owner_gid="$(id -g 2>/dev/null || echo -1)"

  if ! command -v crontab >/dev/null 2>&1; then
    warn "crontab not found. To enable automatic daily updates, install cron (e.g., 'cron' or 'cronie') and re-run arcsctl."
    json_merge_scheduler "no" "no" "no" "" "${owner_user}" "${owner_uid}" "${owner_gid}"
    return 0
  fi

  local job_cmd job_line existing tmp installed="no" present="no"

  # Cron uses local time. Use absolute paths and force working directory.
  # Use --ci --log-sanity to get consistent logging in logs/cron_arcsctl.log.
  job_cmd="cd ${PROJECT_ROOT} && ${PROJECT_ROOT}/admin/arcsctl.sh --ci --log-sanity >> ${PROJECT_ROOT}/logs/cron_arcsctl.log 2>&1"
  job_line="0 3 * * * ${job_cmd} # ARCS daily reconcile"

  existing="$(crontab -l 2>/dev/null || true)"

  # "Entry exists" means any crontab line referencing this arcsctl path.
  if printf "%s\n" "${existing}" | grep -Fq "${PROJECT_ROOT}/admin/arcsctl.sh"; then
    present="yes"
    log "Cron entry already present for arcsctl.sh (user=${owner_user})"
    json_merge_scheduler "yes" "yes" "no" "${job_line}" "${owner_user}" "${owner_uid}" "${owner_gid}"
    return 0
  fi

  tmp="$(mktemp)"
  {
    # Preserve existing (drop blank lines only)
    printf "%s\n" "${existing}" | sed '/^[[:space:]]*$/d'
    echo "${job_line}"
  } > "${tmp}"

  if crontab "${tmp}"; then
    installed="yes"
    present="yes"
    log "Cron entry installed for user=${owner_user}: daily at 03:00"
    log "Cron line: ${job_line}"
  else
    warn "Failed to install crontab entry for user=${owner_user} (continuing)."
  fi
  rm -f "${tmp}"

  json_merge_scheduler "yes" "${present}" "${installed}" "${job_line}" "${owner_user}" "${owner_uid}" "${owner_gid}"
  return 0
}

run_importer() {
  ensure_dirs
  local ts
  ts="$(date -u +%Y%m%d_%H%M%S)"
  local log_file="${LOG_DIR}/importer_${ts}.log"

  log "Running importer (schema + data + views; may take a while)..."
  log "Importer output: ${log_file}"
  log "Importer args: --skip-if-unchanged --meta-path ${IMPORT_META_PATH}"

  set +e
  (
    compose run --rm "${SVC_IMPORTER}" \
      --skip-if-unchanged \
      --meta-path "${IMPORT_META_PATH}" \
      >"${log_file}" 2>&1
  ) &
  local pid=$!
  set -e

  log -n "Importer running (still processing) "
  while kill -0 "${pid}" >/dev/null 2>&1; do
    printf "."
    sleep "${HEARTBEAT_INTERVAL}"
  done
  echo ""

  wait "${pid}" || {
    err "Importer failed. See: ${log_file}"
    return 1
  }

  if grep -q '^\[SKIP\]' "${log_file}"; then
    log "Importer skipped (unchanged source)."
  else
    log "Importer complete."
  fi
  return 0
}

db_exec_root() {
  local sql="$1"
  local root_pw
  root_pw="$(cat "${SECRET_DB_ROOT}")"

  if compose exec -T "${SVC_DB}" mariadb --version >/dev/null 2>&1; then
    compose exec -T "${SVC_DB}" mariadb -uroot "-p${root_pw}" -e "${sql}"
  else
    compose exec -T "${SVC_DB}" mysql -uroot "-p${root_pw}" -e "${sql}"
  fi
}

ensure_xml_api_user() {
  log "Ensuring DB user '${DB_XML_API_USER}' exists, password is synchronized, and privileges are view-only (${DB_NAME}.${DB_VIEW})..."
  local api_pw
  api_pw="$(cat "${SECRET_XML_API}")"

  db_exec_root "CREATE USER IF NOT EXISTS '${DB_XML_API_USER}'@'%' IDENTIFIED BY '${api_pw}';"
  db_exec_root "ALTER USER '${DB_XML_API_USER}'@'%' IDENTIFIED BY '${api_pw}';"
  db_exec_root "REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${DB_XML_API_USER}'@'%';"
  db_exec_root "GRANT SELECT ON \`${DB_NAME}\`.\`${DB_VIEW}\` TO '${DB_XML_API_USER}'@'%';"
  db_exec_root "FLUSH PRIVILEGES;"

  local grants
  grants="$(db_exec_root "SHOW GRANTS FOR '${DB_XML_API_USER}'@'%';" | sed '1d' || true)"
  log "xml_api grants now set to:"
  while IFS= read -r line; do
    [ -n "${line}" ] && log "  ${line}"
  done <<< "${grants}"

  log "DB user '${DB_XML_API_USER}' OK (restricted to SELECT on ${DB_NAME}.${DB_VIEW})."
}

run_sanity() {
  local ci_mode="$1"
  local log_sanity="$2"

  log "Running sanity checks: admin/sanity-check.sh"
  (
    cd "${PROJECT_ROOT}"
    if [ "${ci_mode}" = "yes" ] || [ "${log_sanity}" = "yes" ]; then
      export SANITY_LOG=1
    fi
    ./admin/sanity-check.sh
  )
}

status_print() {
  log "Status requested (--status)."
  log "Canonical state: logs/arcs-state.json"
  if [ ! -f "${STATE_FILE}" ]; then
    warn "No state file found at: ${STATE_FILE}"
    exit 0
  fi

  python3 - "${STATE_FILE}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
  doc = json.load(f)

def show_block(name, keys, hide_empty=None):
  v = doc.get(name, {})
  print(f"[arcsctl] --- {name} ---")
  if not isinstance(v, dict) or not v:
    print("[arcsctl]   (missing)\n")
    return
  hide_empty = set(hide_empty or [])
  for k in keys:
    if k not in v:
      continue
    if k in hide_empty and str(v.get(k,"")).strip() == "":
      continue
    if k == "source_zip_sha256" and isinstance(v[k], str) and len(v[k]) > 20:
      short = v[k][:12] + "…"
      print(f"[arcsctl]   {k}: {v[k]} (short: {short})")
    else:
      print(f"[arcsctl]   {k}: {v[k]}")
  print("")

show_block("bootstrap", ["result","started_at_utc","completed_at_utc","elapsed_human","elapsed_seconds","coldstart","rotate_secrets","ci_mode"])

show_block("uls_import", [
  "last_run_result","last_run_skip_reason",
  "last_run_started_at","last_run_finished_at",
  "local_data_updated_at",
  "source_url","source_last_modified_at","source_etag",
  "source_zip_sha256","source_zip_bytes"
], hide_empty={"last_run_skip_reason"})

show_block("scheduler", [
  "crontab_available",
  "daily_3am_entry_present",
  "daily_3am_entry_installed_this_run",
  "daily_3am_entry",
  "installed_for_user",
  "installed_for_uid",
  "installed_for_gid",
])
PY
}

# -----------------------------
# Argument parsing
# -----------------------------
MODE_STATUS="no"
FLAG_COLDSTART="no"
FLAG_ROTATE_SECRETS="no"
FLAG_FORCE="no"
FLAG_CI="no"
FLAG_LOG_SANITY="no"

if [ "${#}" -gt 0 ]; then
  while [ "${#}" -gt 0 ]; do
    case "$1" in
      --status) MODE_STATUS="yes" ;;
      --coldstart) FLAG_COLDSTART="yes" ;;
      --rotate-secrets) FLAG_ROTATE_SECRETS="yes" ;;
      --force) FLAG_FORCE="yes" ;;
      --ci) FLAG_CI="yes" ;;
      --log-sanity) FLAG_LOG_SANITY="yes" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown arg: $1" ;;
    esac
    shift
  done
fi

if [ "${FLAG_FORCE}" = "yes" ]; then
  FLAG_ROTATE_SECRETS="yes"
fi

if [ "${FLAG_ROTATE_SECRETS}" = "yes" ] && [ "${FLAG_COLDSTART}" != "yes" ]; then
  die "--rotate-secrets is allowed only with --coldstart"
fi
if [ "${FLAG_FORCE}" = "yes" ] && [ "${FLAG_COLDSTART}" != "yes" ]; then
  die "--force implies secrets rotation and therefore requires --coldstart"
fi

log "Mode resolved: fresh-install=no coldstart=${FLAG_COLDSTART} rotate-secrets=${FLAG_ROTATE_SECRETS} ci=${FLAG_CI}"

if [ "${MODE_STATUS}" = "yes" ]; then
  status_print
  exit 0
fi

# -----------------------------
# Main flow
# -----------------------------
ensure_dirs
STARTED_AT="$(utc_now_iso)"
START_EPOCH="$(date +%s)"

log "ARCS control starting..."
log "Project root: ${PROJECT_ROOT}"

# Configure daily updates via cron (non-fatal; same user that runs arcsctl.sh)
ensure_cron_daily

if [ "${FLAG_COLDSTART}" = "yes" ]; then
  log ""
  log "NOTE: A coldstart (fresh install) may take several minutes to complete."
  log ""
  log "Coldstart requested: stopping stack + wiping named volumes..."
  set +e
  compose down --remove-orphans >/dev/null 2>&1
  set -e

  volume_rm_if_exists "${VOL_DB_DATA}"
  volume_rm_if_exists "${VOL_CACHE}"
  log "Coldstart wipe complete."

  if [ "${FLAG_ROTATE_SECRETS}" = "yes" ]; then
    log "Rotating secrets (coldstart only)..."
    write_secrets
    log "Secrets written:"
    log "  ${SECRET_DB_ROOT}"
    log "  ${SECRET_DB_USER}"
    log "  ${SECRET_XML_API}"
  else
    require_secrets_exist
    log "Using existing secrets (no rotation):"
    log "  ${SECRET_DB_ROOT}"
    log "  ${SECRET_DB_USER}"
    log "  ${SECRET_XML_API}"
  fi
else
  require_secrets_exist
  log "Using existing secrets (no rotation):"
  log "  ${SECRET_DB_ROOT}"
  log "  ${SECRET_DB_USER}"
  log "  ${SECRET_XML_API}"
fi

log "Starting MariaDB..."
compose up -d "${SVC_DB}" >/dev/null
wait_for_db_healthy 90 2

run_importer
ensure_xml_api_user

log "Starting runtime services (xml-api + web-ui)..."
compose up -d "${SVC_API}" "${SVC_UI}" >/dev/null

run_sanity "${FLAG_CI}" "${FLAG_LOG_SANITY}"

END_EPOCH="$(date +%s)"
ELAPSED="$((END_EPOCH - START_EPOCH))"
if [ "${ELAPSED}" -lt 3600 ]; then
  ELAPSED_HUMAN="$(printf "%02d:%02d" $((ELAPSED/60)) $((ELAPSED%60)))"
else
  ELAPSED_HUMAN="$(printf "%02d:%02d:%02d" $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60)))"
fi
COMPLETED_AT="$(utc_now_iso)"

json_write_bootstrap "${STARTED_AT}" "${COMPLETED_AT}" "${ELAPSED}" "${ELAPSED_HUMAN}" "${FLAG_COLDSTART}" "${FLAG_ROTATE_SECRETS}" "${FLAG_CI}" "success"

log "Done. Total elapsed ${ELAPSED_HUMAN}."
log "State updated: logs/arcs-state.json"

exit 0
