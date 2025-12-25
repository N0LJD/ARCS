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

# Database connection settings are controlled via environment variables.
# Defaults align with docker-compose service naming (DB_HOST=uls-mariadb).
DB_HOST = os.environ.get("DB_HOST", "uls-mariadb")
DB_NAME = os.environ.get("DB_NAME", "uls")
DB_USER = os.environ.get("DB_USER", "callbook_ro")
DB_PASS = os.environ.get("DB_PASS", "")

# Basic callsign sanity check. Allows letters/numbers and portable suffix like /P, /MM, etc.
CALLSIGN_RE = re.compile(r"^[A-Z0-9/]{1,16}$")

# Canonical media type for XML responses (keeps clients and docs consistent).
# NOTE: Some frameworks drop charset from media_type; we force it via XML_HEADERS.
XML_MEDIA_TYPE = "application/xml"
XML_HEADERS = {"Content-Type": "application/xml; charset=utf-8"}


def db_conn():
    """
    Create a MariaDB/MySQL connection for a single request.

    Notes:
    - autocommit=True because this API is read-only; we don't need explicit transaction mgmt.
    - DictCursor gives us rows as dicts, simplifying field mapping into XML tags.
    """
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
    """
    Minimal XML escaping for content inserted into XML tags.

    This is not a full XML serializer, but is sufficient for simple tag content.
    Caller is expected to pass a string (see helper f() below).
    """
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def hamqth_error_xml(callsign: str, message: str, result: int = 0) -> str:
    """
    Build a HamQTH-style XML response for errors and "not found" cases.

    We always generate a session_id and include the error message in both
    <session><error> and <search><error> to match common HamQTH client expectations.
    """
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
    """
    Health check endpoint.

    Returns JSON so it is easy for monitors, load balancers, and orchestration tools to parse.
    """
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
                "content": {
                    "application/xml": {
                        "schema": {"type": "string"}
                    }
                }
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
    # Normalize callsign for lookup and consistent validation.
    cs = callsign.strip().upper()

    # Validate callsign (basic)
    if not CALLSIGN_RE.match(cs):
        xml = hamqth_error_xml(cs, "Invalid callsign format", result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    # Query DB
    #
    # We query the view v_callbook (not base tables). This reduces DB privileges
    # required by the API user and stabilizes the API contract.
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
        # Avoid leaking DB details; return a HamQTH-style "Backend error".
        xml = hamqth_error_xml(cs, "Backend error", result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    if not rows:
        xml = hamqth_error_xml(cs, "Callsign not found", result=0)
        return Response(content=xml, media_type=XML_MEDIA_TYPE, headers=XML_HEADERS)

    # Return the "best" match:
    # - The SQL ORDER BY prefers Active licenses, then most recent expirations/grants.
    r = rows[0]

    def f(k: str) -> str:
        """
        Convenience accessor for DB fields -> XML-safe text.
        - Converts NULL to empty tag content.
        - Stringifies non-NULL values and escapes XML special chars.
        """
        v = r.get(k)
        return "" if v is None else xml_escape(str(v))

    sid = str(uuid.uuid4())

    # Map fields from v_callbook into a HamQTH-ish set of tags.
    # This is intentionally minimal and can be expanded later if clients need more fields.
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
