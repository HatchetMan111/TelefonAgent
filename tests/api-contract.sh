#!/usr/bin/env bash
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:5678/webhook/shopagent}"
SECRET="${AGENT_WEBHOOK_SECRET:?AGENT_WEBHOOK_SECRET fehlt}"

check() {
  local path="$1" body="$2"
  shift 2
  local out expect
  out="$(curl -fsS -X POST "$BASE/$path" -H "Authorization: Bearer $SECRET" \
    -H 'Content-Type: application/json' -d "$body")"
  for expect in "$@"; do
    echo "$out" | grep -qF "$expect" || { echo "FAIL $path: $out"; exit 1; }
  done
  echo "OK $path"
}

# 401 ohne Secret
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/search" -H 'Content-Type: application/json' -d '{"query":"x"}')"
[[ "$code" == "401" ]] || { echo "FAIL auth: $code"; exit 1; }
echo "OK auth"

# Unbekannte Action -> 404
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/unbekannt" \
  -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d '{}')"
[[ "$code" == "404" ]] || { echo "FAIL unknown action: $code"; exit 1; }
echo "OK unknown action"

check search '{"query":"Regenschuh"}' '"products"' '"as_of"' '"price_eur"'
check product '{"sku":"REGEN-42"}' '"product"' '"variants"' '"price_eur"'
check info '{"topic":"oeffnungszeiten"}' '"answer"' '"source_url"' '"as_of"'
check callback '{"name":"Max","phone":"+491701234567","reason":"Test"}' '"reference"'
check handoff '{"reason":"Test"}' '"action"'
echo "API-CONTRACT OK"
