#!/usr/bin/env bash
install_db() {
  local ctid cores ram disk bridge store
  ctid="${CT_ID:-$(next_ctid)}"
  cores="${CORES:-2}"; ram="${RAM:-4096}"; disk="${DISK:-20}"
  bridge="${BRIDGE:-vmbr0}"; store="${TEMPLATE_STORE:-local}"

  ensure_template "$store"
  create_lxc "$ctid" "shopagent-db" "$cores" "$ram" "$disk" "$bridge"
  local ip; ip="$(ct_ip "$ctid")"
  msg_info "shopagent-db IP: $ip"

  install_docker "$ctid"

  pct exec "$ctid" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive LC_ALL=C
    apt-get install -y --no-install-recommends nodejs npm
    mkdir -p /opt/shopagent
    cd /opt/shopagent
    if [[ ! -f supabase/config.toml ]]; then
      CI=1 npx --yes supabase@2 init --force
    fi
  '

  pct push "$ctid" "$ROOT/supabase/config.patch.py" /opt/shopagent/config.patch.py
  pct exec "$ctid" -- bash -c 'cd /opt/shopagent && python3 config.patch.py supabase/config.toml'

  pct exec "$ctid" -- bash -c 'mkdir -p /opt/shopagent/supabase/migrations'
  for f in "$ROOT"/supabase/migrations/*.sql; do
    pct push "$ctid" "$f" "/opt/shopagent/supabase/migrations/$(basename "$f")"
  done

  pct exec "$ctid" -- bash -c '
    set -euo pipefail
    cd /opt/shopagent
    npx --yes supabase@2 start
    for i in $(seq 1 120); do
      npx --yes supabase@2 status >/dev/null 2>&1 && break
      sleep 5
    done
    npx --yes supabase@2 migration up
    npx --yes supabase@2 status
  '

  pct push "$ctid" "$ROOT/systemd/shopagent-supabase.service" /etc/systemd/system/shopagent-supabase.service
  pct exec "$ctid" -- bash -c '
    systemctl daemon-reload
    systemctl enable shopagent-supabase.service
  '

  msg_ok "Supabase läuft. DB: $ip:54322, Studio: http://$ip:54323"
}
