#!/usr/bin/env bash
# Wird von install/shopagent.sh gesourct.
msg_info()  { echo -e "\e[34m[INFO]\e[0m  $*"; }
msg_ok()    { echo -e "\e[32m[OK]\e[0m    $*"; }
msg_warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || { msg_error "Auf dem Proxmox-Host als root ausführen."; exit 1; }
}

require_tools() {
  for t in pct pvesh wget curl; do
    command -v "$t" >/dev/null || { msg_error "fehlt: $t"; exit 1; }
  done
}

next_ctid() {
  pvesh get /cluster/nextid
}

ensure_template() {
  local store="$1" tmpl="debian-13-standard"
  if ! pveam list "$store" | grep -q "$tmpl"; then
    pveam update
    local latest
    latest="$(pveam available --section system | awk '/debian-13-standard/{print $2}' | tail -n1)"
    [[ -n "$latest" ]] || { msg_error "Kein debian-13-standard Template verfügbar."; exit 1; }
    pveam download "$store" "$latest"
  fi
}

create_lxc() {
  local ctid="$1" hostname="$2" cores="$3" ram="$4" disk="$5" bridge="$6"
  if pct status "$ctid" >/dev/null 2>&1; then
    msg_info "CT $ctid existiert bereits – überspringe Erstellung."
    return 0
  fi
  local store tmpl
  store="${TEMPLATE_STORE:-local}"
  tmpl="$(pveam list "$store" | awk '/debian-13-standard/{print $1}' | tail -n1)"
  pct create "$ctid" "$tmpl" \
    --hostname "$hostname" --cores "$cores" --memory "$ram" --swap 1024 \
    --rootfs "${ROOTFS_STORAGE:-local-lvm}:${disk}" --net0 "name=eth0,bridge=${bridge},ip=dhcp" \
    --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --start 1
  msg_ok "CT $ctid ($hostname) erstellt."
}

ct_ip() {
  local ctid="$1" ip=""
  for _ in $(seq 1 60); do
    ip="$(pct exec "$ctid" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    sleep 2
  done
  msg_error "Keine IP für CT $ctid"; return 1
}

install_docker() {
  pct exec "$1" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive LC_ALL=C
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl gnupg jq postgresql-client python3
    if ! command -v docker >/dev/null; then
      curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
    for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
    docker info >/dev/null
  '
}
