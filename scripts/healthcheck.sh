#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
FAIL=0
note() { echo "FAIL: $*" >&2; FAIL=1; }

pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" >/dev/null || note "postgres"
curl -fsS "http://$N8N_LAN_IP:5678/healthz" >/dev/null || note "n8n"
HHMM="$(date +%H%M)"
if [[ ! "$HHMM" < "0250" ]] && [[ "$HHMM" < "0400" ]]; then
  curl -fsS "http://$FIRECRAWL_HOST:$FIRECRAWL_PORT/test" >/dev/null || note "firecrawl"
fi

if ! FRESH="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tAc \
  "select coalesce(max(last_seen_at) > now() - interval '36 hours', false) from products;")"; then
  note "produktdaten abfrage fehlgeschlagen"
elif [[ "$FRESH" != "t" ]]; then
  note "produktdaten älter als 36h"
fi

STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/shopagent}"
mkdir -p "$STATE_DIR"
COUNT="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tAc \
  "select count(*) from products where is_active;" 2>/dev/null || true)"
PREV="$(cat "$STATE_DIR/product-count" 2>/dev/null || true)"
if [[ "$PREV" =~ ^[0-9]+$ && "$COUNT" =~ ^[0-9]+$ && "$PREV" -gt 0 && "$COUNT" -lt $((PREV * 80 / 100)) ]]; then
  note "produktzahl sinkt ($PREV -> $COUNT)"
fi
[[ "$COUNT" =~ ^[0-9]+$ ]] && echo "$COUNT" > "$STATE_DIR/product-count"

CODE="$(curl -s -o /dev/null -w '%{http_code}' "https://$TUNNEL_HOST/webhook/shopagent/search" \
  -X POST -H 'Content-Type: application/json' -d '{}' || true)"
CODE="${CODE:-000}"
[[ "$CODE" == "401" ]] || note "tunnel/auth (HTTP $CODE)"

if [[ "$FAIL" -ne 0 ]]; then
  curl -fsS -d "ShopAgent Healthcheck fehlgeschlagen auf $(hostname)" "$NTFY_URL" >/dev/null || true
  exit 1
fi
echo "HEALTH OK"
