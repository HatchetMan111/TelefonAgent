#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

docker compose --env-file "$ROOT/.env" -f "$ROOT/vm/docker-compose.yml" down || true

if [[ -d "$ROOT/firecrawl" ]]; then
  (
    cd "$ROOT/firecrawl"
    docker compose -f docker-compose.yaml -f "$ROOT/vm/firecrawl.override.yml" stop || true
  )
fi
