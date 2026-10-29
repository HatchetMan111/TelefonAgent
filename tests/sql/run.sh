#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CID="shopagent-sqltest-$$"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! docker info >/dev/null 2>&1; then
  echo "FEHLER: Docker ist nicht erreichbar (kein Zugriff auf den Docker-Socket)." >&2
  echo "Fix: Benutzer zur Gruppe 'docker' hinzufuegen und neu anmelden:" >&2
  echo "  sudo usermod -aG docker \$USER" >&2
  echo "Oder das Skript mit sudo ausfuehren:" >&2
  echo "  sudo tests/sql/run.sh" >&2
  exit 1
fi

IMAGE="${POSTGRES_IMAGE:-postgres:15}"
docker run -d --rm --name "$CID" -e POSTGRES_PASSWORD=test -p 127.0.0.1:55432:5432 "$IMAGE" >/dev/null
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
