# ARCS – Amateur Radio Call Search
# Edward Moss - N0LJD

---

ARCS (Amateur Radio Call Search) is a self-hosted, containerized amateur radio
callbook service that provides FCC ULS license lookup data through a
HamQTH-compatible XML API.

The project is designed to be simple, transparent, and educational while
remaining interoperable with amateur radio software that expects the HamQTH
XML API format.

---

## What ARCS Provides

- A **HamQTH-compatible XML API** for amateur radio callsign lookups
- Uses **official FCC ULS amateur license data**
- Fully **self-hosted** using Docker and docker-compose
- Optional **Web UI** for basic lookups
- Clear separation between API, database, importer, and UI components

Once deployed, ARCS does not rely on external callbook services.

---

## Why This Project Exists

Personally, I wanted to learn more about Linux, Docker, SQL, Python, scripting,
and APIs. This project also explores security concepts by separating a
front-end web server, an application layer, and a back-end database.

Amateur Radio serves as the catalyst for bringing these components together
into a practical, real-world system.

---

## High-Level Architecture

ARCS consists of four Docker services:

- **arcs-uls-mariadb**  
  MariaDB database containing FCC ULS data

- **arcs-uls-importer**  
  One-shot job that downloads and loads FCC ULS data

- **arcs-xml-api**  
  FastAPI-based HamQTH-compatible XML API

- **arcs-web-ui**  
  nginx-based static Web UI and reverse proxy

The database runs on an internal Docker network and is never exposed externally.

---

## Documentation Overview

- **README.md**  
  Project overview (this file)

- **QUICKSTART.md**  
  Minimal, verified steps to bring ARCS online

- **readme-tech.txt**  
  Technical deep dive into containers, design decisions, and internals

- **ARCS_BASELINE.md**  
  Canonical baseline reference used for long-term consistency and AI context

---

## Non-Affiliation Disclaimer

ARCS is **not affiliated with**: HamQTH, HamCall, or Buckmaster International.
This project implements a compatible API format strictly for interoperability.

---

## License & Data

- **Code License:** MIT License
- **Data Source:** FCC ULS amateur license data (public domain)

ARCS does not redistribute FCC data outside the running system and does not
claim ownership of FCC ULS data.

---

## Reference Test Environment

Validated using:

- Ubuntu Server 24.04
- 4 GB RAM
- 20 GB storage
- Virtual machine under Proxmox VE 9.1.4
- Host: Intel NUC8i5 with 32 GB RAM and 256 GB storage

---

For setup instructions, see **QUICKSTART.md**.  
For architectural and internal details, see **readme-tech.txt**.

