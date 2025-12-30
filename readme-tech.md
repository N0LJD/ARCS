# ARCS – Technical Reference
# Edward Moss - N0LJD

Version: v1.0.0-baseline  
Date: 2025-12-29  

This document provides a technical deep dive into the ARCS (Amateur Radio Call
Search) project. It is intended as a reference for maintainers, home-lab
operators, and developers with working knowledge of Linux, Docker, and basic
application architecture.

This document complements:
- README.md (high-level overview)
- QUICKSTART.md (verified bootstrap process)
- ARCS_BASELINE.md (canonical baseline reference)

---

## 1. Architectural Overview

ARCS is a self-hosted, containerized amateur radio callbook service built around
a HamQTH-compatible XML API. It ingests FCC ULS amateur license data and exposes
it through a standardized interface used by existing amateur radio software.

Design principles:
- Self-hosted and reproducible
- Explicit over implicit behavior
- Clear separation of responsibilities
- Minimal operational magic
- Educational value without sacrificing correctness

The system is intentionally modular and avoids tight coupling between services.

---

## 2. Container Responsibilities

### 2.1 arcs-uls-mariadb

- Image: mariadb:11
- Stores FCC ULS amateur license data
- Uses Docker volumes for persistent storage
- Runs exclusively on an internal Docker network
- Never exposed externally

Important design constraint:
MariaDB init scripts cannot consume Docker secrets due to permission and
execution model limitations. As a result, additional database users are created
after startup using explicit admin scripts. This behavior is intentional and
documented.

---

### 2.2 arcs-uls-importer

- One-shot job container
- Downloads the FCC ULS l_amat.zip dataset
- Converts legacy encodings to UTF-8
- Loads staging tables
- Merges data into the final schema
- Creates the v_callbook view consumed by the XML API
- Safe to re-run
- Exits cleanly upon completion

The importer is decoupled from the API and database lifecycle and can be run
independently when data refresh is required.

---

### 2.3 arcs-xml-api

- FastAPI application running under Uvicorn
- Implements a HamQTH-compatible XML API
- Primary endpoints:
  - /xml.php
  - /health
- Connects to MariaDB using the application database account
- Publicly exposed on TCP port 8080

API version information is injected via environment variables and returned
by the /health endpoint.

Authentication, authorization, and rate limiting are intentionally out of scope
for the v1.0.0 baseline.

---

### 2.4 arcs-web-ui

- nginx-based static Web UI
- Provides a simple callsign lookup form
- Reverse proxies /api/* requests to arcs-xml-api
- Publicly exposed on TCP port 8081

The Web UI is optional and provided strictly as a convenience interface.

---

## 3. Networking Model

Two Docker networks are used:

- uls_db_net (internal)
  - arcs-uls-mariadb
  - arcs-xml-api
  - arcs-uls-importer

- uls_ext_net
  - arcs-xml-api
  - arcs-web-ui

This ensures the database remains isolated while allowing controlled public
access to the XML API and Web UI.

---

## 4. Secrets Management

Docker secrets are used for:
- MariaDB root password
- MariaDB application user password
- XML API database password

Constraints:
- Secrets are mounted as root:root
- MariaDB init scripts run as mysql
- Secrets cannot be consumed during init

Resulting design:
- Database bootstrap uses standard MariaDB mechanisms
- Additional users are created post-startup using admin scripts

This approach favors reliability, clarity, and maintainability over brittle
automation.

---

## 5. Bootstrap and Admin Scripts

### 5.1 admin/first-run.sh

This script is the **authoritative bootstrap mechanism** for ARCS.

It is responsible for:
- Generating Docker secrets
- Managing cold vs warm startup behavior
- Starting containers in the correct order
- Running the FCC ULS importer
- Applying database users
- Recording bootstrap metadata

#### Supported Arguments

- (no arguments)  
  Performs a normal startup. Existing secrets, volumes, and data are preserved
  if present. This is the default and safest mode.

- -coldstart  
  Forces a full rebuild of the system. This includes:
  - Stopping containers
  - Removing database volumes
  - Rebuilding the database from scratch
  - Re-running the importer

  Use this when a completely clean rebuild is required.

- -rotate-passwords  
  Forces regeneration of all database and API passwords during a rebuild.
  Typically used in conjunction with -coldstart.

  Example behavior:
  - Existing secrets are discarded
  - New secrets are generated
  - Database credentials are fully rotated

These flags are intentionally explicit to avoid accidental data loss.

---

### 5.2 Bootstrap Metadata

Upon successful completion, the bootstrap process writes basic metadata to:

admin/.bootstrap_complete

This file is used to record:
- Timestamp of last successful bootstrap
- Baseline version information
- High-level completion state

It is not used for logic gating, but serves as a lightweight indicator that
initialization has completed successfully.

---

### 5.3 admin/sanity-check.sh

This script performs post-startup validation and health checks.

Primary functions:
- Validate required Docker containers are running
- Confirm presence of required secrets
- Verify database connectivity
- Validate XML API availability
- Confirm Web UI reverse proxy operation

#### Supported Arguments

- (no arguments)  
  Runs the standard health check suite.

- -verbose  
  Provides additional diagnostic output intended for troubleshooting.

The script is read-only in nature and does not modify system state.

---

## 6. Verified Startup Workflow

Canonical startup sequence:

1. Run admin/first-run.sh
2. Wait for importer completion
3. Run admin/sanity-check.sh
4. Confirm API and Web UI availability

This workflow has been repeatedly validated from empty volumes and represents
the canonical process for the v1.0.0 baseline.

---

## 7. Directory Structure Reference

The following tree represents the complete v1.0.0 project layout:

arcs
├── ARCS_BASELINE.md
├── Makefile
├── QUICKSTART.md
├── README.md
├── admin
│   ├── apply-db-users.sh
│   ├── db-users.txt
│   ├── first-run.sh
│   ├── sanity-check.sh
│   └── .bootstrap_complete
├── db-init
├── docker-compose.yml
├── importer
│   ├── Dockerfile
│   ├── import_uls.py
│   ├── requirements.txt
│   └── schema.sql
├── logs
│   └── importer_YYYYMMDD_HHMMSS.log
├── run-weekly-import.sh
├── secrets
│   ├── mariadb_root_password.txt
│   ├── mariadb_user_password.txt
│   └── xml_api_password.txt
├── web-ui
│   ├── Dockerfile
│   ├── app.js
│   ├── config.template.js
│   ├── default.conf
│   ├── docker-entrypoint.sh
│   └── index.html
└── xml-api
    ├── Dockerfile
    ├── app.py
    └── requirements.txt

---

## 8. Baseline Security Posture

v1.0.0 characteristics:
- Public XML API
- No authentication
- No TLS
- No rate limiting

These limitations are intentional and documented.

---

## 9. Future Enhancements Under Consideration

The following features are planned but not part of the baseline:

- TLS termination
- External reverse proxy
- Read-only database users
- XML API rate limiting
- Authentication headers
- Scheduled delta imports for FCC ULS data

All future work will preserve compatibility with the HamQTH XML API.

---

