#!/usr/bin/env bash
set -euo pipefail

COMPOSE="docker compose"
DB_SVC="uls-mariadb"
API_SVC="xml-api"
API_BASE="http://localhost:8080"
CALLSIGN="${1:-W1AW}"

# Defaults (override by exporting these env vars before running)
ROOT_PASS="${MARIADB_ROOT_PASSWORD:-6SpfBdgW8}"
DB_NAME="${DB_NAME:-uls}"
RO_USER="${DB_USER:-callbook_ro}"
RO_PASS="${DB_PASS:-42XcgBo4p}"
DB_HOST_EXPECTED="${DB_HOST_EXPECTED:-uls-mariadb}"

fail() { echo "? $*" >&2; exit 1; }
pass() { echo "? $*"; }

cd "$(dirname "$0")"

echo "== HamCall sanity check =="
echo "Project dir: $(pwd)"
echo "Callsign: $CALLSIGN"
echo

# ---- Compose sanity ----
echo "[1] Checking compose visibility..."
$COMPOSE ps >/dev/null || fail "docker compose not usable from here (wrong directory or permissions)"
$COMPOSE ps | grep -q "$DB_SVC" || fail "Service $DB_SVC not found in compose ps"
$COMPOSE ps | grep -q "$API_SVC" || fail "Service $API_SVC not found in compose ps"
pass "Compose services visible ($DB_SVC, $API_SVC)"

# ---- DB reachable as root ----
echo
echo "[2] Checking DB root access + required objects..."
$COMPOSE exec -T "$DB_SVC" mariadb -u root -p"${ROOT_PASS}" -e "USE ${DB_NAME}; SHOW TABLES LIKE 'v_callbook';" >/dev/null \
  || fail "Cannot connect to MariaDB as root or DB '${DB_NAME}' missing"
pass "MariaDB root login OK; database '${DB_NAME}' reachable"

# ---- RO user exists + grants ----
echo
echo "[3] Checking RO user exists and grants..."
GRANTS="$($COMPOSE exec -T "$DB_SVC" mariadb -u root -p"${ROOT_PASS}" -N -e "SHOW GRANTS FOR '${RO_USER}'@'%';" 2>/dev/null || true)"
[[ -n "$GRANTS" ]] || fail "RO user '${RO_USER}'@'%' not found (or cannot SHOW GRANTS)"

echo "$GRANTS" | grep -q "GRANT SELECT ON \`${DB_NAME}\`.\`v_callbook\`" \
  || fail "RO user does not have SELECT on ${DB_NAME}.v_callbook"

if echo "$GRANTS" | grep -qE "GRANT (ALL PRIVILEGES|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER)"; then
  fail "RO user appears to have write/admin privileges (unexpected): $(echo "$GRANTS" | tr '\n' ' ')"
fi
pass "RO grants look least-privilege (SELECT on v_callbook)"

# ---- RO enforcement ----
echo
echo "[4] Testing RO user can read view but NOT base tables..."
VIEW_ROWS="$($COMPOSE exec -T "$DB_SVC" mariadb -u "${RO_USER}" -p"${RO_PASS}" -D "${DB_NAME}" -N -e "SELECT COUNT(*) FROM v_callbook;" 2>/dev/null || true)"
[[ "$VIEW_ROWS" =~ ^[0-9]+$ ]] || fail "RO user could not SELECT from v_callbook"
pass "RO user can SELECT v_callbook (rows=$VIEW_ROWS)"

set +e
$COMPOSE exec -T "$DB_SVC" mariadb -u "${RO_USER}" -p"${RO_PASS}" -D "${DB_NAME}" -e "SELECT COUNT(*) FROM am;" >/dev/null 2>&1
RC=$?
set -e
[[ $RC -ne 0 ]] || fail "RO user unexpectedly can SELECT from base table am"
pass "RO user is blocked from base table am (as expected)"

# ---- xml-api env correctness ----
echo
echo "[5] Validating xml-api container configuration (env)..."
API_ENV="$($COMPOSE exec -T "$API_SVC" env | egrep -i '^(DB_HOST|DB_NAME|DB_USER|DB_PASS)=' || true)"
[[ -n "$API_ENV" ]] || fail "Could not read DB_* environment variables from $API_SVC"

API_DB_HOST="$(echo "$API_ENV" | awk -F= '/^DB_HOST=/{print $2}')"
API_DB_NAME="$(echo "$API_ENV" | awk -F= '/^DB_NAME=/{print $2}')"
API_DB_USER="$(echo "$API_ENV" | awk -F= '/^DB_USER=/{print $2}')"
API_DB_PASS="$(echo "$API_ENV" | awk -F= '/^DB_PASS=/{print $2}')"

[[ "$API_DB_HOST" == "$DB_HOST_EXPECTED" ]] || fail "xml-api DB_HOST mismatch: got '$API_DB_HOST' expected '$DB_HOST_EXPECTED'"
[[ "$API_DB_NAME" == "$DB_NAME" ]] || fail "xml-api DB_NAME mismatch: got '$API_DB_NAME' expected '$DB_NAME'"
[[ "$API_DB_USER" == "$RO_USER" ]] || fail "xml-api DB_USER mismatch: got '$API_DB_USER' expected '$RO_USER'"
[[ "$API_DB_PASS" == "$RO_PASS" ]] || fail "xml-api DB_PASS mismatch (got different value than expected)"
pass "xml-api DB_* env matches expected (host/name/user/pass)"

# ---- API /health ----
echo
echo "[6] Checking API /health (status + content-type + body)..."
HEALTH_HEADERS="$(curl -sS -D - -o /tmp/hamcall_health.out "${API_BASE}/health" || true)"
echo "$HEALTH_HEADERS" | grep -qE '^HTTP/1\.[01] 200' || fail "/health did not return HTTP 200"
# prefer JSON on health
CT_HEALTH="$(echo "$HEALTH_HEADERS" | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tr -d '\r')"
echo "$CT_HEALTH" | grep -q "application/json" || fail "/health content-type is not application/json (got '$CT_HEALTH')"
grep -q '"ok":true' /tmp/hamcall_health.out || fail "/health body missing ok:true"
pass "/health returns 200 + application/json + ok:true"

# ---- API /xml.php ----
echo
echo "[7] Checking API /xml.php lookup for ${CALLSIGN} (status + xml + content-type)..."
XML_HEADERS="$(curl -sS -D - -o /tmp/hamcall_lookup.out "${API_BASE}/xml.php?callsign=${CALLSIGN}" || true)"
echo "$XML_HEADERS" | grep -qE '^HTTP/1\.[01] 200' || fail "/xml.php did not return HTTP 200"

CT_XML="$(echo "$XML_HEADERS" | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tr -d '\r')"
# Some servers may send text/xml or application/xml; accept either.
echo "$CT_XML" | grep -qE '(application/xml|text/xml|application/xhtml\+xml)' || fail "/xml.php content-type not XML-like (got '$CT_XML')"

grep -q "<error>OK</error>" /tmp/hamcall_lookup.out || fail "Lookup did not return <error>OK</error>"
grep -q "<result>1</result>" /tmp/hamcall_lookup.out || fail "Lookup did not return <result>1</result>"
pass "/xml.php returns 200 + XML content-type + OK/result=1"

echo
echo "?? Sanity check PASSED"
