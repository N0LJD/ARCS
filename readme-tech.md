# ARCS — Technical Reference

This document provides a detailed technical overview of ARCS for operators,
developers, and learners who want to understand how the system works and why
it was designed this way.

Documentation version: v1.0.1

---

## 0. Design Philosophy

ARCS is built around a simple operational rule:

The same command should be safe to run repeatedly and should converge the
system toward the desired state.

The system favors:
- Idempotence
- Explicit state recording
- Conservative defaults
- Clear failure modes

Destructive operations are never implicit.

---

## 1. System Architecture

ARCS consists of containerized services orchestrated via Docker Compose.

Web Browser
    |
    | HTTP :8081
    v
arcs-web-ui (nginx)
    - Static UI
    - Reverse proxy to XML API
    |
    | HTTP
    v
arcs-xml-api (FastAPI)
    - HamQTH-compatible XML API
    |
    | TCP 3306
    v
arcs-uls-mariadb (MariaDB, latest)
    - FCC ULS database

A one-shot importer container handles FCC data ingestion and updates.

---

## 2. Containers

### arcs-uls-mariadb

- Image: mariadb:latest
- Persistent database stored in Docker volume
- Healthcheck gates dependent services

Constraints:
- MariaDB init scripts cannot consume Docker secrets
- Additional users are created post-start

---

### arcs-uls-importer

- One-shot job container
- Downloads FCC l_amat.zip
- Converts legacy encodings to UTF-8
- Loads staging tables
- Merges into final schema
- Creates v_callbook view

Safety features:
- Database-level named lock prevents concurrent imports
- Source metadata comparison prevents unnecessary imports
- Import is skipped when data is unchanged

---

### arcs-xml-api

- FastAPI-based service
- Read-only API
- HamQTH-compatible XML output
- Public port: 8080

---

### arcs-web-ui

- nginx-based static UI
- Reverse proxy to API
- Optional convenience interface

---

## 3. Networking Model

Two Docker networks are used:

uls_db_net:
- MariaDB
- API
- Importer
- Internal only

uls_ext_net:
- API
- Web UI
- Exposed to host

The database is never directly exposed.

---

## 4. Secrets Management

Secrets are stored locally and mounted via Docker secrets.

Design constraints:
- Secrets are root-owned
- MariaDB init cannot read secrets
- User creation occurs post-start

Secret rotation is explicit and never automatic.

---

## 5. Bootstrap and State Reconciliation

Authoritative entry point:

admin/first-run.sh

Responsibilities:
- Detect new vs existing systems
- Optionally rotate secrets
- Start database
- Run importer safely
- Enforce DB permissions
- Start runtime services
- Record system state

first-run.sh is not a one-time installer.
It is a reconciliation tool.

---

## 6. System State Model

Canonical system state is recorded in:

logs/arcs-state.json

Namespaces include:
- bootstrap
- uls_import

Recorded data includes:
- Execution timestamps
- Import results
- Skip reasons
- Source metadata (ETag, ZIP hash, ZIP size)
- Local data update timestamps

Legacy text metadata is written to admin/.bootstrap_complete for compatibility.

---

## 7. Importer State Machine (Conceptual)

Importer execution follows this flow:

START
 → Acquire DB lock
 → Load previous importer state
 → Fetch HTTP metadata
 → Compare source metadata
 → If unchanged:
      → Record skip
      → Release lock
      → EXIT
 → Else:
      → Download ZIP
      → Verify hash and size
      → Import data
      → Update views
      → Record metadata
 → Release lock
 → EXIT

This ensures correctness, safety, and auditability.

---

## 8. Security Posture (Baseline)

Baseline intentionally includes:
- No authentication
- No TLS
- No rate limiting

This keeps the system transparent and inspectable.

Hardening is expected to be handled externally.

---

## 9. Summary

- Safe-by-default operations
- Explicit destructive flags
- Canonical state tracking
- Clear separation of concerns
- Designed for long-term unattended operation

ARCS uses amateur radio data as a real-world integration problem while remaining
approachable for operators and learners.
