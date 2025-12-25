/*
  schema.sql
  Edward Moss - N0LJD
  ----------
  Defines database schema, staging tables, and public views for the
  HamCall / FCC ULS import process.

  IMPORTANT:
  - This file is applied on every importer run.
  - Tables and views defined here are recreated or replaced.
  - Presentation logic (joins, derived fields, labels) belongs here,
    not in import_uls.py.

*/


CREATE DATABASE IF NOT EXISTS uls
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE uls;

-- Final tables (used by queries / APIs)
DROP TABLE IF EXISTS hd;
CREATE TABLE hd (
  record_type CHAR(2),
  unique_system_identifier BIGINT NOT NULL,
  call_sign CHAR(10),
  license_status CHAR(1),

  -- NOTE:
  -- operator_class is stored in AM.dat (loaded into table "am").
  -- This column exists for convenience, but the view should use am.operator_class as authoritative.
  operator_class CHAR(1) NULL,

  grant_date DATE,
  expired_date DATE,
  last_action_date DATE,
  PRIMARY KEY (unique_system_identifier),
  KEY idx_callsign (call_sign)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS en;
CREATE TABLE en (
  record_type CHAR(2),
  unique_system_identifier BIGINT NOT NULL,
  call_sign CHAR(10),
  entity_name VARCHAR(200),
  first_name VARCHAR(40),
  last_name VARCHAR(40),
  street_address VARCHAR(80),
  city VARCHAR(40),
  state CHAR(2),
  zip_code VARCHAR(10),
  PRIMARY KEY (unique_system_identifier),
  KEY idx_en_callsign (call_sign),
  KEY idx_location (state, city, zip_code)
) ENGINE=InnoDB;

-- Amateur (AM) staging: raw fields from AM.dat
CREATE TABLE IF NOT EXISTS stg_am (
  record_type VARCHAR(2) NULL,
  unique_system_identifier VARCHAR(32) NULL,
  uls_file_number VARCHAR(32) NULL,
  ebf_number VARCHAR(32) NULL,
  call_sign VARCHAR(10) NULL,
  operator_class VARCHAR(2) NULL
);

-- Amateur (AM) final: normalized subset we care about
CREATE TABLE IF NOT EXISTS am (
  unique_system_identifier BIGINT NOT NULL,
  call_sign CHAR(10) NULL,
  operator_class CHAR(1) NULL,
  PRIMARY KEY (unique_system_identifier),
  KEY idx_am_call_sign (call_sign)
);

-- Staging tables (loaded directly from FCC files)
DROP TABLE IF EXISTS stg_hd;
CREATE TABLE stg_hd (
  record_type CHAR(2),
  unique_system_identifier BIGINT,
  uls_file_number VARCHAR(20),
  ebf_number VARCHAR(40),
  call_sign VARCHAR(20),
  license_status VARCHAR(5),
  operator_class VARCHAR(8) NULL,
  radio_service_code VARCHAR(10),
  grant_date VARCHAR(20),
  expired_date VARCHAR(20),
  cancellation_date VARCHAR(20),
  last_action_date VARCHAR(20)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS stg_en;
CREATE TABLE stg_en (
  record_type CHAR(2),
  unique_system_identifier BIGINT,
  uls_file_number VARCHAR(20),
  ebf_number VARCHAR(40),
  call_sign VARCHAR(20),
  entity_type VARCHAR(10),
  licensee_id VARCHAR(20),
  entity_name VARCHAR(200),
  first_name VARCHAR(80),
  mi VARCHAR(5),
  last_name VARCHAR(80),
  suffix VARCHAR(10),
  phone VARCHAR(30),
  fax VARCHAR(30),
  email VARCHAR(120),
  street_address VARCHAR(120),
  city VARCHAR(80),
  state VARCHAR(10),
  zip_code VARCHAR(20),
  po_box VARCHAR(40),
  attention_line VARCHAR(120),
  sgin VARCHAR(10),
  frn VARCHAR(20)
) ENGINE=InnoDB;

-- Callbook-friendly view
--
-- IMPORTANT:
-- The FCC license class is sourced from AM.dat and loaded into the "am" table.
-- Therefore we join hd + en + am so public queries can return operator class.
CREATE OR REPLACE VIEW v_callbook AS
SELECT
  TRIM(hd.call_sign) AS callsign,
  COALESCE(
    NULLIF(TRIM(en.entity_name), ''),
    CONCAT_WS(' ', TRIM(en.first_name), TRIM(en.last_name))
  ) AS licensee_name,
  TRIM(en.street_address) AS street,
  TRIM(en.city) AS city,
  TRIM(en.state) AS state,
  TRIM(en.zip_code) AS zip,
  hd.license_status,
  hd.grant_date,
  hd.expired_date,
  hd.last_action_date,

  -- License class code (E/A/G/T/N) from AM.dat -> am.operator_class
  am.operator_class AS operator_class,

  -- Human-friendly license class name
CASE
  WHEN am.operator_class = 'E' THEN 'Extra'
  WHEN am.operator_class = 'A' THEN 'Advanced'
  WHEN am.operator_class = 'G' THEN 'General'
  WHEN am.operator_class = 'T' THEN 'Technician'
  WHEN am.operator_class = 'N' THEN 'Novice'
  WHEN am.operator_class IS NULL
       AND NULLIF(TRIM(en.entity_name), '') IS NOT NULL
    THEN 'Club'
  ELSE NULL
END AS operator_class_name

FROM hd
LEFT JOIN en
  ON en.unique_system_identifier = hd.unique_system_identifier
LEFT JOIN am
  ON am.unique_system_identifier = hd.unique_system_identifier;
