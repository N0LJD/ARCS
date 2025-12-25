-- Create read-only DB user for xml-api / external API consumers
CREATE USER IF NOT EXISTS 'callbook_ro'@'%' IDENTIFIED BY '42XcgBo4p';

-- Least privilege: only the view needed by the API
GRANT SELECT ON uls.v_callbook TO 'callbook_ro'@'%';

FLUSH PRIVILEGES;
