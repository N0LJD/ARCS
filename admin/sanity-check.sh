#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# admin/sanity-check.sh
#
# Purpose:
#   Canonical health verification for ARCS. This is designed to be:
#     - called automatically at the end of admin/first-run.sh
#     - run manually by operators for quick validation
#
# What it checks:
#   0) Bootstrap metadata (admin/.bootstrap_complete) - if present
#   1) docker compose visibility + core containers running
#   2) MariaDB container health (Docker healthcheck)
#   3) Required DB object exists (uls.v_callbook)
#   4) xml_api least-privilege enforcement:
#        - SHOW GRANTS confirms SELECT on uls.v_callbook only
#        - Active DB probe confirms xml_api can read v_callbook and cannot read base tables
#   5) API checks (/health and /xml.php)
#   6) Web UI proxy check (/api/health)
#
# Output:
#   - Uses a consistent "[sanity]" prefix to match first-run.sh log style
#   - PASS/WARN/FAIL counts summarized at the end
#
# Options:
#   --no-color   Disable ANSI colors
#   --log        Tee output to logs/sanity-check_*.log
#
# Usage:
#   ./admin/sanity-check.sh [CALLSIGN] [--no-color] [--log]
# -----------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

COMPOSE="docker compose"

DB_SVC="uls-mariadb"
API_SVC="xml-api"
UI_SVC="web-ui"

DB_CONTAINER="${DB_CONTAINER:-arcs-uls-mariadb}"
DB_NAME="${DB_NAME:-uls}"

CALLSIGN="W1AW"
NO_COLOR="no"
DO_LOG="no"

# Paths used by policy
BOOTSTRAP_FILE="$PROJECT_ROOT/admin/.bootstrap_complete"
XML_SECRET_FILE="$PROJECT_ROOT/secrets/xml_api_password.txt"

API_BASE="${API_BASE:-http://127.0.0.1:8080}"
UI_BASE="${UI_BASE:-http://127.0.0.1:8081}"

# ---- Counters ----
PASS_CT=0
WARN_CT=0
FAIL_CT=0

# ---- Color ----
if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; RESET=""
fi

# ---- Logging helpers (match first-run style) ----
log()  { printf '[sanity] %s\n' "$*"; }
pass() { PASS_CT=$((PASS_CT+1)); printf '[sanity]   %bPASS%b %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { WARN_CT=$((WARN_CT+1)); printf '[sanity]   %bWARN%b %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }
fail() { FAIL_CT=$((FAIL_CT+1)); printf '[sanity]   %bFAIL%b %s\n' "${RED}" "${RESET}" "$*" >&2; exit 1; }

usage() {
  printf '%s\n' \
'Usage: ./admin/sanity-check.sh [CALLSIGN] [--no-color] [--log]' \
'' \
'Options:' \
'  --no-color   Disable ANSI colors' \
'  --log        Tee output to logs/sanity-check_*.log'
}

# ---- Arg parsing ----
for a in "$@"; do
  case "$a" in
    --no-color) NO_COLOR="yes" ;;
    --log) DO_LOG="yes" ;;
    -h|--help) usage; exit 0 ;;
    -*)
      # unknown flag
      ;;
    *)
      # first non-flag arg is callsign
      CALLSIGN="$a"
      ;;
  esac
done

if [[ "$NO_COLOR" == "yes" ]]; then
  RED=""; GREEN=""; YELLOW=""; RESET=""
fi

# ---- Optional logging to file ----
if [[ "$DO_LOG" == "yes" ]]; then
  mkdir -p "$PROJECT_ROOT/logs"
  LOGFILE="$PROJECT_ROOT/logs/sanity-check_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOGFILE") 2>&1
  log "Logging enabled: $LOGFILE"
fi

log "ARCS sanity check starting..."
log "Project root: $PROJECT_ROOT"
log "Callsign: $CALLSIGN"
echo

# -----------------------------------------------------------------------------
# [0] Bootstrap metadata
# -----------------------------------------------------------------------------
log "[0] Bootstrap metadata (admin/.bootstrap_complete)..."
if [[ -f "$BOOTSTRAP_FILE" ]]; then
  # Print key fields if present (file is simple key=value)
  BOOT_AT="$(grep -E '^bootstrap_completed_at_utc=' "$BOOTSTRAP_FILE" | head -n1 | cut -d= -f2- || true)"
  ELAPSED_HUMAN="$(grep -E '^elapsed_human=' "$BOOTSTRAP_FILE" | head -n1 | cut -d= -f2- || true)"
  ELAPSED_SEC="$(grep -E '^elapsed_seconds=' "$BOOTSTRAP_FILE" | head -n1 | cut -d= -f2- || true)"
  COLDSTART_META="$(grep -E '^coldstart=' "$BOOTSTRAP_FILE" | head -n1 | cut -d= -f2- || true)"
  ROTATE_META="$(grep -E '^rotate_secrets=' "$BOOTSTRAP_FILE" | head -n1 | cut -d= -f2- || true)"

  pass "Found bootstrap metadata file"
  [[ -n "$BOOT_AT" ]] && log "  bootstrap_completed_at_utc=$BOOT_AT"
  if [[ -n "$ELAPSED_HUMAN" || -n "$ELAPSED_SEC" ]]; then
    log "  elapsed=${ELAPSED_HUMAN:-?} (${ELAPSED_SEC:-?} seconds)"
  fi
  [[ -n "$COLDSTART_META" ]] && log "  coldstart=$COLDSTART_META"
  [[ -n "$ROTATE_META" ]] && log "  rotate_secrets=$ROTATE_META"
else
  warn "Bootstrap metadata file not found. This is expected if first-run.sh has not completed successfully yet."
fi
echo

# -----------------------------------------------------------------------------
# [1] docker compose visibility + containers running
# -----------------------------------------------------------------------------
log "[1] docker compose visibility + core services..."
$COMPOSE ps >/dev/null 2>&1 || fail "docker compose not usable from here (wrong directory or permissions)"

PS_OUT="$($COMPOSE ps || true)"
echo "$PS_OUT" | grep -q "$DB_SVC"  || fail "Service $DB_SVC not found in compose ps"
echo "$PS_OUT" | grep -q "$API_SVC" || fail "Service $API_SVC not found in compose ps"
echo "$PS_OUT" | grep -q "$UI_SVC"  || warn "Service $UI_SVC not found in compose ps (web-ui may be optional in your build)"

pass "Compose services visible ($DB_SVC, $API_SVC)"
echo

# -----------------------------------------------------------------------------
# [2] MariaDB health
# -----------------------------------------------------------------------------
log "[2] MariaDB healthcheck..."
if docker inspect --format '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null | grep -qx healthy; then
  pass "MariaDB container is healthy ($DB_CONTAINER)"
else
  fail "MariaDB container is not healthy yet ($DB_CONTAINER). Check: docker logs $DB_CONTAINER"
fi
echo

# -----------------------------------------------------------------------------
# [3] Required DB object exists (uls.v_callbook)
# -----------------------------------------------------------------------------
log "[3] Required DB object exists (uls.v_callbook)..."
if ! $COMPOSE exec -T "$DB_SVC" sh -lc \
  "DBPASS=\"\$(cat /run/secrets/mariadb_root_password 2>/dev/null || true)\"; \
   [ -n \"\$DBPASS\" ] || exit 2; \
   mariadb -uroot -p\"\$DBPASS\" -N -B -e \"USE \\\`$DB_NAME\\\`; SHOW FULL TABLES LIKE 'v_callbook';\" " \
  | grep -qi 'v_callbook'; then
  fail "View uls.v_callbook not found (import/schema incomplete?)"
fi
pass "View uls.v_callbook exists"
echo

# -----------------------------------------------------------------------------
# [4] xml_api least-privilege enforcement
# -----------------------------------------------------------------------------
log "[4] xml_api least-privilege enforcement..."

# Confirm host-side secret exists (used for DB probe)
if [[ ! -f "$XML_SECRET_FILE" ]]; then
  fail "Missing host secret file: $XML_SECRET_FILE (first-run must generate secrets)"
fi
XML_PASS="$(tr -d '\r\n' < "$XML_SECRET_FILE")"
[[ -n "$XML_PASS" ]] || fail "xml_api secret file is empty: $XML_SECRET_FILE"

# Confirm xml-api container gets password via Docker secret mount (preferred)
if $COMPOSE exec -T "$API_SVC" sh -c 'test -r /run/secrets/xml_api_password' >/dev/null 2>&1; then
  pass "xml-api receives DB password via Docker secret (/run/secrets/xml_api_password)"
else
  warn "xml-api does not have readable /run/secrets/xml_api_password (may be wired differently); continuing with DB-side probe"
fi

# SHOW GRANTS: confirm SELECT on view only
GRANTS="$(
  $COMPOSE exec -T "$DB_SVC" sh -lc \
    "DBPASS=\"\$(cat /run/secrets/mariadb_root_password 2>/dev/null || true)\"; \
     mariadb -uroot -p\"\$DBPASS\" -N -B -e \"SHOW GRANTS FOR 'xml_api'@'%';\" " 2>/dev/null || true
)"
[[ -n "$GRANTS" ]] || fail "Could not read grants for xml_api@'%' (user missing or insufficient root access)"

echo "$GRANTS" | grep -q "GRANT SELECT ON \`$DB_NAME\`.\`v_callbook\`" \
  || fail "xml_api does not have expected SELECT on ${DB_NAME}.v_callbook"

# Must NOT show broader privileges
if echo "$GRANTS" | grep -qE "ON \`$DB_NAME\`\.\*" ; then
  fail "xml_api appears to have schema-wide privileges (expected view-only). Grants: $(echo "$GRANTS" | tr '\n' ' ')"
fi
if echo "$GRANTS" | grep -qE "GRANT (ALL PRIVILEGES|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER)" ; then
  fail "xml_api appears to have write/admin privileges (unexpected). Grants: $(echo "$GRANTS" | tr '\n' ' ')"
fi
pass "xml_api grants are view-only (SELECT on ${DB_NAME}.v_callbook)"
# Active probes from DB container using the host secret
VIEW_ROWS="$(
  $COMPOSE exec -T "$DB_SVC" sh -lc \
    "mariadb -u xml_api -p\"$XML_PASS\" -D \"$DB_NAME\" -N -B -e \"SELECT COUNT(*) FROM v_callbook;\" " 2>/dev/null || true
)"
[[ "$VIEW_ROWS" =~ ^[0-9]+$ ]] || fail "DB probe failed: xml_api could not SELECT from v_callbook using secret"
pass "DB probe OK: xml_api can SELECT v_callbook (rows=$VIEW_ROWS)"

set +e
$COMPOSE exec -T "$DB_SVC" sh -lc \
  "mariadb -u xml_api -p\"$XML_PASS\" -D \"$DB_NAME\" -e \"SELECT COUNT(*) FROM am;\" " >/dev/null 2>&1
RC=$?
set -e
[[ $RC -ne 0 ]] || fail "DB probe failed: xml_api unexpectedly can SELECT from base table 'am'"
pass "DB probe OK: xml_api is blocked from base tables (expected)"
echo

# -----------------------------------------------------------------------------
# [5] API checks
# -----------------------------------------------------------------------------
log "[5] API /health and /xml.php..."

HEALTH_OUT="$(mktemp)"; XML_OUT="$(mktemp)"
trap 'rm -f "$HEALTH_OUT" "$XML_OUT"' EXIT

HEALTH_HEADERS="$(curl -sS --max-time 10 -D - -o "$HEALTH_OUT" "${API_BASE}/health" || true)"
echo "$HEALTH_HEADERS" | grep -qE '^HTTP/1\.[01] 200' || fail "/health did not return HTTP 200"
CT_HEALTH="$(echo "$HEALTH_HEADERS" | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tr -d '\r')"
echo "$CT_HEALTH" | grep -q "application/json" || fail "/health content-type not application/json (got '$CT_HEALTH')"
grep -q '"ok":true' "$HEALTH_OUT" || fail "/health body missing ok:true"
pass "API /health returns 200 + JSON + ok:true"

XML_HEADERS="$(curl -sS --max-time 10 -D - -o "$XML_OUT" "${API_BASE}/xml.php?callsign=${CALLSIGN}" || true)"
echo "$XML_HEADERS" | grep -qE '^HTTP/1\.[01] 200' || fail "/xml.php did not return HTTP 200"
CT_XML="$(echo "$XML_HEADERS" | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tr -d '\r')"
echo "$CT_XML" | grep -qE '(application/xml|text/xml|application/xhtml\+xml)' || fail "/xml.php content-type not XML-like (got '$CT_XML')"
grep -q "<error>OK</error>" "$XML_OUT" || fail "Lookup did not return <error>OK</error>"
pass "API /xml.php returns 200 + XML + <error>OK</error>"
echo

# -----------------------------------------------------------------------------
# [6] Web UI proxy check
# -----------------------------------------------------------------------------
log "[6] Web UI proxy /api/health..."
UI_HEADERS="$(curl -sS --max-time 10 -D - -o /dev/null "${UI_BASE}/api/health" || true)"
echo "$UI_HEADERS" | grep -qE '^HTTP/1\.[01] 200' || fail "web-ui /api/health did not return HTTP 200"
pass "Web UI proxy /api/health returns 200"
echo

# -----------------------------------------------------------------------------
# Summary footer
# -----------------------------------------------------------------------------
log "Summary: ${PASS_CT} PASS / ${WARN_CT} WARN / ${FAIL_CT} FAIL"
if [[ "$WARN_CT" -gt 0 ]]; then
  warn "Completed with warnings (review WARN lines above)."
else
  pass "Completed with no warnings."
fi
