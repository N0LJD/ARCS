#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# admin-set-callbook-ro.sh
#
# Purpose:
#   One-shot admin utility to (re)apply the callbook_ro account configuration
#   in the MariaDB container WITHOUT storing plaintext passwords in SQL files.
#
# What it does:
#   - Reads DB root password from ./secrets/mariadb_root_password.txt
#   - Reads callbook_ro password from ./secrets/callbook_ro_password.txt
#   - Connects to the MariaDB container as root
#   - Creates callbook_ro@'%' if missing
#   - Sets/rotates password for callbook_ro@'%'
#   - Enforces least privilege:
#       * REVOKE ALL
#       * GRANT SELECT on uls.v_callbook only
#   - Prints final grants (safe)
#   - Verifies behavior:
#       * SELECT from v_callbook succeeds
#       * SELECT from base table am fails (expected)
#
# Notes:
#   - /docker-entrypoint-initdb.d scripts only run on FIRST init of an empty
#     /var/lib/mysql. This script is the repeatable admin step for live DBs.
#
# Usage:
#   cd /opt/arcs
#   sudo bash ./admin-set-callbook-ro.sh
#
# Optional env overrides:
#   DB_SERVICE=uls-mariadb
#   DB_NAME=uls
#   RO_USER=callbook_ro
#   RO_HOST=%
# ---------------------------------------------------------------------------

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_SERVICE="${DB_SERVICE:-uls-mariadb}"
DB_NAME="${DB_NAME:-uls}"
RO_USER="${RO_USER:-callbook_ro}"
RO_HOST="${RO_HOST:-%}"

ROOT_SECRET="${ROOT_SECRET:-$PROJECT_DIR/secrets/mariadb_root_password.txt}"
RO_SECRET="${RO_SECRET:-$PROJECT_DIR/secrets/callbook_ro_password.txt}"

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
ok() { echo "[OK]    $*"; }

[[ -f "$ROOT_SECRET" ]] || die "Missing root password file: $ROOT_SECRET"
[[ -f "$RO_SECRET" ]] || die "Missing RO password file: $RO_SECRET"

DB_ROOT_PASS="$(tr -d '\r\n' < "$ROOT_SECRET")"
RO_PASS="$(tr -d '\r\n' < "$RO_SECRET")"

[[ -n "$DB_ROOT_PASS" ]] || die "Root password file is empty: $ROOT_SECRET"
[[ -n "$RO_PASS" ]] || die "RO password file is empty: $RO_SECRET"

[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "docker-compose.yml not found in $PROJECT_DIR"

info "Project dir: $PROJECT_DIR"
info "DB service: $DB_SERVICE"
info "DB name:    $DB_NAME"
info "RO user:    $RO_USER@$RO_HOST"

SQL=$(cat <<SQL_EOF
CREATE USER IF NOT EXISTS '${RO_USER}'@'${RO_HOST}';
ALTER USER '${RO_USER}'@'${RO_HOST}' IDENTIFIED BY '${RO_PASS}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${RO_USER}'@'${RO_HOST}';
GRANT SELECT ON \`${DB_NAME}\`.\`v_callbook\` TO '${RO_USER}'@'${RO_HOST}';
FLUSH PRIVILEGES;
SHOW GRANTS FOR '${RO_USER}'@'${RO_HOST}';
SQL_EOF
)

info "Applying user/grant configuration in MariaDB..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T "$DB_SERVICE" \
  env MYSQL_PWD="$DB_ROOT_PASS" mariadb -uroot -N -B \
  <<<"$SQL" > /tmp/callbook_ro_grants.txt

ok "Applied. Current grants:"
cat /tmp/callbook_ro_grants.txt

info "Verifying least-privilege behavior (v_callbook allowed; base table blocked)..."

VERIFY_OK_SQL='SELECT COUNT(*) AS v_callbook_rows FROM v_callbook;'
VERIFY_DENY_SQL='SELECT COUNT(*) AS am_rows FROM am;'

# v_callbook should succeed
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T "$DB_SERVICE" \
  env MYSQL_PWD="$RO_PASS" mariadb -u"$RO_USER" -D "$DB_NAME" -N -B \
  <<<"$VERIFY_OK_SQL" > /tmp/callbook_ro_verify_ok.txt

ok "RO user can SELECT v_callbook (expected):"
cat /tmp/callbook_ro_verify_ok.txt

# base table should fail
set +e
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T "$DB_SERVICE" \
  env MYSQL_PWD="$RO_PASS" mariadb -u"$RO_USER" -D "$DB_NAME" -N -B \
  <<<"$VERIFY_DENY_SQL" > /tmp/callbook_ro_verify_deny.txt 2> /tmp/callbook_ro_verify_deny.err
RC=$?
set -e

if grep -qi "denied" /tmp/callbook_ro_verify_deny.err; then
  ok "RO user is blocked from base table access (expected)."
else
  die "Unexpected result: base-table query did not fail as expected (rc=$RC). See /tmp/callbook_ro_verify_deny.err"
fi

ok "Done."
