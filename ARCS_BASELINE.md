# ARCS — AI / ChatGPT Baseline Context
Amateur Radio Call Service (ARCS)

Repository (canonical):
https://github.com/N0LJD/ARCS

Baseline branch:
main

Baseline reference version:
v1.0.x (operational baseline, evolving)

======================================================================

1. PROJECT OVERVIEW

ARCS (Amateur Radio Call Service) is a self-hosted, containerized amateur
radio callbook service that provides FCC ULS amateur license data via a
HamQTH-compatible XML API.

The project is intentionally designed to:

- Be fully self-hosted and locally inspectable
- Use official FCC ULS amateur license data (l_amat.zip)
- Provide a public XML API compatible with HamQTH clients
- Support standard HamQTH XML Callbook Search queries
- Offer a simple web UI as a convenience (non-authoritative)
- Serve as a practical learning and reference project for:
  - Docker / Docker Compose
  - Linux service orchestration
  - Python APIs
  - SQL-backed data pipelines
  - Operational state tracking

ARCS is NOT affiliated with HamQTH, HamCall, or Buckmaster.
It implements a compatible XML response format strictly for interoperability.

======================================================================

2. XML CALLBOOK COMPATIBILITY (IMPORTANT)

ARCS implements the HamQTH XML Callbook Search API format as documented at:

https://www.hamqth.com/developers.php

Specifically:
- XML-based callsign lookup
- HamQTH-compatible response structure
- Intended to work with existing HamQTH-capable logging software

Typical query example:

http://<host>:8080/xml.php?callsign=W1AW

The ARCS XML API should be evaluated and reasoned about using the HamQTH
developer documentation as the authoritative protocol reference.

======================================================================

3. ARCHITECTURE SUMMARY

ARCS consists of containerized services orchestrated via Docker Compose.

Web Browser
    |
    | HTTP :8081
    v
arcs-web-ui (nginx)
    - Static web UI
    - Reverse proxy /api/* → arcs-xml-api
    |
    | HTTP /api/*
    v
arcs-xml-api (FastAPI + Uvicorn)
    - HamQTH-compatible XML API
    |
    | TCP 3306
    v
arcs-uls-mariadb (MariaDB, latest)
    - FCC ULS database

One-shot job container:
arcs-uls-importer
    - Downloads and imports FCC ULS data

======================================================================

4. CONTAINERS AND RESPONSIBILITIES

4.1 arcs-uls-mariadb
- Image: mariadb:latest
- Persistent database storing FCC ULS amateur license data
- Database: uls
- Uses Docker secrets for credentials
- Data persisted via Docker volume (uls_db_data)
- Healthcheck gates dependent services

Important design constraint:
- MariaDB init scripts cannot consume Docker secrets
- Additional DB users must be created post-startup

---------------------------------------------------------------------

4.2 arcs-uls-importer
- One-shot job container
- Downloads FCC ULS l_amat.zip
- Converts legacy encodings to UTF-8
- Loads staging tables
- Merges data into final schema
- Creates and maintains v_callbook view
- Safe to re-run
- Skips work automatically if source data is unchanged

Importer metadata is recorded in:
- logs/arcs-state.json (canonical)
- logs/.last_import (human-readable snapshot)

---------------------------------------------------------------------

4.3 arcs-xml-api
- FastAPI application
- Public HamQTH-compatible XML API
- Endpoints:
  - /health
  - /xml.php
- Uses least-privilege DB credentials
- Publicly exposed on port 8080

Versioning:
- API version injected via environment
- /health returns structured JSON including version

---------------------------------------------------------------------

4.4 arcs-web-ui
- nginx-based static web interface
- Simple callbook lookup form
- Reverse proxy /api/* → arcs-xml-api
- Exposed on port 8081
- Convenience interface only

======================================================================

5. NETWORKING MODEL

Two Docker networks are used:

uls_db_net (internal)
- MariaDB
- API
- Importer
- Not externally accessible

uls_ext_net
- API
- Web UI
- Exposed via mapped ports

This ensures:
- The database is never directly exposed
- Only API and UI are reachable externally

======================================================================

6. SECRETS MANAGEMENT

Docker secrets are used for:
- MariaDB root password
- MariaDB application password
- XML API database password

Important constraints:
- Secrets are mounted root:root
- MariaDB init scripts run as mysql
- Init scripts cannot consume Docker secrets

Resulting design:
- Secrets are generated and managed by the control script
- Database users and privileges are enforced post-start

Secrets are rotated ONLY when explicitly requested.

======================================================================

7. VERIFIED BASELINE WORKFLOW (FROM SCRATCH)

Authoritative control mechanism:
admin/arcsctl.sh

Cold start definition:
- Containers stopped
- Volumes removed
- Secrets regenerated
- Database rebuilt from scratch

Verified workflow:

1. Optional teardown:
   docker compose down --remove-orphans
   docker volume rm arcs_uls_db_data arcs_uls_cache

2. Bootstrap / reconcile:
   ./admin/arcsctl.sh

3. Status inspection:
   ./admin/arcsctl.sh --status

Canonical operational state is recorded in:
logs/arcs-state.json

======================================================================

8. SECURITY POSTURE (BASELINE)

Current baseline:
- Public XML API
- No authentication
- No TLS termination
- No rate limiting
- Database protected by Docker networking

Planned future enhancements (out of scope for v1.0.x baseline):
- External reverse proxy
- TLS
- Rate limiting
- IP filtering
- Additional read-only DB users

======================================================================

9. DESIGN PHILOSOPHY

- Favor clarity over cleverness
- Prefer explicit control paths over hidden automation
- Treat re-runs as normal operation
- Make state visible and inspectable
- Keep the system approachable for Docker learners
- Use amateur radio as a real-world integration context

======================================================================

10. USING THIS DOCUMENT WITH AI SYSTEMS (ChatGPT)

When starting a new AI-assisted discussion about ARCS:

Provide this file and state:

"Use ARCS_BASELINE.md as the authoritative baseline context.
Assume the repository state matches the main branch of
https://github.com/N0LJD/ARCS unless otherwise specified."

This avoids re-explaining architecture, tradeoffs, and constraints.

======================================================================

11. REPOSITORY REFERENCE

Canonical source of truth:
https://github.com/N0LJD/ARCS

Primary documentation:
- README.md
- QUICKSTART.md
- readme-tech.md

Branch: main
Version line: v1.0.x
