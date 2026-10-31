#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
DUMP="${1:?Pfad zum Dump angeben}"
SCRATCH="${2:-restore_test}"

if [[ ! "$SCRATCH" =~ ^[a-z_][a-z0-9_]*$ ]]; then
  echo "Ungueltiger Scratch-DB-Name: $SCRATCH" >&2
  exit 1
fi
case "$SCRATCH" in
  postgres|n8n|template*)
    echo "Scratch-DB darf nicht $SCRATCH heissen." >&2
    exit 1
    ;;
esac

DIR="$(cd "$(dirname "$DUMP")" && pwd)"
BASE="$(basename "$DUMP")"
if [[ -f "$DIR/SHA256SUMS" ]]; then
  CHECK="$(grep -F -- " ${BASE}" "$DIR/SHA256SUMS" || true)"
  if [[ -z "$CHECK" ]]; then
    echo "Kein Eintrag fuer $BASE in $DIR/SHA256SUMS." >&2
    exit 1
  fi
  if ! (cd "$DIR" && printf '%s\n' "$CHECK" | sha256sum -c -); then
    echo "Pruefsumme fuer $BASE stimmt nicht." >&2
    exit 1
  fi
else
  echo "Warnung: $DIR/SHA256SUMS fehlt, Restore ohne Pruefsumme." >&2
fi

export PGPASSWORD="$DB_ADMIN_PASSWORD"
psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -c "drop database if exists \"$SCRATCH\";"
psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -c "create database \"$SCRATCH\";"
pg_restore -h 127.0.0.1 -p "$DB_PORT" -U "$DB_ADMIN_USER" -d "$SCRATCH" --no-owner "$DUMP"
psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_ADMIN_USER" -d "$SCRATCH" -tAc \
  "select 'products=' || count(*) from products; select 'pages=' || count(*) from pages;"
