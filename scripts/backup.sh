#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
STAMP="$(date +%F-%H%M)"
OUT="${BACKUP_DIR}/${STAMP}"
mkdir -p "$OUT"
export PGPASSWORD="$DB_ADMIN_PASSWORD"
pg_dump -h 127.0.0.1 -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -Fc -f "$OUT/postgres.dump"
pg_dump -h 127.0.0.1 -p "$DB_PORT" -U "$DB_ADMIN_USER" -d n8n -Fc -f "$OUT/n8n.dump"
(cd "$OUT" && sha256sum *.dump > SHA256SUMS)
psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 \
  -c "delete from callbacks where created_at < now() - interval '30 days';"
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+${BACKUP_RETAIN_DAYS}" -exec rm -rf {} +
echo "Backup: $OUT"
