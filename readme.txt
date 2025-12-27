ARCS - Amateur Radio Call Search
===============================

ARCS (Amateur Radio Call Search) is a self-hosted, Docker-based callbook system
backed by publicly available FCC Universal Licensing System (ULS) data.

The system provides:
- An XML API for callsign lookup and advanced searches
- A lightweight web-based search UI
- A local FCC ULS-backed callbook database

Why this project exists
-----------------------
This project exists as a learning and exploration platform, bringing together
Linux, Docker, SQL, Python, APIs, and basic security concepts using Amateur Radio
as the unifying theme.

Non-Affiliation Disclaimer
--------------------------
ARCS is an independently developed project and is not affiliated with, endorsed by,
or connected to:

- HamCall.net
- Buckmaster International LLC
- HamQTH.com

Some responses may be formatted for compatibility with applications that support
the HamQTH API format. ARCS does not replicate paid or proprietary datasets.

Architecture Overview
---------------------
ARCS consists of Docker containers managed by Docker Compose:

1. MariaDB
   - Stores imported FCC ULS data
   - Includes a callbook-friendly view (`v_callbook`)

2. XML API
   - Read-only access to FCC ULS data
   - Supports callsign lookups and advanced searches

3. Web UI
   - Browser-based search interface
   - Uses the local XML API via a reverse proxy

License & Data
--------------
FCC ULS data is public domain. This project does not redistribute or claim
ownership of FCC data.

