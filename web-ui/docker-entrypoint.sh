#!/bin/sh
set -eu

# Default to same-origin reverse proxy path (recommended).
# This uses nginx location /api/ -> http://xml-api:8000/
UI_API_BASE_URL="${UI_API_BASE_URL:-/api}"

# Render config.js from template
sed "s|__UI_API_BASE_URL__|${UI_API_BASE_URL}|g" \
  /usr/share/nginx/html/config.template.js > /usr/share/nginx/html/config.js

# Exec nginx (foreground)
exec nginx -g 'daemon off;'
