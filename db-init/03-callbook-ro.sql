-- 03-callbook-ro.sql
--
-- Create the read-only DB account used by xml-api and grant least-privilege access.
-- IMPORTANT:
--   - No plaintext password is stored here.
--   - The password is managed separately (via secrets / DB_PASS_FILE) and should be set
--     with ALTER USER after init, or by a controlled admin step.
--
-- NOTE:
--   Files in /docker-entrypoint-initdb.d are only executed on FIRST container init
--   (when /var/lib/mysql is empty). If you already have a populated volume, changing
--   this file will not retroactively change users or grants.

CREATE USER IF NOT EXISTS 'callbook_ro'@'%';

GRANT SELECT ON `uls`.`v_callbook` TO 'callbook_ro'@'%';

FLUSH PRIVILEGES;

-- Optional: show grants during first init logs
SHOW GRANTS FOR 'callbook_ro'@'%';
