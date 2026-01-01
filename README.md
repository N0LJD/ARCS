# ARCS — Amateur Radio Call Service

ARCS (Amateur Radio Call Service) is a self-hosted, containerized amateur radio
callbook service that provides FCC ULS license data via a HamQTH-compatible XML API.

This project is intended for operators who want a **local, inspectable, and
self-managed** callbook service built from official FCC data.

ARCS is **NOT affiliated** with HamQTH. It implements a compatible API format 
strictly for interoperability.

---

## Why This Project Exists

ARCS exists as both a practical service and a learning reference.

It brings together:

- Docker and Docker Compose
- Linux service orchestration
- Python-based APIs
- Database-backed services
- Real-world amateur radio data

The emphasis is on **clarity, reproducibility, and local control**, not hosted
convenience or opaque automation.

---

## Requirements

- Linux-based operating system
- Docker
- Docker Compose

---

## Quick Setup

### 1. Download the project

git clone https://github.com/N0LJD/ARCS arcs
mv arcs /opt/arcs
cd /opt/arcs

---

### 2. Run the control script

./admin/arcsctl.sh

On a **new system**, this single command will:

- Generate required secrets
- Initialize MariaDB
- Download and import FCC ULS data
- Create schema and database views
- Start API and UI services
- Record canonical system state

On an **existing system**, the same command will:

- Start required services if stopped
- Check the FCC source for updated data
- Skip the import if the data is unchanged
- Download and apply new data if available
- Reconcile permissions and services safely

This command is **idempotent** and safe to re-run.

---

## Accessing ARCS

### XML API (primary interface)

- Port: **8080**
- Example:
  http://<host-ip>:8080/xml.php?callsign=W1AW

### Web UI (convenience only)

- Port: **8081**
- Example:
  http://<host-ip>:8081

The Web UI is optional and provided only as a convenience.
API clients should use the XML API directly.

---

## Operational Status

To view the current system state:

./admin/arcsctl.sh --status

This displays:

- Last bootstrap result and timing
- Last importer run or skip reason
- FCC source metadata (ETag, size, checksum)
- When local data was last updated

All canonical state is stored in:

logs/arcs-state.json

---

## Documentation

- QUICKSTART.md  
  Practical operational guide for install, update, rebuild, and status checks.

- readme-tech.md  
  Deep technical reference covering architecture, containers, data flow,
  state management, and design philosophy.

---

## Repository

Canonical source of truth:

https://github.com/N0LJD/ARCS

Current version line: **v1.0.x**
