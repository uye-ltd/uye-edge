#!/usr/bin/env bash
# certbot-renew.sh — renew Let's Encrypt certificates and reload nginx.
#
# Intended to be run as a cron job on the host or inside a scheduled container:
#   0 3 * * * /opt/uye-edge/scripts/certbot-renew.sh >> /var/log/certbot-renew.log 2>&1
set -euo pipefail

COMPOSE_FILE="$(cd "$(dirname "$0")/.." && pwd)/docker-compose.yml"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting certificate renewal ..."

# Run certbot renew inside the certbot container
docker compose -f "$COMPOSE_FILE" \
    --profile certbot \
    run --rm certbot renew --quiet

# Reload nginx config so it picks up the refreshed certificates
docker compose -f "$COMPOSE_FILE" exec nginx nginx -s reload

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Certificate renewal complete."
