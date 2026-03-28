#!/bin/bash
# Fix permissions on database files (created by root during init)
echo "Fixing database permissions..."
chown -R overpass:overpass /db/db/ 2>/dev/null
chmod 755 /db/ /db/db/ 2>/dev/null
chmod -R 755 /db/db/ 2>/dev/null

# Remove stale sockets
find /db/db -type s -print0 | xargs -0 --no-run-if-empty rm 2>/dev/null
find /nginx -type s -print0 | xargs -0 --no-run-if-empty rm 2>/dev/null

# Generate nginx config from template (the original entrypoint does this)
export OVERPASS_MAX_TIMEOUT=${OVERPASS_MAX_TIMEOUT:-60s}
envsubst '${OVERPASS_MAX_TIMEOUT}' </etc/nginx/nginx.conf.template >/etc/nginx/nginx.conf

echo "Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
