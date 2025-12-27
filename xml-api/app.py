"""
app.py
------
ARCS API (HamQTH-compatible XML) for FCC ULS-backed callbook lookups.

Endpoints
---------
GET /health

GET /xml.php?callsign=<CALLSIGN>[&raw=0|1][&prg=...][&id=...]
  - Callsign lookup (single best match)

GET /xml.php?action=search&callsign=...&name=...&city=...&state=...&zip=...&limit=...&offset=...
  - Advanced search (multiple matches)

Design goals
------------
- "Compatible-plus": callsign lookup works without HamQTH session auth.
- HamQTH-ish envelope: version/xmlns included for compatibility.
- Search features:
  - substring matching (LIKE %term%)
  - all words must appear (tokens AND'ed)
  - callsign wildcard '*' supported
- Search guardrails:
  - default limit=100 (env DEFAULT_SEARCH_LIMIT)
  - limit=0 means unlimited
  - require >=2 constraints unless callsign is the only constraint
- Callsign-only search behavior (practical default):
  - If callsign has NO wildcard: exact match (callsign = X)
  - If callsign includes '*': wildcard match (LIKE)
  - Portable suffix fallback (W1AW/P -> W1AW) only for exact (no wildcard) callsign-only searches
- Safe SQL:
  - all WHERE predicates are parameterized
  - LIMIT/OFFSET are embedded as integers (MariaDB can reject quoted values there)

Notes
-----
- DB access should be READ-ONLY (SELECT on uls.v_callbook).
- prg/id are accepted and ignored for now (future session auth / telemetry).
"""

from __future__ import annotations

import os
import re
import uuid
from typing import Dict, List, Optional, Tuple

import pymysql
from fastapi import FastAPI, Query, Response
from fastapi.middleware.cors import CORSMiddleware

APP_TITLE = "ARCS API"
app = FastAPI(title=APP_TITLE)

# -------------------------------------------------------------------
# CORS (Browser access)
# -------------------------------------------------------------------
# The web UI is typically served from a different origin (port 8081) than the API (port 8080).
# Browsers enforce CORS, so we explicitly allow the UI origin(s).
#
# If you later put both behind one reverse proxy (nginx/caddy) under the same origin,
# you can remove or tighten this.
CORS_ALLOW_ORIGINS = [
    os.environ.get("CORS_ALLOW_ORIGIN", "http://192.168.1.121:8081"),
    "http://127.0.0.1:8081",
    "http://localhost:8081",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o for o in CORS_ALLOW_ORIGINS if o],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# ----------------------------
# Environment / Configuration
# ----------------------------
DB_HOST = os.environ.get("DB_HOST", "uls-mariadb")
DB_NAME = os.environ.get("DB_NAME", "uls")
DB_USER = os.environ.get("DB_USER", "callbook_ro")

# Password may be provided directly (DB_PASS) or via a mounted secret file (DB_PASS_FILE).
# DB_PASS_FILE takes precedence if set.
DB_PASS = os.environ.get("DB_PASS", "")
DB_PASS_FILE = os.environ.get("DB_PASS_FILE")

DEFAULT_SEARCH_LIMIT = int(os.environ.get("DEFAULT_SEARCH_LIMIT", "100"))

# Canonical XML response media type
XML_MEDIA_TYPE = "application/xml; charset=utf-8"
XML_HEADERS = {"Content-Type": XML_MEDIA_TYPE}

# Basic callsign sanity check: letters/numbers and optional portable suffix with '/'
CALLSIGN_RE = re.compile(r"^[A-Z0-9/]{1,16}$")

# HamQTH 'prg' guidance is basically "no spaces"; we accept a safe subset.
PRG_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")


def _read_secret(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


if DB_PASS_FILE:
    DB_PASS = _read_secret(DB_PASS_FILE)


def db_conn():
    """Open a new DB connection per request (fine for low volume)."""
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        autocommit=True,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )


# ----------------------------
# XML helpers
# ----------------------------
def xml_escape(s: str) -> str:
    """Minimal XML escaping for element contents."""
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def hamqth_envelope_start(session_id: str, error: str = "OK") -> str:
    """HamQTH-ish envelope with version and xmlns commonly used by clients."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<HamQTH version="2.7" xmlns="https://www.hamqth.com">
  <session>
    <session_id>{xml_escape(session_id)}</session_id>
    <error>{xml_escape(error)}</error>
  </session>
"""


def hamqth_envelope_end() -> str:
    return "</HamQTH>\n"


def hamqth_error_xml(message: str, callsign: str = "", result: int = 0) -> str:
    """
    Return a generic HamQTH-ish error response.
    We intentionally avoid leaking internal details to the caller.
    """
    sid = str(uuid.uuid4())
    xml = hamqth_envelope_start(sid, error=message)
    xml += f"""  <search>
    <callsign>{xml_escape(callsign)}</callsign>
    <result>{result}</result>
    <error>{xml_escape(message)}</error>
  </search>
"""
    xml += hamqth_envelope_end()
    return xml


def _safe_str(v) -> str:
    return "" if v is None else str(v)


# ----------------------------
# Search helpers
# ----------------------------
def _normalize_ws(s: str) -> str:
    """Strip and collapse internal whitespace."""
    return " ".join(s.strip().split())


def _split_tokens(s: str) -> List[str]:
    """Split on whitespace into non-empty tokens."""
    s = _normalize_ws(s)
    return [t for t in s.split(" ") if t]


def _escape_like(term: str) -> str:
    """
    Escape LIKE wildcards so user input doesn't become an unintended pattern.
    We'll re-introduce controlled wildcard behavior explicitly (e.g., '*' for callsign).
    """
    term = term.replace("\\", "\\\\")
    term = term.replace("%", "\\%")
    term = term.replace("_", "\\_")
    return term


def _callsign_pattern(user_callsign: str) -> str:
    """
    Convert user callsign input into a safe LIKE pattern:
      - uppercase
      - escape % and _
      - translate '*' to '%' (wildcard)
    """
    cs = user_callsign.strip().upper()
    cs = _escape_like(cs)
    cs = cs.replace("*", "%")
    return cs


def _count_constraints(callsign: str, name: str, city: str, state: str, zip_code: str) -> int:
    """Count how many of the constraint fields are non-empty."""
    fields = [callsign, name, city, state, zip_code]
    return sum(1 for f in fields if f and f.strip())


def _portable_base(callsign: str) -> str:
    """Strip portable suffix (W1AW/P -> W1AW)."""
    return callsign.split("/", 1)[0] if "/" in callsign else callsign


# ----------------------------
# Endpoints
# ----------------------------
@app.get("/health")
def health():
    return {"ok": True, "service": APP_TITLE}


@app.get(
    "/xml.php",
    response_class=Response,
    responses={200: {"content": {"application/xml": {"schema": {"type": "string"}}}}},
    openapi_extra={"responses": {"200": {"content": {"application/xml": {"schema": {"type": "string"}}}}}},
)
def xml_api(
    # Mode selection
    action: Optional[str] = Query(None),

    # Callsign lookup params
    callsign: Optional[str] = Query(None, min_length=1, max_length=16),
    raw: int = Query(0, ge=0, le=1),

    # HamQTH-ish compatibility params (accepted, ignored for now)
    prg: Optional[str] = Query(None),
    id: Optional[str] = Query(None),

    # Advanced search params (used when action=search)
    name: Optional[str] = Query(None, max_length=200),
    city: Optional[str] = Query(None, max_length=80),
    state: Optional[str] = Query(None, max_length=2),
    zip: Optional[str] = Query(None, max_length=20),

    # Search paging controls
    limit: Optional[int] = Query(None, ge=0),
    offset: int = Query(0, ge=0),
):
    """
    Combined endpoint:
      - Callsign lookup when action != 'search'
      - Advanced search when action=search
    """

    # Accept/ignore prg safely (never error for compatibility)
    if prg:
        p = prg.strip()
        prg = p if PRG_RE.match(p) else None

    # ============================
    # SEARCH MODE
    # ============================
    if action and action.strip().lower() == "search":
        cs = (callsign or "").strip()
        nm = (name or "").strip()
        ct = (city or "").strip()
        st = (state or "").strip().upper()
        zp = (zip or "").strip()

        # Callsign-only is allowed as a single constraint.
        # We treat callsign-only searches as:
        #   - exact match if no wildcard '*'
        #   - wildcard match if '*' is present
        callsign_only = bool(cs) and not any([nm, ct, st, zp])
        callsign_has_wildcard = "*" in cs

        callsign_only_exact = callsign_only and (not callsign_has_wildcard)
        callsign_only_wildcard = callsign_only and callsign_has_wildcard

        # Guardrail: require >=2 constraints unless callsign is the only constraint.
        if (not callsign_only) and _count_constraints(cs, nm, ct, st, zp) < 2:
            xml = hamqth_error_xml(
                "Search requires at least two constraints (callsign, name, city, state, zip), "
                "unless callsign is the only constraint.",
                callsign=cs,
                result=0,
            )
            return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

        # Effective limit: default to env/100 if not provided
        eff_limit = DEFAULT_SEARCH_LIMIT if limit is None else int(limit)

        # Build WHERE clauses + parameter list (all parameterized)
        where: List[str] = []
        params: List[str] = []

        if cs:
            if callsign_only_exact:
                # Exact callsign match (predictable behavior for a specific callsign)
                where.append("callsign = %s")
                params.append(cs.strip().upper())
            else:
                # Wildcard/multi-field searches use LIKE patterns
                pattern = _callsign_pattern(cs)
                where.append("callsign LIKE %s ESCAPE '\\\\'")
                params.append(pattern)

        if nm:
            for token in _split_tokens(nm.upper()):
                tok = _escape_like(token)
                where.append("UPPER(licensee_name) LIKE %s ESCAPE '\\\\'")
                params.append(f"%{tok}%")

        if ct:
            for token in _split_tokens(ct.upper()):
                tok = _escape_like(token)
                where.append("UPPER(city) LIKE %s ESCAPE '\\\\'")
                params.append(f"%{tok}%")

        if st:
            if len(st) != 2 or not st.isalpha():
                xml = hamqth_error_xml("Invalid state (must be 2 letters).", callsign=cs, result=0)
                return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)
            where.append("state = %s")
            params.append(st)

        if zp:
            # ZIP prefix match is usually most useful (handles ZIP+4)
            tok = _escape_like(zp)
            where.append("zip LIKE %s ESCAPE '\\\\'")
            params.append(f"{tok}%")

        where_sql = " AND ".join(where) if where else "1=1"

        base_sql = f"""
        SELECT
          callsign, licensee_name, street, city, state, zip,
          license_status, operator_class, operator_class_name,
          grant_date, expired_date, last_action_date
        FROM v_callbook
        WHERE {where_sql}
        ORDER BY (license_status='A') DESC, last_action_date DESC, expired_date DESC, callsign ASC
        """

        def run_search_query(sql: str, p: List[str], eff_limit_i: int, offset_i: int) -> Tuple[List[Dict], int]:
            """
            Execute the search query using our LIMIT semantics:
              - eff_limit=0 => unlimited (optionally offset)
              - eff_limit>0 => fetch limit+1 to detect 'more'
            Returns: (rows, more_flag)
            """
            rows_local: List[Dict] = []
            more_local = 0

            with db_conn() as conn:
                with conn.cursor() as cur:
                    if eff_limit_i == 0:
                        # Unlimited: return all matches (can be large)
                        sql_run = sql
                        if offset_i:
                            sql_run += f" LIMIT 18446744073709551615 OFFSET {int(offset_i)}"
                        cur.execute(sql_run, tuple(p))
                        rows_local = cur.fetchall()
                        more_local = 0
                    else:
                        fetch_n = int(eff_limit_i) + 1
                        sql_run = sql + f" LIMIT {fetch_n} OFFSET {int(offset_i)}"
                        cur.execute(sql_run, tuple(p))
                        rows_local = cur.fetchall()

                        if len(rows_local) > eff_limit_i:
                            more_local = 1
                            rows_local = rows_local[:eff_limit_i]

            return rows_local, more_local

        # Execute query
        try:
            rows, more = run_search_query(base_sql, params, eff_limit, offset)
        except Exception:
            xml = hamqth_error_xml("Backend error", callsign=cs, result=0)
            return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

        returned = len(rows)

        # Portable suffix fallback for *exact* callsign-only searches:
        # If user searched W1AW/P and exact match returned nothing, try W1AW.
        if callsign_only_exact and returned == 0 and "/" in cs:
            base = _portable_base(cs.strip().upper())
            if base and base != cs.strip().upper():
                try:
                    # Re-run with stripped callsign, preserving limit/offset semantics.
                    where2 = "callsign = %s"
                    params2 = [base]
                    base_sql2 = f"""
                    SELECT
                      callsign, licensee_name, street, city, state, zip,
                      license_status, operator_class, operator_class_name,
                      grant_date, expired_date, last_action_date
                    FROM v_callbook
                    WHERE {where2}
                    ORDER BY (license_status='A') DESC, last_action_date DESC, expired_date DESC, callsign ASC
                    """
                    rows, more = run_search_query(base_sql2, params2, eff_limit, offset)
                    returned = len(rows)
                except Exception:
                    # Ignore fallback errors and keep original empty result.
                    pass

        # Render XML response
        sid = str(uuid.uuid4())
        xml = hamqth_envelope_start(sid, error="OK")
        xml += f"""  <search>
    <result>{returned}</result>
    <limit>{eff_limit}</limit>
    <offset>{offset}</offset>
    <returned>{returned}</returned>
    <more>{more}</more>
  </search>
  <results>
"""

        for r in rows:
            def f(k: str) -> str:
                return xml_escape(_safe_str(r.get(k)))

            xml += f"""    <item>
      <callsign>{f("callsign")}</callsign>
      <adr_name>{f("licensee_name")}</adr_name>
      <adr_street1>{f("street")}</adr_street1>
      <adr_city>{f("city")}</adr_city>
      <adr_adrcode>{f("state")}</adr_adrcode>
      <adr_zip>{f("zip")}</adr_zip>

      <qth>{f("city")}</qth>
      <us_state>{f("state")}</us_state>

      <status>{f("license_status")}</status>
      <operator_class>{f("operator_class")}</operator_class>
      <operator_class_name>{f("operator_class_name")}</operator_class_name>

      <grant_date>{f("grant_date")}</grant_date>
      <expired_date>{f("expired_date")}</expired_date>
      <last_action_date>{f("last_action_date")}</last_action_date>
    </item>
"""

        xml += "  </results>\n"
        xml += hamqth_envelope_end()
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    # ============================
    # CALLSIGN LOOKUP MODE
    # ============================
    if not callsign:
        xml = hamqth_error_xml("Missing callsign", callsign="", result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    cs = callsign.strip().upper()

    if not CALLSIGN_RE.match(cs):
        xml = hamqth_error_xml("Invalid callsign format", callsign=cs, result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    def _lookup_once(q_callsign: str) -> List[Dict]:
        with db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT
                      callsign, licensee_name, street, city, state, zip,
                      license_status, operator_class, operator_class_name,
                      grant_date, expired_date, last_action_date
                    FROM v_callbook
                    WHERE callsign = %s
                    ORDER BY (license_status='A') DESC, expired_date DESC, grant_date DESC
                    LIMIT 5
                    """,
                    (q_callsign,),
                )
                return cur.fetchall()

    try:
        rows = _lookup_once(cs)

        # Portable suffix fallback: W1AW/P -> W1AW if not found
        if not rows and "/" in cs:
            base = _portable_base(cs)
            if base and base != cs:
                rows = _lookup_once(base)

    except Exception:
        xml = hamqth_error_xml("Backend error", callsign=cs, result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    if not rows:
        xml = hamqth_error_xml("Callsign not found", callsign=cs, result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    r = rows[0]

    def f(k: str) -> str:
        return xml_escape(_safe_str(r.get(k)))

    sid = str(uuid.uuid4())
    xml = hamqth_envelope_start(sid, error="OK")
    xml += f"""  <search>
    <callsign>{f("callsign")}</callsign>
    <result>1</result>

    <adr_name>{f("licensee_name")}</adr_name>
    <adr_street1>{f("street")}</adr_street1>
    <adr_city>{f("city")}</adr_city>
    <adr_adrcode>{f("state")}</adr_adrcode>
    <adr_zip>{f("zip")}</adr_zip>

    <qth>{f("city")}</qth>
    <us_state>{f("state")}</us_state>

    <status>{f("license_status")}</status>
    <operator_class>{f("operator_class")}</operator_class>
    <operator_class_name>{f("operator_class_name")}</operator_class_name>

    <grant_date>{f("grant_date")}</grant_date>
    <expired_date>{f("expired_date")}</expired_date>
    <last_action_date>{f("last_action_date")}</last_action_date>
  </search>
"""
    xml += hamqth_envelope_end()
    return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)
