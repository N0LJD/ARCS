# ARCS — Amateur Radio Call Service

ARCS (Amateur Radio Call Service) is a self-hosted, containerized amateur radio
callbook service that provides FCC ULS license data via a HamQTH-compatible XML
API format for interoperability.

This project is intended for operators who want a local, inspectable, and
self-managed callbook service built directly from official FCC data.

ARCS is NOT affiliated with HamQTH, HamCall, or Buckmaster.
It implements a compatible API format strictly for interoperability.

---

## Why This Project Exists

ARCS exists as both a practical service and a learning reference.

It brings together:
- Docker and Docker Compose
- Linux service orchestration
- Python-based import and API services
- Database-backed applications
- Real-world amateur radio licensing data

The emphasis is on clarity, reproducibility, operational safety, and local control.

ARCS is designed so that running the same operational command repeatedly
reconciles system state rather than rebuilding it.

---

## Requirements

- Linux-based operating system
- Docker
- Docker Compose (v2)

---

## Quick Setup

### 1. Download the project

git clone https://github.com/N0LJD/ARCS arcs

Assumption: the project will live in /opt/arcs

mv arcs /opt/arcs
cd /opt/arcs

---

### 2. Run the bootstrap script

./admin/first-run.sh

#### First execution (new system)

When run on a fresh checkout, first-run.sh will:

- Generate required local secrets
- Start the MariaDB database
- Download and import FCC ULS data
- Create database schema and callbook views
- Configure least-privilege database users
- Start the XML API and Web UI services
- Record system state and metadata

No manual setup steps are required.

#### Subsequent executions (existing system)

Running the same command again is safe and expected.

On an existing system, first-run.sh will:

- Preserve existing secrets and database volumes
- Ensure required services are running
- Check whether FCC data has changed
- Automatically skip the import if the FCC data is unchanged
- Download and apply updates only when new FCC data is available

If no updates are required, the script completes quickly without modifying
the database.

This makes first-run.sh suitable for repeated execution, automation,
and unattended operation.

---

## Scheduled Updates (Optional)

Because first-run.sh is idempotent and safe to re-run, it can be scheduled.

Example weekly cron job (runs every Sunday at 03:15):

15 3 * * 0 cd /opt/arcs && ./admin/first-run.sh >> logs/cron.log 2>&1

This will:
- Check for updated FCC data
- Apply updates only if the source has changed
- Leave the system untouched otherwise

---

## Accessing ARCS

### XML API (primary interface)

Port: 8080  
Example:
http://<host-ip>:8080/xml.php?callsign=W1AW

### Web UI (convenience only)

Port: 8081  
Example:
http://<host-ip>:8081

The Web UI is optional and provided only as a convenience.
API clients should use the XML API directly.

---

## Documentation

QUICKSTART.md  
Operational guide covering install, updates, status checks, and recovery.

readme-tech.md  
Technical reference describing architecture, state management, importer
locking, metadata, and design philosophy.

---

## Repository

Canonical source of truth:
https://github.com/N0LJD/ARCS

Current documentation version: v1.0.1
