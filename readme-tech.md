# ARCS — Technical Reference

This document provides a detailed technical overview of ARCS for operators,
developers, and learners who want to understand how the system works and why
it was designed this way.

Current version line: v1.0.x

---

## Philosophy (Why It Looks Like This)

ARCS is intentionally opinionated toward **clarity over cleverness**.

The system is designed to be:
- Readable by humans
- Safe to re-run without surprises
- Observable through explicit state files
- Educational for operators learning Docker, Linux, and data pipelines

Rather than splitting responsibilities across many scripts, ARCS converges
bootstrap, reconciliation, and update logic into a single control path.
This reduces ambiguity and makes operational behavior predictable.

Amateur radio data is used as a real-world integration problem, not merely
as an application payload.

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
arcs-uls-mariadb (MariaDB, latest)
    - FCC ULS database

A one-shot importer container is used to load and update FCC data.

---

## 2. Containers

### arcs-uls-mariadb

- Image: mariadb:latest
- Persistent FCC ULS database
- Data stored in Docker volume uls_db_data
- Healthcheck gates dependent services

Important constraints:
- MariaDB init scripts cannot consume Docker secrets
- Additional users must be created after startup

Design consequence:
- Bootstrap script performs post-start privilege enforcement

---

### arcs-uls-importer

- One-shot job container
- Downloads FCC l_amat.zip
- Converts legacy encodings to UTF-8
- Loads staging tables
- Merges into final schema
- Creates and updates v_callbook view
- Safe to re-run
- Skips work automatically when source data is unchanged

Importer state is written to:
- logs/arcs-state.json (canonical)
- logs/.last_import (human-readable snapshot)

---

### arcs-xml-api

- FastAPI application
- Public HamQTH-compatible XML API
- Endpoints:
  - /health
  - /xml.php
- Public port: 8080
- API version injected via environment

---

### arcs-web-ui

- nginx-based static UI
- Reverse proxy to API
- Public port: 8081
- Convenience only; not required for API usage

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

This ensures the database is never directly exposed.

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

Design resolution:
- Secrets are generated and managed by arcsctl.sh
- Database users are created and enforced post-start

Secrets are rotated only when explicitly requested.

---

## 5. Control Script (arcsctl.sh)

Authoritative control mechanism:

admin/arcsctl.sh

Responsibilities:
- Optional coldstart (volume wipe)
- Optional secrets rotation
- Start MariaDB and wait for health
- Run importer (with skip-if-unchanged default)
- Enforce least-privilege DB users
- Start API and UI services
- Run sanity checks
- Record canonical state

Behavior is idempotent and safe to re-run.

---

## 6. State and Metadata

Canonical system state is recorded in:

logs/arcs-state.json

Namespaces include:
- bootstrap
- uls_import

Importer metadata includes:
- Source URL
- HTTP ETag and Last-Modified
- ZIP checksum and byte size
- Import start and finish times
- Skip reasons when applicable
- Timestamp of last local data update

This file is authoritative for operational status.

---

## 7. Security Posture (Baseline)

The v1.x baseline intentionally includes:
- Public API
- No authentication
- No TLS
- No rate limiting

This is a deliberate choice to keep the system simple and inspectable.

Planned future enhancements may include:
- External reverse proxy
- TLS termination
- Rate limiting
- IP filtering
- Authentication layers

These are explicitly out of scope for the baseline release.

---

## 8. Design Principles Summary

- Prefer explicit control paths
- Make state visible and inspectable
- Avoid hidden automation
- Treat re-runs as normal operation
- Keep learning value high
- Use amateur radio as a real integration domain

