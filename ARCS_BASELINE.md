# ARCS — ChatGPT Baseline Context
Amateur Radio Call Service (ARCS)
Repository: https://github.com/N0LJD/ARCS
Baseline: main branch (published, stable)
Baseline Version: v1.0.0 (frozen)

======================================================================

1. PROJECT OVERVIEW

ARCS (Amateur Radio Call Service) is a self-hosted, containerized amateur
radio callbook service that provides FCC ULS license lookup data using a
HamQTH-compatible XML API.

The project is designed to:
- Be fully self-contained and self-hosted
- Use official FCC ULS amateur license data
- Provide a public XML API compatible with HamQTH clients
- Offer a simple web UI as a convenience tool
- Serve as a learning and reference project for Docker, Linux, Python,
  APIs, and database-backed services

ARCS is NOT affiliated with HamQTH, HamCall, or Buckmaster. It implements
a compatible API format for interoperability only.

======================================================================

2. ARCHITECTURE SUMMARY

ARCS consists of four Docker services orchestrated via docker-compose:

Web Browser
    |
    | HTTP :8081
    v
arcs-web-ui (nginx)
    - Static web UI
    - Reverse proxy /api/* ? arcs-xml-api
    |
    | HTTP /api/*
    v
arcs-xml-api (FastAPI + Uvicorn)
    - HamQTH-compatible XML API
    |
    | TCP 3306
    v
arcs-uls-mariadb (MariaDB 11)
    - FCC ULS database

One-shot job container:
arcs-uls-importer
    - Downloads and loads FCC ULS data

======================================================================

3. CONTAINERS AND RESPONSIBILITIES

3.1 arcs-uls-mariadb
- Image: mariadb:11
- Persistent database storing FCC ULS amateur license data
- Initialized using:
  - MARIADB_DATABASE=uls
  - MARIADB_USER=uls
  - MARIADB_PASSWORD_FILE
- Uses Docker secrets for credentials
- Data persisted via Docker volume (uls_db_data)
- Healthcheck ensures readiness before dependent services start

Important design decision:
- MariaDB init scripts do NOT read Docker secrets
- Additional DB users are created post-startup via admin scripts

---------------------------------------------------------------------

3.2 arcs-uls-importer
- One-shot job container
- Downloads FCC ULS l_amat.zip
- Converts legacy encodings to UTF-8
- Loads staging tables
- Merges data into final schema
- Creates v_callbook view used by the API
- Safe to re-run
- Exits cleanly when complete

---------------------------------------------------------------------

3.3 arcs-xml-api
- FastAPI application
- Public HamQTH-compatible XML API
- Endpoints:
  - /health
  - /xml.php
- Uses the bootstrap database account (uls) in the baseline
- Publicly exposed on port 8080
- Designed to support future read-only DB users

Versioning:
- API version is injected via ARCS_API_VERSION
- /health returns structured JSON including version

---------------------------------------------------------------------

3.4 arcs-web-ui
- nginx-based static web interface
- Provides:
  - Simple callbook lookup form
  - Reverse proxy /api/* ? arcs-xml-api
- Exposed on port 8081
- Convenience interface only; not required for API clients

Versioning:
- UI version is injected via ARCS_UI_VERSION
- /health.json returns structured JSON including version

======================================================================

4. NETWORKING MODEL

Two Docker networks are used:

uls_db_net (internal)
- Used by MariaDB, API, and importer
- Not externally accessible

uls_ext_net
- Used by API and web UI
- API exposed publicly via mapped ports

This ensures:
- Database is never exposed externally
- Only API and UI are reachable from outside Docker

======================================================================

5. SECRETS MANAGEMENT

Docker secrets are used for:
- MariaDB root password
- MariaDB application user password
- XML API database password

Important constraints:
- Docker secrets are mounted root:root
- MariaDB init scripts run as mysql
- Init scripts cannot consume Docker secrets

Resulting design:
- Database bootstrap uses the standard MariaDB application user
- Additional users (e.g. read-only, API-specific) are created after startup
  using explicit admin scripts

This is intentional and documented.

======================================================================

6. VERIFIED BASELINE STARTUP WORKFLOW (FROM SCRATCH)

Authoritative bootstrap mechanism:
- admin/first-run.sh

Cold start definition:
- Containers stopped
- Volumes removed
- Secrets regenerated
- Database rebuilt from scratch

Verified workflow:

1. Optional teardown (cold start):
   docker compose down --remove-orphans
   docker volume rm arcs_uls_db_data arcs_uls_cache

2. Run bootstrap:
   ./admin/first-run.sh

3. Verify functionality:
   http://localhost:8080/health
   http://localhost:8080/xml.php?callsign=W1AW
   http://localhost:8081/health.json
   http://localhost:8081/api/xml.php?callsign=W1AW

This workflow has been verified repeatedly from empty volumes.

======================================================================

7. SECURITY POSTURE (BASELINE)

Current baseline:
- Public API
- Database accessed using application account
- No authentication
- No rate limiting
- No TLS termination

Planned future enhancements:
- Read-only database user
- External reverse proxy
- TLS
- Rate limiting
- IP filtering

These are explicitly out of scope for the v1.0.0 baseline.

======================================================================

8. QA AND VALIDATION STATUS

A modular QA automation script was developed during v1.0 work to validate:
- Container readiness
- Health endpoints
- XML correctness
- Database sanity

Outcome:
- Functional checks validated system correctness
- Tooling complexity and file-permission edge cases produced false negatives
- QA automation is NOT considered authoritative for the v1.0.0 baseline

Baseline policy:
- Manual smoke checks define system health
- Automation may be reintroduced post-hardening

======================================================================

9. DEVELOPMENT PHILOSOPHY

- Favor clarity over cleverness
- Prefer explicit operational steps over brittle automation
- Document tradeoffs clearly
- Keep the system understandable for users new to Docker
- Use amateur radio as the real-world integration context

======================================================================

10. USING THIS DOCUMENT WITH CHATGPT

To start a new ChatGPT conversation about ARCS:

Provide this file and say:

"Use this document as the baseline context for the ARCS project.
Assume the repository is in the published v1.0.0 baseline state unless
otherwise noted."

This avoids re-explaining architecture, design decisions, and constraints.

======================================================================

11. REPOSITORY REFERENCE

Canonical source of truth:
https://github.com/N0LJD/ARCS

Branch: main
Tag: v1.0.0-baseline

