#!/usr/bin/env bash
install_n8n() {
  local ctid cores ram disk bridge store
  ctid="${CT_ID:-$(next_ctid)}"
  cores="${CORES:-2}"; ram="${RAM:-2048}"; disk="${DISK:-10}"
  bridge="${BRIDGE:-vmbr0}"; store="${TEMPLATE_STORE:-local}"

  if [[ ! -f "$ROOT/.env" ]]; then
    msg_error ".env fehlt – bitte aus .env.example kopieren und ausfüllen."
    exit 1
  fi

  ensure_template "$store"
  create_lxc "$ctid" "shopagent-n8n" "$cores" "$ram" "$disk" "$bridge"
  local ip; ip="$(ct_ip "$ctid")"
  msg_info "shopagent-n8n IP: $ip"
  install_docker "$ctid"

  if grep -q 'CHANGE_ME' "$ROOT/.env"; then
    msg_error ".env enthält noch CHANGE_ME – bitte ausfüllen."
    exit 1
  fi

  pct exec "$ctid" -- mkdir -p /opt/shopagent /opt/shopagent/scripts /opt/shopagent/n8n/code /etc/cloudflared
  pct push "$ctid" "$ROOT/docker/n8n/docker-compose.yml" /opt/shopagent/docker-compose.yml
  pct push "$ctid" "$ROOT/.env" /opt/shopagent/.env
  pct exec "$ctid" -- chmod 600 /opt/shopagent/.env

  pct exec "$ctid" -- bash -c '
    set -euo pipefail
    cd /opt/shopagent
    docker compose pull
    docker compose up -d
    for i in $(seq 1 60); do
      curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1 && break
      sleep 3
    done
    curl -fsS http://127.0.0.1:5678/healthz
  '

  pct push "$ctid" "$ROOT/docker/n8n/cloudflared.service" /etc/systemd/system/shopagent-cloudflared.service
  pct exec "$ctid" -- bash -c '
    systemctl daemon-reload
    systemctl enable shopagent-cloudflared.service
  '

  msg_ok "n8n läuft: http://$ip:5678 (UI nur im LAN), Tunnel-Unit aktiviert."
}
