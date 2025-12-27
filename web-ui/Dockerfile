FROM nginx:alpine

# Static assets
COPY index.html /usr/share/nginx/html/index.html
COPY app.js /usr/share/nginx/html/app.js
COPY config.template.js /usr/share/nginx/html/config.template.js

# Nginx site config (adds /api reverse proxy)
COPY default.conf /etc/nginx/conf.d/default.conf

# Entrypoint renders config.js based on env var UI_API_BASE_URL
COPY docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
