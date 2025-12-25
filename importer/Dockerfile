FROM python:3.12-slim

WORKDIR /app

# Tools we need: TLS certs + unzip (for l_amat.zip)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates unzip \
  && rm -rf /var/lib/apt/lists/*

# Python deps installed next (requirements.txt will be created in a later step)
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# App files (we'll create these in later steps)
COPY import_uls.py /app/import_uls.py
COPY schema.sql /app/schema.sql

ENTRYPOINT ["python", "/app/import_uls.py"]
