# ARCS Quick Start Guide

This document explains how to bring ARCS online for the first time and how
ongoing operation works once the system is established.

ARCS is designed so that the same command can be run safely on both a new
system and an existing system.

---

## Prerequisites

Before starting, ensure the following are installed:

- Linux-based operating system
- Docker
- Docker Compose (v2)
- Internet access (for FCC data download)

---

## Initial Installation (New System)

From the project root directory:

./admin/first-run.sh

### What happens during the first run

When executed on a fresh system with no prior state, first-run.sh will:

1. Detect that required secrets do not exist
2. Generate local secret files under ./secrets
3. Start the MariaDB container and wait for it to become healthy
4. Run the ULS importer, which:
   - Downloads the FCC ULS Amateur Radio dataset
   - Applies database schema
   - Imports license and entity data
   - Builds the callbook view
5. Create and enforce a least-privilege database user for the API
6. Start the XML API and Web UI services
7. Run sanity checks to verify correct operation
8. Record bootstrap and importer metadata

No manual configuration is required for a standard installation.

---

## Normal Operation (Existing System)

Once ARCS is installed, the same command is used for maintenance:

./admin/first-run.sh

### What happens on subsequent runs

On an existing system, first-run.sh behaves as a reconciliation and update
process:

- Existing secrets are preserved
- Docker volumes are not removed
- Services are started if stopped
- Database schema and views are ensured
- The importer runs in safe mode:
  - Acquires a database-level lock
  - Checks FCC source metadata
  - Automatically skips the import if the FCC data is unchanged
  - Downloads and applies updates only when new data is available

If no FCC updates are detected, the script performs a no-op import and exits
cleanly without modifying the database.

Because of this behavior, first-run.sh may be safely scheduled (for example,
via a weekly cron job) to check for FCC updates.

---

## Checking System Status

To inspect system state without modifying anything:

./admin/first-run.sh --status

This prints a concise summary including:

- Last bootstrap result
- Last importer run result
- Whether the last import was skipped or applied
- Relevant timestamps and source metadata

---

## Forcing a Full Reset

If a complete rebuild is required:

./admin/first-run.sh --coldstart --rotate-secrets

This will:

- Stop all running services
- Remove named Docker volumes
- Regenerate secrets
- Perform a full database reinitialization and import

This operation is destructive and should be used deliberately.

---

## Accessing the Services

Once running:

XML API  
- Primary interface for applications
- Port and endpoint defined by your Docker configuration

Web UI  
- Optional, human-facing interface
- Provided for convenience only

Refer to README.md for example URLs.

---

## Operational Notes

- Running first-run.sh multiple times is expected and safe
- Imports are skipped automatically when no FCC data changes are detected
- All significant actions are recorded in logs/arcs-state.json
- Legacy bootstrap metadata is also written to admin/.bootstrap_complete

---

## Summary

- One command (first-run.sh) is used for install, update, and reconciliation
- New systems are initialized automatically
- Existing systems are updated only when necessary
- Explicit flags are required for destructive operations

This design supports unattended operation and long-term self-hosting.
