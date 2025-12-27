/*
  03-callbook-ro.sql
  ------------------
  Create the read-only callbook user used by the XML API.

  IMPORTANT:
  - On a fresh database init, the view `uls.v_callbook` does NOT exist yet.
    It is created later by the importer when it applies schema.sql.
  - Therefore we must NOT run GRANT statements that reference v_callbook here,
    or MariaDB init will fail.

  Strategy:
  - Create the user (if missing).
  - Grant minimal read access to the database so the API can function once
    the importer creates the view/tables.
  - The importer (or a post-import admin step) can tighten permissions later
    to SELECT-only on v_callbook if desired.
*/

-- Create user if it doesn't exist
CREATE USER IF NOT EXISTS 'callbook_ro'@'%' IDENTIFIED BY 'CHANGEME';

-- Grant read-only access to the schema.
-- This avoids referencing v_callbook before it exists.
GRANT SELECT ON `uls`.* TO 'callbook_ro'@'%';

FLUSH PRIVILEGES;
