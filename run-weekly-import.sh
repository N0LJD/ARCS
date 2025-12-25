#!/usr/bin/env bash
#
# run-weekly-import.sh
# Edward Moss - N0LJD
#
# --------------------
# Entry point for running the FCC ULS import job.
#
# This script is designed to be:
#   - Safe to run manually
#   - Safe to run from cron
#   - Safe against overlapping executions
#
# Typical usage:
#   Manual:
#     /opt/hamcall/run-weekly-import.sh
#
#   Cron (example: Fridays at 03:15):
#     15 3 * * 5 /opt/hamcall/run-weekly-import.sh >> /var/log/uls-import.log 2>&1
#
# High-level flow:
#   1) Acquire an exclusive lock to prevent concurrent runs
#   2) Change to the project directory
#   3) Run the Docker Compose importer as a one-shot job
#
# Notes:
#   - The actual import logic lives in importer/import_uls.py
#   - Database schema and views are defined in importer/schema.sql
#   - This script only orchestrates execution; it does not process data itself
#

# Fail fast and fail safely:
#   -e : exit immediately on any command failure
#   -u : error on use of unset variables
#   -o pipefail : fail if any command in a pipeline fails
set -euo pipefail


# Location of the lock file used to prevent overlapping runs.
# /var/lock is standard for system-wide lock files.
LOCKFILE="/var/lock/uls-import.lock"


# ----------------------------
# Lock acquisition
# ----------------------------
#
# We use file descriptor 9 to hold the lock.
# If another instance is already running, flock -n will fail immediately.
#
# This is important for cron:
# - Prevents overlapping imports if a previous run is slow or stuck
# - Avoids concurrent schema changes or data loads
#
exec 9>"$LOCKFILE"

if ! flock -n 9; then
    echo "[LOCK] Import already running, exiting."
    exit 0
fi


# ----------------------------
# Run the importer
# ----------------------------

# Ensure we are in the project directory so docker-compose.yml is found
cd /opt/hamcall

# Run the importer as a one-shot container:
#   --rm : remove the container after it exits
#   uls-importer : service defined in docker-compose.yml
#
# The importer container:
#   - Applies schema.sql
#   - Downloads FCC data if needed
#   - Loads and merges tables
#   - Builds/refreshes v_callbook
#
docker compose run --rm uls-importer
