#!/usr/bin/env python3
"""
import_uls.py
Edward Moss - N0LJD
-------------------

Purpose
-------
ARCS "uls-importer" entrypoint.

Downloads the FCC ULS Amateur license data package (l_amat.zip),
extracts key .dat files (HD.dat, EN.dat, AM.dat), loads them into MariaDB,
and builds a callbook-friendly view used by the XML API.

Design goals (v1.0+)
--------------------
This importer keeps three categories of truth:

1) Local execution truth (what ARCS did):
   - last_run_started_at / last_run_finished_at
   - last_run_result / last_run_skip_reason

2) Local data truth (what changed locally):
   - local_data_updated_at (only moves forward on successful imports)

3) Upstream provenance (what FCC provided):
   - source_* fields derived from HTTP headers + downloaded ZIP
     (ETag, Last-Modified, SHA256, bytes)

Features (cron/CI friendly)
---------------------------
1) Locking (--lock / --no-lock)
   - Prevents overlapping imports by acquiring a DB-level named lock:
       SELECT GET_LOCK('arcs:uls_import', 0);
   - Default: lock ENABLED.

2) Skip if unchanged (--skip-if-unchanged)
   - Avoids re-importing if the upstream ZIP has not changed.
   - Primary signal: HTTP HEAD metadata (ETag / Last-Modified) compared to prior.
   - Fallback: SHA-256 of the existing local ZIP (if present) compared to prior.
   - Default: skip-if-unchanged DISABLED (opt-in).

3) Canonical state file
   - Writes importer state to:
       /logs/arcs-state.json    (container; compose should mount ./logs -> /logs)
   - Namespace used: "uls_import"

4) Lightweight marker (used for quick eyeballing AND as a fallback prior source)
   - Writes:
       /logs/.last_import
   - Can be overridden via --meta-path (see CLI)

Exit codes
----------
0 = success OR "skipped (lock held)" OR "skipped (unchanged)"
1 = hard failure
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

import pymysql
import requests


# ----------------------------
# Configuration (environment)
# ----------------------------

FCC_AMAT_URL = os.environ.get(
    "FCC_AMAT_URL",
    "https://data.fcc.gov/download/pub/uls/complete/l_amat.zip",
)

DATA_DIR = pathlib.Path(os.environ.get("DATA_DIR", "/data"))
EXTRACT_DIR = DATA_DIR / "extract"
ZIP_PATH = DATA_DIR / "l_amat.zip"

SCHEMA_PATH = pathlib.Path("/app/schema.sql")

# Canonical state file (compose should mount ./logs -> /logs)
STATE_PATH = pathlib.Path(os.environ.get("ARCS_STATE_PATH", "/logs/arcs-state.json"))
STATE_NAMESPACE = "uls_import"

# Lightweight marker (also used as fallback prior source if canonical is empty)
DEFAULT_LAST_IMPORT_PATH = pathlib.Path(os.environ.get("ARCS_LAST_IMPORT_PATH", "/logs/.last_import"))


def _read_secret(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


DB_HOST = os.environ.get("DB_HOST", "uls-mariadb")
DB_NAME = os.environ.get("DB_NAME", "uls")
DB_USER = os.environ.get("DB_USER", "uls")

DB_PASS = os.environ.get("DB_PASS", "")
DB_PASS_FILE = os.environ.get("DB_PASS_FILE")
if DB_PASS_FILE:
    DB_PASS = _read_secret(DB_PASS_FILE)


# ----------------------------
# Logging helper
# ----------------------------

def log(msg: str) -> None:
    print(msg, flush=True)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


# ----------------------------
# JSON helpers (atomic read/write)
# ----------------------------

def _load_json(path: pathlib.Path) -> Dict[str, Any]:
    if not path.exists():
        return {}
    try:
        txt = path.read_text(encoding="utf-8", errors="replace").strip()
        if not txt:
            return {}
        obj = json.loads(txt)
        return obj if isinstance(obj, dict) else {}
    except Exception:
        return {}


def _atomic_write_json(path: pathlib.Path, obj: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def read_state_namespace(path: pathlib.Path, ns: str) -> Dict[str, Any]:
    state = _load_json(path)
    val = state.get(ns, {})
    return val if isinstance(val, dict) else {}


def merge_state_namespace(path: pathlib.Path, ns: str, updates: Dict[str, Any]) -> None:
    state = _load_json(path)
    if ns not in state or not isinstance(state.get(ns), dict):
        state[ns] = {}
    state[ns].update(updates)
    _atomic_write_json(path, state)


def write_last_import_marker(path: pathlib.Path, updates: Dict[str, Any]) -> None:
    try:
        _atomic_write_json(path, updates)
    except Exception as e:
        log(f"[WARN] Could not write last import marker {path}: {e}")


# ----------------------------
# Remote metadata + hashing
# ----------------------------

@dataclass
class RemoteMeta:
    etag: str = ""
    last_modified: str = ""
    content_length: int = 0


def head_remote_meta(url: str, timeout: int = 30) -> RemoteMeta:
    try:
        r = requests.head(url, allow_redirects=True, timeout=timeout)
        if r.status_code < 200 or r.status_code >= 400:
            return RemoteMeta()
        etag = (r.headers.get("ETag") or "").strip()
        last_mod = (r.headers.get("Last-Modified") or "").strip()
        clen = r.headers.get("Content-Length")
        try:
            content_length = int(clen) if clen else 0
        except Exception:
            content_length = 0
        return RemoteMeta(etag=etag, last_modified=last_mod, content_length=content_length)
    except Exception:
        return RemoteMeta()


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def should_skip_import(
    *,
    skip_if_unchanged: bool,
    remote: RemoteMeta,
    zip_path: pathlib.Path,
    prior: Dict[str, Any],
) -> Tuple[bool, str]:
    """
    Decide whether to skip the entire import.

    Decision order:
      1) If skip_if_unchanged is False -> do not skip
      2) If remote ETag or Last-Modified matches prior -> skip
      3) Else if local zip exists and its SHA matches prior -> skip
      4) Else -> do not skip
    """
    if not skip_if_unchanged:
        return False, "skip-if-unchanged disabled"

    prior_etag = str(prior.get("source_etag") or "").strip()
    prior_lm = str(prior.get("source_last_modified_at") or "").strip()
    prior_sha = str(prior.get("source_zip_sha256") or "").strip()

    if remote.etag and prior_etag and remote.etag == prior_etag:
        return True, "etag match"
    if remote.last_modified and prior_lm and remote.last_modified == prior_lm:
        return True, "last-modified match"

    if zip_path.exists() and prior_sha:
        try:
            local_sha = sha256_file(zip_path)
            if local_sha == prior_sha:
                return True, "local zip sha256 match"
        except Exception:
            pass

    return False, "no unchanged signal matched"


# ----------------------------
# Download / extract helpers
# ----------------------------

def download_zip(url: str, dest: pathlib.Path, remote: RemoteMeta) -> Tuple[str, int]:
    """
    Download the FCC ZIP to 'dest' (atomic download via temp file).
    Returns (sha256, bytes_on_disk).
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + f".tmp.{os.getpid()}")

    log(f"[DL] {url}")
    try:
        with requests.get(url, stream=True, timeout=180) as r:
            r.raise_for_status()
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        f.write(chunk)
    except Exception as e:
        tmp.unlink(missing_ok=True)
        raise SystemExit(f"[ERR] Download failed: {e}") from e

    tmp.replace(dest)
    size = dest.stat().st_size
    digest = sha256_file(dest)

    log(f"[OK] Downloaded: {dest} ({size} bytes)")
    log(f"[OK] ZIP sha256: {digest}")

    if remote.content_length and remote.content_length != size:
        log(f"[WARN] Content-Length mismatch: head={remote.content_length} downloaded={size}")

    return digest, size


def extract_zip(zip_path: pathlib.Path, extract_dir: pathlib.Path) -> None:
    extract_dir.mkdir(parents=True, exist_ok=True)
    log(f"[UNZIP] {zip_path} -> {extract_dir}")
    try:
        with zipfile.ZipFile(zip_path, "r") as z:
            z.extractall(extract_dir)
    except Exception as e:
        raise SystemExit(f"[ERR] Extract failed: {e}") from e
    log("[OK] Extract complete")


def to_utf8(src: pathlib.Path) -> pathlib.Path:
    dst = src.with_suffix(src.suffix + ".utf8")
    log(f"[ICONV] {src.name} -> {dst.name}")
    with open(src, "rb") as f_in, open(dst, "wb") as f_out:
        for line in f_in:
            f_out.write(line.decode("latin-1", errors="replace").encode("utf-8"))
    return dst


# ----------------------------
# DB helpers (connect + lock)
# ----------------------------

def connect_db():
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


LOCK_NAME = "arcs:uls_import"


def acquire_db_lock(conn, lock_name: str = LOCK_NAME) -> bool:
    with conn.cursor() as cur:
        cur.execute("SELECT GET_LOCK(%s, 0) AS got;", (lock_name,))
        row = cur.fetchone()
        got = row.get("got") if row else None
        return bool(got == 1)


def release_db_lock(conn, lock_name: str = LOCK_NAME) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT RELEASE_LOCK(%s) AS rel;", (lock_name,))


# ----------------------------
# DB load helpers
# ----------------------------

def load_local_infile(conn, table: str, path: pathlib.Path, columns: str) -> None:
    log(f"[LOAD] {table} <- {path.name}")
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE TABLE {table};")

        if table == "stg_hd":
            vars_list = ", ".join([f"@f{i}" for i in range(1, 60)])
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

        if table == "stg_am":
            vars_list = ", ".join([f"@f{i}" for i in range(1, 19)])
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
    log("[DB] Merging staging -> final tables")
    with conn.cursor() as cur:
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


# ----------------------------
# Schema application
# ----------------------------

def _split_sql_statements(sql: str) -> List[str]:
    sql = sql.lstrip("\ufeff")
    raw = [s.strip() for s in sql.split(";")]
    statements: List[str] = []
    for stmt in raw:
        if not stmt:
            continue
        lines = [ln for ln in stmt.splitlines() if ln.strip()]
        non_comment = []
        for ln in lines:
            if ln.strip().startswith("--"):
                continue
            non_comment.append(ln)
        cleaned = "\n".join(non_comment).strip()
        if cleaned:
            statements.append(cleaned)
    return statements


def apply_schema(conn) -> None:
    sql = SCHEMA_PATH.read_text(encoding="utf-8")
    statements = _split_sql_statements(sql)
    log(f"[DB] Applying schema ({len(statements)} statements)")
    with conn.cursor() as cur:
        for i, stmt in enumerate(statements, start=1):
            try:
                cur.execute(stmt + ";")
            except Exception as e:
                snippet = stmt.replace("\n", " ")[:200]
                raise SystemExit(
                    f"[ERR] Schema failed at statement {i}/{len(statements)}: {e}\n"
                    f"      SQL: {snippet}..."
                ) from e
    log("[OK] Schema applied")


# ----------------------------
# CLI
# ----------------------------

def parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="ARCS uls-importer: download FCC ULS l_amat.zip and import into MariaDB.",
        formatter_class=argparse.RawTextHelpFormatter,
    )

    p.add_argument(
        "--lock",
        dest="lock",
        action="store_true",
        default=True,
        help="Enable DB named lock (default: enabled).",
    )
    p.add_argument(
        "--no-lock",
        dest="lock",
        action="store_false",
        help="Disable DB named lock (not recommended).",
    )

    p.add_argument(
        "--skip-if-unchanged",
        action="store_true",
        help="Skip the entire import when the upstream ZIP appears unchanged (ETag/Last-Modified; fallback zip sha256).",
    )

    # NOTE: name retained for compatibility with arcsctl.sh.
    # This now refers to the marker file path (prior source fallback + written on each run),
    # not any legacy bootstrap metadata.
    p.add_argument(
        "--meta-path",
        default="",
        help="Override last-import marker path (default: ARCS_LAST_IMPORT_PATH or /logs/.last_import).",
    )

    return p.parse_args(argv)


# ----------------------------
# Main workflow
# ----------------------------

def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    log("[START] ULS import starting")

    run_started = utc_now_iso()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    EXTRACT_DIR.mkdir(parents=True, exist_ok=True)
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)

    last_import_path = pathlib.Path(args.meta_path) if args.meta_path else DEFAULT_LAST_IMPORT_PATH
    last_import_path.parent.mkdir(parents=True, exist_ok=True)

    # Prior state comes from canonical state first; fallback to marker if needed.
    prior_state = read_state_namespace(STATE_PATH, STATE_NAMESPACE)
    if not prior_state:
        prior_state = _load_json(last_import_path)
        if prior_state:
            log(f"[META] Loaded prior marker: {last_import_path}")

    conn = connect_db()
    got_lock = False

    def persist(
        *,
        run_result: str,
        run_skip_reason: str = "",
        remote: Optional[RemoteMeta] = None,
        source_zip_sha256: str = "",
        source_zip_bytes: int = 0,
        did_update_local_data: bool = False,
    ) -> None:
        """
        Persist state in two places (no legacy artifacts):
          1) Canonical JSON state: /logs/arcs-state.json (namespace uls_import)
          2) Marker JSON:          /logs/.last_import (or --meta-path)

        Naming intent:
          - last_run_*   => operational truth about the most recent run attempt
          - local_data_* => only changes when the DB was actually refreshed
          - source_*     => identity/provenance of the upstream artifact
        """
        rm = remote or RemoteMeta()
        run_finished = utc_now_iso()

        prior_local_updated = str(prior_state.get("local_data_updated_at") or "").strip()
        local_updated = run_finished if did_update_local_data else prior_local_updated

        updates: Dict[str, Any] = {
            # Operational truth
            "last_run_started_at": run_started,
            "last_run_finished_at": run_finished,
            "last_run_result": run_result,
            "last_run_skip_reason": run_skip_reason,

            # Local data truth
            "local_data_updated_at": local_updated,

            # Upstream provenance / artifact identity
            "source_url": FCC_AMAT_URL,
            "source_etag": rm.etag or (prior_state.get("source_etag") or ""),
            "source_last_modified_at": rm.last_modified or (prior_state.get("source_last_modified_at") or ""),
            "source_zip_sha256": source_zip_sha256 or (prior_state.get("source_zip_sha256") or ""),
            "source_zip_bytes": int(source_zip_bytes or (prior_state.get("source_zip_bytes") or 0)),
        }

        # Canonical arcs-state.json
        try:
            merge_state_namespace(STATE_PATH, STATE_NAMESPACE, updates)
            log(f"[STATE] Updated: {STATE_PATH} (ns={STATE_NAMESPACE})")
        except Exception as e:
            log(f"[WARN] Failed to update state file {STATE_PATH}: {e}")

        # Lightweight marker
        write_last_import_marker(last_import_path, updates)
        log(f"[META] Updated: {last_import_path}")

    try:
        if args.lock:
            log(f"[LOCK] Acquiring DB lock: {LOCK_NAME}")
            got_lock = acquire_db_lock(conn)
            if not got_lock:
                log("[SKIP] Another import is already running (lock held). Exiting cleanly.")
                persist(run_result="skipped_locked", run_skip_reason="db lock held")
                return 0
            log("[LOCK] Acquired")
        else:
            log("[LOCK] Disabled (--no-lock)")

        remote = head_remote_meta(FCC_AMAT_URL)
        if remote.etag or remote.last_modified:
            log(f"[HEAD] etag={remote.etag or '(none)'} last_modified={remote.last_modified or '(none)'}")
        else:
            log("[HEAD] No usable ETag/Last-Modified (or HEAD failed). Will rely on sha fallback if needed.")

        skip, reason = should_skip_import(
            skip_if_unchanged=args.skip_if_unchanged,
            remote=remote,
            zip_path=ZIP_PATH,
            prior=prior_state,
        )
        if skip:
            log(f"[SKIP] Import skipped: {reason}")
            persist(run_result="skipped_unchanged", run_skip_reason=reason, remote=remote)
            return 0

        apply_schema(conn)

        sha, bytes_on_disk = download_zip(FCC_AMAT_URL, ZIP_PATH, remote)

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

        hd_u8 = to_utf8(hd)
        en_u8 = to_utf8(en)
        am_u8 = to_utf8(am)

        stg_en_cols = ",".join([
            "record_type","unique_system_identifier","uls_file_number","ebf_number","call_sign",
            "entity_type","licensee_id","entity_name","first_name","mi","last_name","suffix",
            "phone","fax","email","street_address","city","state","zip_code","po_box",
            "attention_line","sgin","frn"
        ])

        load_local_infile(conn, "stg_hd", hd_u8, "record_type")
        load_local_infile(conn, "stg_en", en_u8, stg_en_cols)
        load_local_infile(conn, "stg_am", am_u8, "record_type")

        merge_into_final(conn)

        # Diagnostics / sanity output
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS c FROM hd;")
            hd_count = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(*) AS c FROM en;")
            en_count = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(*) AS c FROM am;")
            am_count = cur.fetchone()["c"]

            cur.execute("""
                SELECT operator_class, COUNT(*) AS cnt
                FROM am
                GROUP BY operator_class
                ORDER BY cnt DESC
                LIMIT 10;
            """)
            class_rows = cur.fetchall()

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

        # Success means local DB was refreshed; advance local_data_updated_at
        persist(
            run_result="success",
            run_skip_reason="",
            remote=remote,
            source_zip_sha256=sha,
            source_zip_bytes=bytes_on_disk,
            did_update_local_data=True,
        )

        log("[END] ULS import complete")
        return 0

    finally:
        try:
            if got_lock:
                release_db_lock(conn)
                log("[LOCK] Released")
        except Exception as e:
            log(f"[WARN] Failed to release DB lock: {e}")
        try:
            conn.close()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
