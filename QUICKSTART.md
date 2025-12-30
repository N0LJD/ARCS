# ARCS Quick Start
# Edward Moss - N0LJD

This document describes the single supported method to bring ARCS online
from a clean system using the automated bootstrap process.

This is not an operator manual. Its purpose is to get a functional system
running quickly, predictably, and in a known-good baseline state.

---

## Prerequisites

- Linux host
- Docker and docker-compose installed
- Internet access (required to download FCC ULS data)
- Approximately 20 GB of free disk space

The reference system used for validation is documented in README.md.

---

## First-Time Startup

ARCS provides an automated bootstrap script that performs all required setup
steps in the correct order. This includes:

- Generating Docker secrets
- Starting required containers
- Downloading FCC ULS data
- Initializing and populating the database
- Bringing the XML API and Web UI online

From the project root directory, run:

./admin/first-run.sh

---

## Expected Runtime

Initial startup typically takes approximately 10 minutes, depending on
network speed and disk performance.

This script is safe to re-run and is the authoritative bootstrap mechanism
for the v1.0.0 baseline.

---

## System Health Verification

After the bootstrap process completes, verify system health by running:

./admin/sanity-check.sh

This script performs basic validation checks, including:

- Docker container status
- Presence of required secrets
- Database availability
- XML API responsiveness
- Web UI reverse proxy functionality

A clean run indicates the system is operating as expected.

---

## XML API Test Example

The XML API is compatible with the HamQTH API format and is case-insensitive
for callsign queries.

Example using curl:

curl "http://localhost:8080/xml.php?callsign=W1AW"

A successful response returns an XML document containing callsign data.

---

## Web UI Access

If the Web UI container is enabled, open a browser and navigate to:

http://localhost:8081/

The Web UI is provided as a convenience interface and is not required for
API-based integrations.

---

For architectural details, design decisions, and internal behavior, see
readme-tech.txt.

