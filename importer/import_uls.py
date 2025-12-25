#!/usr/bin/env python3
"""
import_uls.py
Edward Moss - N0LJD
-------------------


Downloads the FCC ULS Amateur license data package (l_amat.zip),
extracts key .dat files (HD.dat, EN.dat, AM.dat), loads them into MariaDB,
and builds a "callbook-friendly" view used by the XML API.

Key Notes:
- We load raw FCC data into STAGING tables (stg_hd, stg_en, stg_am).
- We merge staging into FINAL tables (hd, en, am).
- We do NOT try to "interpret" data during import beyond basic cleaning.
  Presentation logic (joins, derived fields, labels like "Club") belongs in schema.sql
  via CREATE OR REPLACE VIEW v_callbook.

Important FCC nuance:
- AM.dat contains the authoritative amateur operator class (field 6).
- Some club/station licenses legitimately have operator_class = NULL.
  The view can map those to "Club" (searched CASE) for user-friendly output.
"""

import os
import pathlib
import zipfile
import requests
import pymysql
from typing import List


# ----------------------------
# Configuration (environment)
# ----------------------------

# FCC ULS Amateur "Licenses" package (l_amat.zip)
FCC_AMAT_URL = os.environ.get(
    "FCC_AMAT_URL",
    "https://data.fcc.gov/download/pub/uls/complete/l_amat.zip"
)

# Where the ZIP and extracted .dat files live (usually a Docker volume mounted at /data)
DATA_DIR = pathlib.Path(os.environ.get("DATA_DIR", "/data"))
EXTRACT_DIR = DATA_DIR / "extract"
ZIP_PATH = DATA_DIR / "l_amat.zip"

# MariaDB connection settings (service name "uls-mariadb" when using docker compose)
DB_HOST = os.environ.get("DB_HOST", "uls-mariadb")
DB_NAME = os.environ.get("DB_NAME", "uls")
DB_USER = os.environ.get("DB_USER", "uls")
DB_PASS = os.environ.get("DB_PASS", "")

# Schema file path inside the importer container
SCHEMA_PATH = pathlib.Path("/app/schema.sql")


# ----------------------------
# Logging helper
# ----------------------------

def log(msg: str) -> None:
    """Consistent log output that plays nicely with docker logs."""
    print(msg, flush=True)


# ----------------------------
# Download / extract helpers
# ----------------------------

def download_zip(url: str, dest: pathlib.Path) -> None:
    """
    Download the FCC ZIP to 'dest'.

    We skip download if the file already exists and is "reasonably large".
    This avoids re-downloading 150MB+ weekly unless you delete the file.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)

    # Skip download if file exists and is reasonably large (>50MB)
    if dest.exists() and dest.stat().st_size > 50_000_000:
        log(f"[SKIP] ZIP exists: {dest} ({dest.stat().st_size} bytes)")
        return

    log(f"[DL] {url}")
    try:
        with requests.get(url, stream=True, timeout=180) as r:
            r.raise_for_status()
            with open(dest, "wb") as f:
                for chunk in r.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        f.write(chunk)
    except Exception as e:
        raise SystemExit(f"[ERR] Download failed: {e}") from e

    log(f"[OK] Downloaded: {dest} ({dest.stat().st_size} bytes)")


def extract_zip(zip_path: pathlib.Path, extract_dir: pathlib.Path) -> None:
    """
    Extract the FCC ZIP into extract_dir.

    Note: This overwrites existing extracted files with the same names.
    """
    extract_dir.mkdir(parents=True, exist_ok=True)

    log(f"[UNZIP] {zip_path} -> {extract_dir}")
    try:
        with zipfile.ZipFile(zip_path, "r") as z:
            z.extractall(extract_dir)
    except Exception as e:
        raise SystemExit(f"[ERR] Extract failed: {e}") from e

    log("[OK] Extract complete")


def to_utf8(src: pathlib.Path) -> pathlib.Path:
    """
    Convert FCC .dat files to UTF-8 (safe for names/addresses).

    FCC data is often compatible with latin-1; latin-1 decode never fails.
    errors='replace' ensures bad bytes won't crash the import.
    """
    dst = src.with_suffix(src.suffix + ".utf8")
    log(f"[ICONV] {src.name} -> {dst.name}")

    with open(src, "rb") as f_in, open(dst, "wb") as f_out:
        for line in f_in:
            f_out.write(line.decode("latin-1", errors="replace").encode("utf-8"))
    return dst


# ----------------------------
# DB load helpers
# ----------------------------

def load_local_infile(conn, table: str, path: pathlib.Path, columns: str) -> None:
    """
    Load a UTF-8 .dat file into a staging table.

    We special-case HD and AM because:
      - HD.dat has many fields (59). We only care about a subset.
      - AM.dat is where the "real" operator class lives (field 6).
    """
    log(f"[LOAD] {table} <- {path.name}")

    with conn.cursor() as cur:
        # Truncate staging first to keep loads deterministic each run
        cur.execute(f"TRUNCATE TABLE {table};")

        # HD.dat (59 fields): do NOT attempt to load operator class from HD.
        if table == "stg_hd":
            vars_list = ", ".join([f"@f{i}" for i in range(1, 60)])  # @f1..@f59

            sql = f"""
LOAD DATA LOCAL INFILE '{path.as_posix()}'
INTO TABLE stg_hd
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '|'
LINES TERMINATED BY '\\n'
({vars_list})
SET
  record_type = NULLIF(@f1,''),
  unique_system_identifier = NULLIF(@f2,''),
  call_sign = NULLIF(@f5,''),
  license_status = NULLIF(@f6,''),
  grant_date = NULLIF(@f8,''),
  expired_date = NULLIF(@f9,''),
  last_action_date = NULLIF(@f10,'');
"""
            cur.execute(sql)
            log(f"[OK] Loaded {table} (HD mapped fields: 1,2,5,6,8,9,10)")
            return

        # AM.dat (18 fields): operator class is field 6 (E/A/G/T/N, sometimes NULL)
        if table == "stg_am":
            vars_list = ", ".join([f"@f{i}" for i in range(1, 19)])  # @f1..@f18

            sql = f"""
LOAD DATA LOCAL INFILE '{path.as_posix()}'
INTO TABLE stg_am
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '|'
LINES TERMINATED BY '\\n'
({vars_list})
SET
  record_type = NULLIF(@f1,''),
  unique_system_identifier = NULLIF(@f2,''),
  uls_file_number = NULLIF(@f3,''),
  ebf_number = NULLIF(@f4,''),
  call_sign = NULLIF(@f5,''),
  operator_class = NULLIF(@f6,'');
"""
            cur.execute(sql)
            log(f"[OK] Loaded {table} (AM mapped fields: 1,2,3,4,5,6[class])")
            return

        # Default loader (EN, etc.) using the provided column list
        sql = f"""
LOAD DATA LOCAL INFILE '{path.as_posix()}'
INTO TABLE {table}
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '|'
LINES TERMINATED BY '\\n'
({columns});
"""
        cur.execute(sql)

    log(f"[OK] Loaded {table}")


def merge_into_final(conn) -> None:
    """
    Merge staging tables into final tables.

    NOTE:
    - Operator class is sourced from AM.dat -> stg_am -> am.
    - The view v_callbook joins hd + en + am.
    """
    log("[DB] Merging staging -> final tables")

    with conn.cursor() as cur:
        # stg_hd -> hd (license header)
        cur.execute("""
            INSERT INTO hd (
                record_type,
                unique_system_identifier,
                call_sign,
                license_status,
                grant_date,
                expired_date,
                last_action_date
            )
            SELECT
                record_type,
                unique_system_identifier,
                LEFT(TRIM(call_sign), 10),
                LEFT(TRIM(license_status), 1),
                STR_TO_DATE(NULLIF(grant_date,''), '%m/%d/%Y'),
                STR_TO_DATE(NULLIF(expired_date,''), '%m/%d/%Y'),
                STR_TO_DATE(NULLIF(last_action_date,''), '%m/%d/%Y')
            FROM stg_hd
            WHERE unique_system_identifier IS NOT NULL
            ON DUPLICATE KEY UPDATE
                call_sign=VALUES(call_sign),
                license_status=VALUES(license_status),
                grant_date=VALUES(grant_date),
                expired_date=VALUES(expired_date),
                last_action_date=VALUES(last_action_date);
        """)

        # stg_en -> en (entity / name / address)
        cur.execute("""
            INSERT INTO en (
                record_type,
                unique_system_identifier,
                call_sign,
                entity_name,
                first_name,
                last_name,
                street_address,
                city,
                state,
                zip_code
            )
            SELECT
                record_type,
                unique_system_identifier,
                LEFT(TRIM(call_sign), 10),
                NULLIF(TRIM(entity_name),''),
                NULLIF(TRIM(first_name),''),
                NULLIF(TRIM(last_name),''),
                NULLIF(TRIM(street_address),''),
                NULLIF(TRIM(city),''),
                LEFT(TRIM(state), 2),
                LEFT(TRIM(zip_code), 10)
            FROM stg_en
            WHERE unique_system_identifier IS NOT NULL
            ON DUPLICATE KEY UPDATE
                call_sign=VALUES(call_sign),
                entity_name=VALUES(entity_name),
                first_name=VALUES(first_name),
                last_name=VALUES(last_name),
                street_address=VALUES(street_address),
                city=VALUES(city),
                state=VALUES(state),
                zip_code=VALUES(zip_code);
        """)

        # stg_am -> am (operator class / license class)
        cur.execute("""
            INSERT INTO am (unique_system_identifier, call_sign, operator_class)
            SELECT
                unique_system_identifier,
                LEFT(TRIM(call_sign), 10),
                LEFT(TRIM(operator_class), 1)
            FROM stg_am
            WHERE unique_system_identifier IS NOT NULL
            ON DUPLICATE KEY UPDATE
                call_sign=VALUES(call_sign),
                operator_class=VALUES(operator_class);
        """)

    log("[OK] Merge complete")


def connect_db():
    """
    Connect to MariaDB with LOCAL INFILE enabled (required for LOAD DATA LOCAL INFILE).
    DictCursor makes count queries and diagnostics easy to read.
    """
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        autocommit=True,
        local_infile=True,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )


# ----------------------------
# Schema application
# ----------------------------

def _split_sql_statements(sql: str) -> List[str]:
    """
    Very small SQL splitter.

    Assumption: schema.sql is "simple" DDL where splitting on ';' works.
    (No stored procedures, triggers, or custom DELIMITER sections.)

    We also remove:
    - empty statements
    - full-line comments starting with '--'
    """
    # Strip UTF-8 BOM if present (common if edited in some Windows tools)
    sql = sql.lstrip("\ufeff")

    raw = [s.strip() for s in sql.split(";")]
    statements: List[str] = []

    for stmt in raw:
        if not stmt:
            continue

        # Remove leading comment-only blocks quickly
        lines = [ln for ln in stmt.splitlines() if ln.strip()]

        # If everything left is '-- comment', skip it
        non_comment = []
        for ln in lines:
            stripped = ln.strip()
            if stripped.startswith("--"):
                continue
            non_comment.append(ln)

        cleaned = "\n".join(non_comment).strip()
        if cleaned:
            statements.append(cleaned)

    return statements


def apply_schema(conn) -> None:
    """
    Apply schema.sql on each run.

    Keep schema.sql idempotent:
    - CREATE TABLE IF NOT EXISTS
    - DROP TABLE IF EXISTS (for staging tables)
    - CREATE OR REPLACE VIEW
    """
    sql = SCHEMA_PATH.read_text(encoding="utf-8")
    statements = _split_sql_statements(sql)

    log(f"[DB] Applying schema ({len(statements)} statements)")
    with conn.cursor() as cur:
        for i, stmt in enumerate(statements, start=1):
            try:
                cur.execute(stmt + ";")
            except Exception as e:
                # Print which statement failed and a short snippet for fast debugging
                snippet = stmt.replace("\n", " ")[:200]
                raise SystemExit(f"[ERR] Schema failed at statement {i}/{len(statements)}: {e}\n"
                                 f"      SQL: {snippet}...") from e
    log("[OK] Schema applied")


# ----------------------------
# Main workflow
# ----------------------------

def main():
    log("[START] ULS import starting")

    # 1) Ensure directories exist
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # 2) Apply schema (tables + view)
    conn = connect_db()
    try:
        apply_schema(conn)
    finally:
        conn.close()

    # 3) Download FCC file
    download_zip(FCC_AMAT_URL, ZIP_PATH)

    # 4) Extract and verify expected files exist
    extract_zip(ZIP_PATH, EXTRACT_DIR)

    hd = EXTRACT_DIR / "HD.dat"
    en = EXTRACT_DIR / "EN.dat"
    am = EXTRACT_DIR / "AM.dat"

    for f in (hd, en, am):
        if not f.exists():
            raise SystemExit(f"[ERR] Missing {f} after extract")

    log(f"[OK] Found: {hd} ({hd.stat().st_size} bytes)")
    log(f"[OK] Found: {en} ({en.stat().st_size} bytes)")
    log(f"[OK] Found: {am} ({am.stat().st_size} bytes)")

    # 5) Convert to UTF-8 for safe loading
    hd_u8 = to_utf8(hd)
    en_u8 = to_utf8(en)
    am_u8 = to_utf8(am)

    # 6) Load into DB (staging tables), then merge to final
    conn = connect_db()
    try:
        # EN staging columns MUST match stg_en table definition in schema.sql
        stg_en_cols = ",".join([
            "record_type","unique_system_identifier","uls_file_number","ebf_number","call_sign",
            "entity_type","licensee_id","entity_name","first_name","mi","last_name","suffix",
            "phone","fax","email","street_address","city","state","zip_code","po_box",
            "attention_line","sgin","frn"
        ])

        # For stg_hd and stg_am, the loader ignores `columns` due to explicit mapping
        load_local_infile(conn, "stg_hd", hd_u8, "record_type")
        load_local_infile(conn, "stg_en", en_u8, stg_en_cols)
        load_local_infile(conn, "stg_am", am_u8, "record_type")

        merge_into_final(conn)

        # ----------------------------
        # Diagnostics / sanity checks
        # ----------------------------
        with conn.cursor() as cur:
            # Final table counts
            cur.execute("SELECT COUNT(*) AS c FROM hd;")
            hd_count = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(*) AS c FROM en;")
            en_count = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(*) AS c FROM am;")
            am_count = cur.fetchone()["c"]

            # Class distribution (top few)
            cur.execute("""
                SELECT operator_class, COUNT(*) AS cnt
                FROM am
                GROUP BY operator_class
                ORDER BY cnt DESC
                LIMIT 10;
            """)
            class_rows = cur.fetchall()

            # View-level sanity: how many are labeled 'Club'?
            # (This confirms your searched CASE logic is active in v_callbook)
            cur.execute("""
                SELECT
                  SUM(operator_class_name = 'Club') AS club_rows,
                  SUM(operator_class_name IS NULL) AS null_name_rows,
                  COUNT(*) AS total_rows
                FROM v_callbook;
            """)
            v_diag = cur.fetchone()

        log(f"[DONE] Loaded: hd={hd_count} en={en_count} am={am_count}")

        log("[DIAG] License class distribution (am.operator_class):")
        for r in class_rows:
            oc = r["operator_class"]
            cnt = r["cnt"]
            log(f"  class={oc if oc is not None else 'NULL'} cnt={cnt}")

        log("[DIAG] v_callbook operator_class_name:")
        log(f"  club_rows={v_diag['club_rows']} null_name_rows={v_diag['null_name_rows']} total_rows={v_diag['total_rows']}")

    finally:
        conn.close()

    log("[END] ULS import complete")


if __name__ == "__main__":
    main()
