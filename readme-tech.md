# ARCS — Technical Reference

This document provides a detailed technical overview of ARCS for operators,
developers, and learners who want to understand how the system works and why
it was designed this way.

Current version line: v1.0.x

---

## Philosophy (Why It Looks Like This)

ARCS is intentionally opinionated toward clarity over cleverness.

The system is designed to be:

- Readable by humans
- Safe to re-run without surprises
- Observable through explicit state files
- Educational for operators learning Docker, Linux, and data pipelines

Rather than distributing responsibilities across multiple ad-hoc scripts,
ARCS converges bootstrap, reconciliation, and update logic into a single
authoritative control path.

Re-runs are treated as normal operation, not exceptional cases.

---

## 1. System Architecture

ARCS is composed of containerized services orchestrated via Docker Compose.

Web Browser
    |
    | HTTP :8081
    v
arcs-web-ui (nginx)
    - Static UI
    - Reverse proxy /api/* → arcs-xml-api
    |
    | HTTP /api/*
    v
arcs-xml-api (FastAPI + Uvicorn)
    - HamQTH-compatible XML API
    |
    | TCP 3306
    v
arcs-uls-mariadb (MariaDB)
    - FCC ULS database

A one-shot importer container is used to load and update FCC data.

---

## 2. Containers

### arcs-uls-mariadb

- Image: mariadb:latest
- Persistent FCC ULS database
- Data stored in Docker volume: uls_db_data
- Healthcheck gates dependent services

Important constraint:
- MariaDB init scripts cannot consume Docker secrets

Design consequence:
- Database users and privileges are enforced post-start by arcsctl.sh

---

### arcs-uls-importer

- One-shot job container
- Downloads FCC l_amat.zip
- Converts legacy encodings to UTF-8
- Loads staging tables
- Merges into final schema
- Updates v_callbook view
- Safe to re-run
- Automatically skips work when source data is unchanged

Importer behavior is controlled by:

- HTTP ETag / Last-Modified headers
- ZIP SHA-256 checksum fallback
- DB-level named lock to prevent overlapping runs

Importer state is written to:

- logs/arcs-state.json (canonical)
- logs/.last_import (human-readable snapshot)

All legacy metadata paths have been removed.

---

### arcs-xml-api

- FastAPI application
- HamQTH-compatible XML API
- Endpoints:
  - /health
  - /xml.php
- Public port: 8080
- API version injected via environment variables

---

### arcs-web-ui

- nginx-based static UI
- Reverse proxy to API
- Public port: 8081
- Convenience interface only

---

## 3. Networking Model

Two Docker networks are used:

### uls_db_net (internal)

- MariaDB
- API
- Importer
- Not externally accessible

### uls_ext_net

- API
- Web UI
- Exposed via mapped ports

This prevents direct database exposure.

---

## 4. Secrets Management

Docker secrets are used for:

- MariaDB root password
- MariaDB application password
- XML API database password

Constraints:

- Secrets are mounted as root:root
- MariaDB init runs as mysql
- Init scripts cannot read secrets

Resolution:

- Secrets are generated and managed by arcsctl.sh
- Database users and privileges are enforced after startup
- Secrets rotate only on explicit request
  (using --coldstart --rotate-secrets)

---

## 5. Control Script (arcsctl.sh)

Authoritative control mechanism:

admin/arcsctl.sh

Responsibilities:

- Optional coldstart (volume wipe)
- Optional secrets rotation
- Start MariaDB and wait for health
- Run importer with skip-if-unchanged enabled
- Enforce least-privilege DB users
- Start API and UI services
- Run sanity checks
- Record canonical system state
- Manage optional cron-based automation

The script is idempotent and safe to run manually or unattended.

---

## 6. Automatic Reconciliation (Cron)

ARCS supports unattended operation via cron using the same control script.

Behavior:

- arcsctl.sh checks for cron availability
- Detects existing ARCS cron entries for the same user
- Creates a daily reconcile job if none exists

Default cron entry:

0 3 * * * cd /opt/arcs && /opt/arcs/admin/arcsctl.sh --ci --log-sanity >> /opt/arcs/logs/cron_arcsctl.log 2>&1

Design goals:

- Runs as the same user that owns the Docker workflow
- Uses the same idempotent control path as manual execution
- Skips imports automatically when data is unchanged
- Avoids secret rotation or destructive actions

Cron presence and status are recorded in metadata for visibility.

---

## 7. State and Metadata

Canonical system state is recorded in:

logs/arcs-state.json

Namespaces include:

- bootstrap
- uls_import
- scheduler

Importer metadata tracks:

- Source URL
- HTTP ETag and Last-Modified
- ZIP checksum and byte size
- Import start and finish timestamps
- Skip reasons when applicable
- Timestamp of last successful local data update

This file is authoritative for operational status and troubleshooting.

---

## 8. Security Posture (Baseline)

The v1.x baseline intentionally includes:

- Public API
- No authentication
- No TLS
- No rate limiting

This is a deliberate choice to keep the system simple, inspectable,
and educational.

Future enhancements (out of scope for baseline):

- External reverse proxy
- TLS termination
- Rate limiting
- Authentication layers

---

## 9. Design Principles Summary

- Prefer explicit control paths
- Make state visible and inspectable
- Avoid hidden automation
- Treat re-runs as normal operation
- Keep learning value high
- Use amateur radio as a real integration domain
