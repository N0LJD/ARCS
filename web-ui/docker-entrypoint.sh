#!/bin/sh
set -eu

# -----------------------------------------------------------------------------
# ARCS Web UI entrypoint
# - Renders config.js from config.template.js
# - Writes /health.json including version for QA/monitoring
# - Starts nginx (foreground)
# -----------------------------------------------------------------------------

WEB_ROOT="/usr/share/nginx/html"

# Default to same-origin reverse proxy path (recommended).
# This uses nginx location /api/ -> http://xml-api:8000/
UI_API_BASE_URL="${UI_API_BASE_URL:-/api}"

# UI version (set via docker-compose env ARCS_UI_VERSION, defaults to "dev")
ARCS_UI_VERSION="${ARCS_UI_VERSION:-dev}"

# Render config.js from template (preserves existing behavior)
sed "s|__UI_API_BASE_URL__|${UI_API_BASE_URL}|g" \
  "${WEB_ROOT}/config.template.js" > "${WEB_ROOT}/config.js"

# Write a stable, versioned health endpoint for QA/monitoring
cat > "${WEB_ROOT}/health.json" <<EOF
{"ok":true,"service":"ARCS Web UI","version":"${ARCS_UI_VERSION}"}
EOF

# Ensure nginx can read the generated files
chmod 0644 "${WEB_ROOT}/config.js" "${WEB_ROOT}/health.json" 2>/dev/null || true

# Exec nginx (foreground)
exec nginx -g 'daemon off;'
