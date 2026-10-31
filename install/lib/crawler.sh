#!/usr/bin/env bash
install_crawler() {
  local ctid cores ram disk bridge store
  ctid="${CT_ID:-$(next_ctid)}"
  cores="${CORES:-2}"; ram="${RAM:-4096}"; disk="${DISK:-20}"
  bridge="${BRIDGE:-vmbr0}"; store="${TEMPLATE_STORE:-local}"

  if [[ ! -f "$ROOT/.env" ]]; then
    msg_error ".env fehlt – bitte aus .env.example kopieren und ausfüllen."
    exit 1
  fi

  if grep -q 'CHANGE_ME' "$ROOT/.env"; then
    msg_error ".env enthält noch CHANGE_ME – bitte ausfüllen."
    exit 1
  fi

  if [[ -z "${FIRECRAWL_BULL_AUTH_KEY:-}" || "${FIRECRAWL_BULL_AUTH_KEY}" == "CHANGE_ME" ]]; then
    msg_error "FIRECRAWL_BULL_AUTH_KEY fehlt in .env oder ist noch CHANGE_ME – bitte setzen."
    exit 1
  fi

  ensure_template "$store"
  create_lxc "$ctid" "shopagent-crawler" "$cores" "$ram" "$disk" "$bridge"
  local ip; ip="$(ct_ip "$ctid")"
  msg_info "shopagent-crawler IP: $ip"
  install_docker "$ctid"

  pct exec "$ctid" -- env FIRECRAWL_REF="${FIRECRAWL_REF:-main}" bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive LC_ALL=C
    apt-get update
    apt-get install -y --no-install-recommends git
    if [[ ! -d /opt/shopagent-crawler/firecrawl/.git ]]; then
      git clone --depth 1 --branch "$FIRECRAWL_REF" \
        https://github.com/firecrawl/firecrawl.git /opt/shopagent-crawler/firecrawl
    fi
  '

  pct push "$ctid" "$ROOT/docker/crawler/docker-compose.override.yml" /opt/shopagent-crawler/docker-compose.override.yml
  pct push "$ctid" "$ROOT/docker/crawler/firecrawl.env.example" /opt/shopagent-crawler/firecrawl.env
  pct exec "$ctid" -- chmod 600 /opt/shopagent-crawler/firecrawl.env
  pct exec "$ctid" -- env BULL_AUTH_KEY="${FIRECRAWL_BULL_AUTH_KEY}" bash -c '
    set -euo pipefail
    cd /opt/shopagent-crawler
    cp firecrawl/.env.example firecrawl/.env 2>/dev/null || true
    cp firecrawl.env firecrawl/.env
    sed -i "s|^BULL_AUTH_KEY=.*|BULL_AUTH_KEY=$BULL_AUTH_KEY|" firecrawl/.env
    chmod 600 firecrawl/.env
    docker compose -f firecrawl/docker-compose.yaml -f docker-compose.override.yml pull
    docker compose -f firecrawl/docker-compose.yaml -f docker-compose.override.yml up -d
    for i in $(seq 1 60); do
      curl -fsS http://127.0.0.1:3002/test >/dev/null 2>&1 && break
      sleep 3
    done
    curl -fsS http://127.0.0.1:3002/test
  '

  for unit in shopagent-crawler.service shopagent-crawler.timer \
              shopagent-crawler-stop.service shopagent-crawler-stop.timer; do
    pct push "$ctid" "$ROOT/systemd/$unit" "/etc/systemd/system/$unit"
  done
  pct exec "$ctid" -- bash -c '
    systemctl daemon-reload
    systemctl enable --now shopagent-crawler.timer shopagent-crawler-stop.timer
  '

  msg_ok "Firecrawl läuft: http://$ip:3002/test"
}
