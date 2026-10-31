#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

docker network inspect telefonagent >/dev/null 2>&1 || docker network create telefonagent

(
  cd "$ROOT/firecrawl"
  docker compose -f docker-compose.yaml -f "$ROOT/vm/firecrawl.override.yml" up -d
)

exec docker compose --env-file "$ROOT/.env" -f "$ROOT/vm/docker-compose.yml" up
