# ARCS - Quickstart Guide
Amateur Radio Call Service (ARCS)

This Quickstart is written for **first-time, fresh installs**.
It assumes no existing Docker containers, volumes, or secrets.

ARCS provides:
- A local FCC ULS call database
- A HamQTH-compatible XML API (public accessible)
- A simple Web UI (XML API front-end) for convenience (public accessible)

Public API access is **read-only by design**.

---

## Prerequisites

You must have the following installed:

- Docker Engine (v24+ recommended)
- Docker Compose v2 (`docker compose`)
- curl (for testing)

Verify Docker:

docker version  
docker compose version  

---

## Directory Layout (important)

You should be in the project root:

ARCS/  
+-- docker-compose.yml  
+-- secrets/                # created by first-run.sh  
+-- admin/  
¦   +-- first-run.sh  
¦   +-- apply-db-users.sh  
¦   +-- db-users.txt  
¦   +-- db-users.template.txt  
+-- importer/  
+-- xml-api/  
+-- web-ui/  
+-- db-init/  

All commands below assume you are in the **ARCS root directory**.

---

## One-Time Initial Setup (First Run)

### Step 1: Make admin scripts executable

chmod +x admin/first-run.sh admin/apply-db-users.sh

---

### Step 2: Run first-run bootstrap

./admin/first-run.sh

You will be prompted with:

Executing this script will reset passwords for:
- MariaDB-root
- MariaDB-user (uls)
- xml_api (read-only public API user)

Type **y** or **yes** to continue.

What this script does:

1. Creates/resets secrets:
   - secrets/mariadb_root_password.txt
   - secrets/mariadb_user_password.txt
   - secrets/xml_api_password.txt
2. Creates:
   - admin/db-users.template.txt
   - admin/db-users.txt (with header commented)
3. Starts **MariaDB only**
4. Waits for the database to be healthy
5. Runs the importer:
   - applies schema
   - downloads FCC ULS data
   - loads and merges tables
6. Ensures database user **xml_api** exists with **read-only** privileges
7. Starts:
   - xml-api
   - web-ui

This script is **safe for a fresh install**.
It is intentionally conservative and explicit.

---

## Verify the System

### API Health

curl -sS http://127.0.0.1:8080/health

Expected output:

{"ok":true,"service":"ARCS API"}

---

### XML Callsign Query (HamQTH-compatible)

curl -sS "http://127.0.0.1:8080/xml.php?callsign=W1AW" | head -n 20

You should see valid XML data returned.

---

### Web UI Proxy Check

curl -sS http://127.0.0.1:8081/api/health

Expected output:

{"ok":true,"service":"ARCS API"}

The Web UI is available at:

http://127.0.0.1:8081

---

## Database Users (Important Concept)

ARCS intentionally separates database roles:

Purpose            | DB User   | Privileges  
-------------------|-----------|------------
Import / schema    | uls       | Write  
Public XML API     | xml_api   | Read-only  

- The **uls** account is created automatically by MariaDB on first initialization
- The **xml_api** account is created by admin scripts
- The XML API **never** uses write-capable credentials

This separation is intentional and part of ARCS security design.

---

## Managing Database Accounts (Optional / Advanced)

Edit:

admin/db-users.txt

Format:

# account,password,priv  
xml_api,public,r  

Apply changes:

./admin/apply-db-users.sh

Preview changes only:

./admin/apply-db-users.sh --dry-run

---

## Restarting the Stack Later

Normal restarts do **not** require first-run:

docker compose up -d

To refresh FCC data later:

docker compose run --rm uls-importer

---

## Notes on Automation (Future)

- xml-api assumes the xml_api DB user already exists
- Startup order is intentionally explicit
- A future xml-api “wait wrapper” may allow single-command startup
- This behavior is documented by design

---

## Troubleshooting Basics

Check container status:

docker compose ps

View logs:

docker logs arcs-xml-api  
docker logs arcs-uls-mariadb  

---

## You Are Done

At this point:
- The database is populated
- The XML API is live
- The Web UI is live
- Public queries are read-only
- Secrets are local and not embedded in images

You are running a clean ARCS installation.

---

## Future work to be done

- Verify uls account for importer/admin
- XML to use xml-api account only
- Change xml-api so it doesn't use public as the password

- Consolidate documentation **readme**
- Health Check - One command to verify DB, API, UI Health
- Graceful startup Guards
    - API return 503 until DB + schema ready
- Import Metadata Tracking
    - Store: Import Date, FCC File Version, Record counts

- Hardening 
    - Nginx
    - API exposure
    - rate limiting
    - reverse proxy

- JSON API (Parallel, not replacement)
    - LetsEncrypt for ssh

- Incremental Updates
    - Weekly delta imports with fill rebuild fallback

