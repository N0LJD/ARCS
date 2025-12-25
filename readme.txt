# HamCall - FCC ULS Callbook (Dockerized)
# Edward Moss - N0LJD


HamCall is a Docker-based system that imports the FCC ULS Amateur Radio
licensing database and exposes a clean, query-friendly callbook view
via a lightweight XML API.

The project is designed to be:
- Repeatable (safe to rebuild from scratch)
- Observable (clear logs and diagnostics)
- Maintainable (schema, import logic, and orchestration are separated)

---

## High-Level Architecture

The system consists of three Docker containers:

1. **uls-mariadb**  
   Persistent MariaDB database storing FCC ULS data and derived views.

2. **uls-importer**  
   One-shot job container that:
   - Downloads FCC data
   - Loads staging tables
   - Merges into final tables
   - Creates/updates the public `v_callbook` view

3. **xml-api**  
   Long-running service that exposes read-only access to the callbook.

A cron-safe shell script orchestrates the weekly import.

---

## Text-Based Architecture Diagram


                         (Host / Linux)
                  /opt/hamcall/run-weekly-import.sh
                               |
                               |  cron (example)
                               |  15 3 * * 5 ... >> /var/log/uls-import.log 2>&1
                               v
+--------------------------------------------------------------------------+
|                          Docker Compose Project                           |
+--------------------------------------------------------------------------+

   Networks:
     [uls_ext_net]  (external / published ports allowed)
     [uls_db_net ]  (internal: true; no outbound to internet)

   Volumes:
     [uls_db_data]  -> MariaDB data directory (/var/lib/mysql)
     [uls_cache  ]  -> FCC ZIP + extracted .dat files (/data)



  ------------------------------------------------------------------------
  1) One-shot weekly import job (uls-importer) - started by script/cron
  ------------------------------------------------------------------------

        +------------------------------+
        |  uls-importer (job)          |
        |  container: uls-importer     |
        |  runs: import_uls.py         |
        |                              |
        |  bind mounts (read-only):    |
        |   ./importer/schema.sql      |
        |   ./importer/import_uls.py   |
        |                              |
        |  volume: uls_cache -> /data  |
        +------------------------------+
                 |              |
                 |              | downloads (internet)
                 |              v
                 |      FCC ULS ZIP (l_amat.zip)
                 |      https://data.fcc.gov/.../l_amat.zip
                 |
                 | LOAD DATA LOCAL INFILE, merges staging->final,
                 | creates/updates v_callbook view (schema.sql)
                 v
        +------------------------------+
        |  uls-mariadb (service)       |
        |  image: mariadb:11           |
        |  DB: uls                     |
        |  tables: stg_* , hd, en, am  |
        |  view: v_callbook            |
        |  volume: uls_db_data         |
        +------------------------------+
                 ^
                 |
          network: uls_db_net (internal)



  ------------------------------------------------------------------------
  2) Normal operation (public queries) via xml-api
  ------------------------------------------------------------------------

   Internet clients
         |
         |  HTTP :8080 (published on host)
         v
+------------------------------+           network: uls_db_net (internal)
|  xml-api (service)           |----------------------------------------+
|  container: xml-api          |                                        |
|  listens: 8000 (published)   |                                        |
|  reads from v_callbook view  |                                        |
|  DB user: callbook_ro (read) |                                        |
+------------------------------+                                        |
        ^                                                               |
        | network: uls_ext_net                                          |
        +---------------------------------------------------------------+
                                 |
                                 v
                        +------------------------------+
                        |  uls-mariadb (service)       |
                        |  serves read queries         |
                        +------------------------------+


-------------------------------------------------------------------------

## Database Design

### Source Files (FCC ULS)
- **HD.dat** – License header (callsign, status, dates)
- **EN.dat** – Entity / licensee name and address
- **AM.dat** – Amateur operator class (authoritative source)

### Tables
- `stg_hd`, `stg_en`, `stg_am`  
  Raw staging tables loaded directly from FCC files.

- `hd`, `en`, `am`  
  Final normalized tables used for queries.

### Public View
- **`v_callbook`**  
  A callbook-friendly view that:
  - Joins `hd`, `en`, and `am`
  - Produces clean text fields
  - Adds derived fields such as `operator_class_name`

---

## Operator Class Logic (Important)

FCC behavior:
- Individual licenses have an operator class in `AM.dat`
- Club / station licenses often have **NULL** operator class

Design decision:
- If `am.operator_class` is NULL **and**
  `en.entity_name` is present ? classify as **"Club"**

This logic lives **only in `schema.sql`**, not in Python.

Example mapping:
- `E` ? Extra
- `A` ? Advanced
- `G` ? General
- `T` ? Technician
- `N` ? Novice
- `NULL + entity_name` ? Club

---

## Import Process (uls-importer)

The importer runs as a one-shot job and performs:

1. Apply `schema.sql` (idempotent)
2. Download `l_amat.zip` (if not cached)
3. Extract `HD.dat`, `EN.dat`, `AM.dat`
4. Convert files to UTF-8
5. Load staging tables via `LOAD DATA LOCAL INFILE`
6. Merge into final tables
7. Emit diagnostics (row counts, class distribution)

It is safe to re-run at any time.

---

## Scheduling the Import

The import is orchestrated by:

------------------------------------------------------------------------
## Rebuild / Recovery

To rebuild everything from scratch:

```bash
docker compose down -v
docker compose up -d uls-mariadb xml-api
./run-weekly-import.sh

------------------------------------------------------------------------
Design Philosophy

Schema owns presentation logic
Importer owns data movement
Shell script owns scheduling
API is read-only and dumb
This separation keeps the system predictable and easy to debug.


-----------------------------------------------------------------------
Notes for Future Maintenance

Do NOT derive operator class from HD.dat
Treat schema.sql as authoritative
If the FCC file format changes, adjust import_uls.py mappings
Always test changes by rebuilding from an empty volume
