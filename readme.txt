HamCall - FCC ULS Callbook (Dockerized)
Author: Edward Moss, N0LJD

-----------------------------------------------------------------------------

Why this project exists -

This project began as a personal learning exercise. I wanted hands-on
experience with Linux system administration, Docker and container
orchestration, SQL and database design, Python development, shell
scripting, and building simple but reliable APIs.

It also serves as a practical exploration of layered system design and
security concepts, including separation between a front-end web service,
an application layer, and a back-end database with strict least-privilege
access controls.

Amateur Radio provided the catalyst that brought these elements together.
The FCC ULS dataset is public, structured, and regularly updated, making
it an ideal real-world data source for learning, experimentation, and
community-oriented tooling.

This software is shared in the spirit of education, experimentation, and
technical curiosity, and may be useful to others interested in similar
learning goals or self-hosted amateur radio infrastructure.

-----------------------------------------------------------------------------

This project, HamCall, is an independently developed, self-hosted
software system for importing and querying publicly available FCC ULS
Amateur Radio licensing data.

It is not affiliated with, endorsed by, or connected to HamCall.net
or Buckmaster International LLC.
The name is used in a descriptive sense only, to refer to the general
idea of an amateur radio callbook.

All data used by this project is sourced from publicly available FCC
datasets, and this software is provided for educational, experimental,
and community use.

-----------------------------------------------------------------------------

OVERVIEW


HamCall is a Docker-based system that imports the FCC Universal Licensing
System (ULS) Amateur Radio database and exposes a clean, read-only,
HamQTH-style XML callbook API.

The system performs four core functions:
1. Download the FCC ULS Amateur Radio dataset
2. Import and normalize the data into MariaDB
3. Build a query-optimized callbook view
4.  Serve read-only XML queries over HTTP

The design goals are:
* Fully rebuildable from empty volumes
* Least-privilege security model
*Clear separation of responsibilities
* Safe for unattended scheduled operation
* Suitable for homelab or internet-facing deployments

HIGH-LEVEL ARCHITECTURE
HamCall consists of three Docker containers managed by Docker Compose.

1. uls-mariadb (Persistent Database)
	MariaDB 11
	Stores FCC ULS data and derived views
	Uses a persistent Docker volume
	Not exposed to the network
	All credentials provided via Docker secrets

2. uls-importer (One-Shot Import Job)
	Runs only when invoked manually or via cron
	Downloads FCC data
	Loads staging tables
	Merges data into final tables
	Rebuilds the public callbook view

3. xml-api (Public Query Service)
	Long-running FastAPI service
	Read-only access to callbook data
	Uses a dedicated read-only database account
	Exposes HamQTH-style XML over HTTP

-----------------------------------------------------------------------------

TEXT ARCHITECTURE FLOW

Host system (Ubuntu VM on Proxmox)
|
| cron
| run-weekly-import.sh
v
uls-importer (job container)
|
| downloads FCC ZIP
| loads staging tables
| merges final tables
v
uls-mariadb (persistent database)
^
|
xml-api (read-only service)
|
| HTTP port 8080
v
Internet / local clients

Networks:
uls_db_net (internal-only database traffic)
uls_ext_net (external access for xml-api)

Volumes:

uls_db_data (MariaDB data directory)
uls_cache (FCC ZIP and extracted files)

DIRECTORY STRUCTURE

/opt/hamcall
|
|-- docker-compose.yml
|-- README.txt
|-- run-weekly-import.sh
|-- sanity_check.sh
|-- admin-set-callbook-ro.sh
|
|-- secrets/
| |-- mariadb_root_password.txt
| |-- mariadb_user_password.txt
| |-- callbook_ro_password.txt
|
|-- db-init/
| |-- 03-callbook-ro.sql
|
|-- importer/
| |-- Dockerfile
| |-- import_uls.py
| |-- schema.sql
|
|-- xml-api/
|-- Dockerfile
|-- app.py

SECRETS AND SECURITY MODEL

No plaintext passwords are stored in docker-compose.yml.

All database credentials live in /opt/hamcall/secrets and are mounted
into containers using Docker secrets.

Required secret files:
mariadb_root_password.txt
mariadb_user_password.txt
callbook_ro_password.txt

Each file should contain only the password value.

Database accounts:

root
Purpose: administrative access
Privileges: full

uls
Purpose: importer account
Privileges: full access to the uls database

callbook_ro
Purpose: XML API
Privileges: SELECT only on v_callbook

The XML API user cannot access base tables.

DATABASE DESIGN

FCC Source Files:

HD.dat
License header information (callsign, status, dates)

EN.dat
Entity name and address information

AM.dat
Amateur operator class (authoritative source)

Tables:

stg_hd, stg_en, stg_am
Raw staging tables loaded directly from FCC files

hd, en, am
Normalized final tables used for queries

Public View:

v_callbook
Joined view of hd, en, and am
Contains cleaned, API-friendly fields
Only object readable by the XML API user

OPERATOR CLASS LOGIC (IMPORTANT)

FCC behavior:

Individual licenses usually have an operator class

Club or station licenses often do not

Design decision:

If am.operator_class is NULL
AND en.licensee_name is present
THEN operator_class_name = "Club"

This logic exists ONLY in schema.sql.
It is intentionally not duplicated in Python code.

IMPORT PROCESS (ULS-IMPORTER)
The importer runs as a one-shot job and performs:
Apply schema.sql (idempotent)
Download FCC l_amat.zip (cached if present)
Extract data files
Convert files to UTF-8
Load staging tables using LOAD DATA LOCAL INFILE
Merge staging tables into final tables
Emit diagnostics and row counts

Manual execution:
docker compose run --rm uls-importer
The importer is safe to re-run at any time.

SCHEDULING WEEKLY IMPORTS
Imports are typically scheduled via cron.
Example: Friday at 03:15 AM
15 3 * * 5 /opt/hamcall/run-weekly-import.sh >> /var/log/uls-import.log 2>&1

The script:
Uses flock to prevent overlapping runs
Logs all output
Exits cleanly on failure

XML API USAGE
Endpoint:
GET /xml.php?callsign=W1AW

Example request:
curl http://localhost:8080/xml.php?callsign=W1AW

Response format:
XML

Content-Type: application/xml; charset=utf-8
HamQTH-compatible structure

ADMIN AND VALIDATION TOOLS
Sanity check script:
./sanity_check.sh

Performs:
Container health checks
Database connectivity validation
Read-only privilege enforcement
API functional checks
Admin script (RO user maintenance):

sudo ./admin-set-callbook-ro.sh
Used to:
Apply or reapply least-privilege grants
Rotate read-only user credentials
Verify correct access behavior

REBUILD AND RECOVERY
To rebuild the system from scratch:
docker compose down -v
docker compose up -d uls-mariadb xml-api
docker compose run --rm uls-importer
This recreates the database and reloads FCC data.

TROUBLESHOOTING
API returns "Backend error":
Database authentication issue
Database not reachable
Incorrect secrets

Importer fails authentication:
Secret not mounted
Incorrect DB_PASS_FILE configuration
Missing operator class:
Review logic in schema.sql

Database empty after restart:
Persistent volume removed or recreated

Useful commands:
docker compose ps
docker compose logs xml-api
docker compose exec uls-mariadb mariadb -uroot

DESIGN PHILOSOPHY
Schema owns presentation logic
Importer owns data movement
Shell scripts own scheduling
API is read-only and simple
This separation keeps the system predictable, secure, and easy to debug.

NOTES FOR FUTURE MAINTENANCE
Do not derive operator class from HD.dat
Treat schema.sql as authoritative
Update import_uls.py if FCC formats change
Always test from an empty volume
Never grant API access to base tables

END OF README.TXT
