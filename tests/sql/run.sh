#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CID="shopagent-sqltest-$$"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --name "$CID" -e POSTGRES_PASSWORD=test -p 55432:5432 postgres:17 >/dev/null
for _ in $(seq 1 60); do
  docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CID" pg_isready -U postgres >/dev/null

PSQL=(docker exec -i -e PGPASSWORD=test "$CID" psql -U postgres -d postgres -v ON_ERROR_STOP=1)
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "apply $(basename "$f")"
  "${PSQL[@]}" < "$f"
done
for f in "$ROOT"/tests/sql/assert-*.sql; do
  echo "assert $(basename "$f")"
  "${PSQL[@]}" < "$f"
done
echo "SQL-TESTS OK"
