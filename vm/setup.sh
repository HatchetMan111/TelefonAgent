#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/opt/telefonagent}"
ENV_SRC="${ENV_SRC:-/tmp/telefonagent.env}"
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/TelefonAgent.git}"
FIRECRAWL_REF="${FIRECRAWL_REF:-main}"

log() { printf '[setup] %s\n' "$*"; }
fail() { printf '[setup] FEHLER: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "setup.sh muss als root laufen"
[[ -f "$ENV_SRC" ]] || fail "Env-Datei fehlt: $ENV_SRC"

log "Pakete installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git

if ! command -v docker >/dev/null 2>&1; then
  log "Docker installieren"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
for _ in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info >/dev/null || fail "Docker ist nicht bereit"

if [[ ! -d "$ROOT/.git" ]]; then
  log "Repo klonen: $REPO_URL"
  rm -rf "$ROOT"
  git clone --depth 1 "$REPO_URL" "$ROOT"
else
  log "Repo aktualisieren"
  git -C "$ROOT" fetch --depth 1 origin
  git -C "$ROOT" merge --ff-only FETCH_HEAD
fi

if [[ -f "$ROOT/.env" ]]; then
  chmod 600 "$ROOT/.env"
  log "Bestehende .env beibehalten"
else
  install -m 600 "$ENV_SRC" "$ROOT/.env"
  log ".env installiert"
fi

chmod -R a+rX "$ROOT/supabase" "$ROOT/vm/init" "$ROOT/docker/crawler"

if [[ ! -d "$ROOT/firecrawl/.git" ]]; then
  log "Firecrawl klonen ($FIRECRAWL_REF)"
  git clone --depth 1 --branch "$FIRECRAWL_REF" https://github.com/firecrawl/firecrawl.git "$ROOT/firecrawl"
else
  log "Firecrawl aktualisieren"
  git -C "$ROOT/firecrawl" fetch --depth 1 origin "$FIRECRAWL_REF"
  git -C "$ROOT/firecrawl" checkout -q FETCH_HEAD
fi

if [[ ! -f "$ROOT/firecrawl/.env" ]]; then
  cp "$ROOT/docker/crawler/firecrawl.env.example" "$ROOT/firecrawl/.env"
fi
BULL_KEY="$(sed -n 's/^FIRECRAWL_BULL_AUTH_KEY=//p' "$ROOT/.env" | head -1 | sed -e "s/^'//" -e "s/'$//")"
[[ -n "$BULL_KEY" ]] || fail "FIRECRAWL_BULL_AUTH_KEY fehlt in .env"
sed -i "s|^BULL_AUTH_KEY=.*|BULL_AUTH_KEY=$BULL_KEY|" "$ROOT/firecrawl/.env"
chmod 600 "$ROOT/firecrawl/.env"

docker network inspect telefonagent >/dev/null 2>&1 || docker network create telefonagent
install -m 644 "$ROOT/systemd/telefonagent.service" /etc/systemd/system/telefonagent.service
systemctl daemon-reload
systemctl enable telefonagent.service
systemctl restart telefonagent.service

for _ in $(seq 1 200); do
  if systemctl is-active --quiet telefonagent.service && curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    log "Stack läuft"
    docker compose --env-file "$ROOT/.env" -f "$ROOT/vm/docker-compose.yml" ps
    exit 0
  fi
  sleep 3
done

systemctl --no-pager --full status telefonagent.service || true
docker compose --env-file "$ROOT/.env" -f "$ROOT/vm/docker-compose.yml" logs --tail=100 || true
fail "Web-UI antwortet nach 600s nicht"
