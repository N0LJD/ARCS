# ARCS — Quick Start Guide

This document provides a concise operational guide for installing, updating,
and maintaining ARCS using the unified control script.

If you are new to the project, start here.

---

## Prerequisites

- Linux host
- Docker
- Docker Compose
- Internet access (to retrieve FCC ULS data)

---

## Initial Installation (New System)

1. Clone the repository and place it in the expected location:

git clone https://github.com/N0LJD/ARCS arcs
mv arcs /opt/arcs
cd /opt/arcs

2. Run the control script:

./admin/arcsctl.sh

On a system with no prior state, this will:

- Generate all required secrets
- Initialize the MariaDB database
- Download the FCC ULS l_amat.zip dataset
- Import and normalize license data
- Create database views used by the API
- Start the XML API and Web UI
- Record canonical system state in logs/arcs-state.json

No additional commands are required.

---

## Normal Operation (Existing System)

On an already-initialized system, running the same command:

./admin/arcsctl.sh

will act as a **reconciliation and update pass**:

- Ensures MariaDB is running and healthy
- Checks FCC metadata (ETag / Last-Modified)
- Skips the import if the source data is unchanged
- Downloads and applies new data if available
- Reconciles database permissions
- Ensures API and UI services are running

This behavior is intentional and safe.
Running the script multiple times is expected.

---

## Checking System Status

To view the current operational state without making changes:

./admin/arcsctl.sh --status

This prints a concise summary including:

- Last successful bootstrap
- Last importer run or skip reason
- FCC source metadata (checksum, size, ETag)
- Timestamp of last local data update

Canonical state is stored in:

logs/arcs-state.json

---

## Rebuilding the System (Cold Start)

To perform a full rebuild:

./admin/arcsctl.sh --coldstart --rotate-secrets

This will:

- Stop all containers
- Remove named volumes (database and cache)
- Generate new secrets
- Reinitialize the database from scratch
- Re-import FCC data
- Restart all services

This is destructive and intended for rebuilds only.

---

## Non-Interactive / CI Mode

For scripted or CI-style execution:

./admin/arcsctl.sh --ci

This suppresses interactive output and enables additional logging.

---

## Scheduling (Optional)

Because the control script is idempotent, it may be safely scheduled.
For example, a weekly check for FCC updates:

15 3 * * 0 cd /opt/arcs && ./admin/arcsctl.sh >> logs/cron.log 2>&1

---

## Key Operational Notes

- There is no separate “weekly import” script
- One command handles install, update, and reconciliation
- Import is skipped automatically when FCC data is unchanged
- All authoritative state is recorded in logs/arcs-state.json

---

For architectural details and design rationale, see:

readme-tech.md
