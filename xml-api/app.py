"""
HamCall / HamQTH-style XML API (FastAPI)
Edward Moss - N0LJD


Purpose
-------
This service exposes a small HamQTH-compatible subset for callsign lookups, backed by a
local MariaDB instance populated from FCC ULS data.

Endpoints
---------
1) GET /health
   - Lightweight JSON health check for orchestration/monitoring.

2) GET /xml.php?callsign=<CALLSIGN>[&raw=0|1]
   - Returns HamQTH-style XML for a callsign lookup.

Design notes
------------
- Database access is READ-ONLY for this API. The recommended DB user is `callbook_ro`,
  with SELECT privilege ONLY on `uls.v_callbook`.
- The API queries the view `v_callbook` (not the base tables) to keep the API contract
  stable and to limit privileges.
- XML responses are returned using explicit XML Content-Type headers:
    Content-Type: application/xml; charset=utf-8
  This is important because some HamQTH/legacy clients are strict about response types.
- OpenAPI (/openapi.json and /docs) is explicitly overridden to advertise XML for /xml.php.
  FastAPI can otherwise default to application/json for Response-returning routes.

High-level flow for /xml.php
----------------------------
1) Normalize the callsign:
   - trim whitespace
   - convert to uppercase

2) Validate callsign format:
   - allow A-Z 0-9 and "/" for portable suffixes (e.g., W1AW/P)

3) Query v_callbook:
   - fetch up to 5 candidate rows
   - sort to prefer Active ("A") records, then newest expirations/grants

4) Choose "best" match:
   - select first row after sorting

5) Render HamQTH-style XML:
   - include a generated UUID session_id
   - map DB fields into HamQTH-ish tags

6) Return XML Response:
   - always with application/xml; charset=utf-8

Operational notes
-----------------
- The `db_conn()` function opens a new connection per request. This is fine at small scale.
  If concurrency grows, consider connection pooling or a lightweight per-process pool.
- Exceptions from the DB layer return a HamQTH-style XML error: "Backend error".
  (This avoids leaking internal details to callers.)
"""

import os
import re
import uuid

from fastapi import FastAPI, Query, Response
import pymysql

APP_TITLE = "HamQTH-style Callsign XML"
app = FastAPI(title=APP_TITLE)

DB_HOST = os.environ.get("DB_HOST", "uls-mariadb")
DB_NAME = os.environ.get("DB_NAME", "uls")
DB_USER = os.environ.get("DB_USER", "callbook_ro")

# Password may be provided directly (DB_PASS) or via a mounted secret file (DB_PASS_FILE).
# DB_PASS_FILE takes precedence if set.
DB_PASS = os.environ.get("DB_PASS", "")
DB_PASS_FILE = os.environ.get("DB_PASS_FILE")


def _read_secret(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


if DB_PASS_FILE:
    DB_PASS = _read_secret(DB_PASS_FILE)

# Basic callsign sanity check. Allows letters/numbers and portable suffix like /P, /MM, etc.
CALLSIGN_RE = re.compile(r"^[A-Z0-9/]{1,16}$")

# Canonical media type for XML responses (keeps clients and docs consistent)
XML_MEDIA_TYPE = "application/xml; charset=utf-8"
XML_HEADERS = {"Content-Type": "application/xml; charset=utf-8"}


def db_conn():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        autocommit=True,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )


def xml_escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def hamqth_error_xml(callsign: str, message: str, result: int = 0) -> str:
    sid = str(uuid.uuid4())
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<HamQTH version="2.0">
  <session>
    <session_id>{xml_escape(sid)}</session_id>
    <error>{xml_escape(message)}</error>
  </session>
  <search>
    <callsign>{xml_escape(callsign)}</callsign>
    <result>{result}</result>
    <error>{xml_escape(message)}</error>
  </search>
</HamQTH>
"""


@app.get(
    "/health",
    responses={
        200: {
            "description": "Successful Response",
            "content": {
                "application/json": {
                    "schema": {"type": "object"},
                    "example": {"ok": True, "service": APP_TITLE},
                }
            },
        }
    },
)
def health():
    return {"ok": True, "service": APP_TITLE}


@app.get(
    "/xml.php",
    response_class=Response,
    # Tell OpenAPI (and /docs) that we return XML, not JSON.
    responses={
        200: {
            "description": "Successful Response",
            "content": {
                "application/xml": {
                    "schema": {"type": "string"},
                    "example": """<?xml version="1.0" encoding="UTF-8"?>
<HamQTH version="2.0">
  <session>
    <session_id>...</session_id>
    <error>OK</error>
  </session>
  <search>
    <callsign>W1AW</callsign>
    <result>1</result>
  </search>
</HamQTH>
""",
                }
            },
        },
        422: {
            "description": "Validation Error",
            "content": {
                "application/json": {
                    "schema": {"$ref": "#/components/schemas/HTTPValidationError"}
                }
            },
        },
    },
    # FastAPI can still default 200->application/json in OpenAPI for Response-returning routes.
    # openapi_extra forces the correct content-type in the final spec.
    openapi_extra={
        "responses": {
            "200": {
                "content": {"application/xml": {"schema": {"type": "string"}}}
            }
        }
    },
)
def lookup(
    callsign: str = Query(..., min_length=1, max_length=16),
    raw: int = Query(0, ge=0, le=1),
):
    """
    HamQTH-like endpoint (simple):
      /xml.php?callsign=K0ABC

    Returns XML.
    """
    cs = callsign.strip().upper()

    # Validate callsign (basic)
    if not CALLSIGN_RE.match(cs):
        xml = hamqth_error_xml(cs, "Invalid callsign format", result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    # Query DB
    try:
        with db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT callsign, licensee_name, street, city, state, zip,
                           license_status, grant_date, expired_date, last_action_date
                    FROM v_callbook
                    WHERE callsign = %s
                    ORDER BY (license_status='A') DESC, expired_date DESC, grant_date DESC
                    LIMIT 5
                    """,
                    (cs,),
                )
                rows = cur.fetchall()
    except Exception:
        xml = hamqth_error_xml(cs, "Backend error", result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    if not rows:
        xml = hamqth_error_xml(cs, "Callsign not found", result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    # Return the "best" match
    r = rows[0]

    def f(k: str) -> str:
        v = r.get(k)
        return "" if v is None else xml_escape(str(v))

    sid = str(uuid.uuid4())

    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<HamQTH version="2.0">
  <session>
    <session_id>{xml_escape(sid)}</session_id>
    <error>OK</error>
  </session>
  <search>
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
    <grant_date>{f("grant_date")}</grant_date>
    <expired_date>{f("expired_date")}</expired_date>
    <last_action_date>{f("last_action_date")}</last_action_date>
  </search>
</HamQTH>
"""
    return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)
