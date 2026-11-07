#!/usr/bin/env bash
set -Eeuo pipefail

VM_NAME="${VM_NAME:-telefonagent}"
VMID="${VMID:-}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-6144}"
DISK="${DISK:-50}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
IP_ADDR="${IP_ADDR:-}"
GATEWAY="${GATEWAY:-}"
CIDR="${CIDR:-24}"
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/TelefonAgent.git}"
FIRECRAWL_REF="${FIRECRAWL_REF:-main}"
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/vz/template/iso}"
LOG_FILE="${LOG_FILE:-/var/log/telefonagent-install.log}"
SSH_KEY="${SSH_KEY:-/root/.ssh/telefonagent_ed25519}"
DRY_RUN=0
DEBUG=0
REBOOT_TEST=0
EXISTING=0
VM_IP=""
ROOT_PW=""

usage() {
  cat <<EOF
Usage: $0 [options]

Erstellt/aktualisiert eine VM "$VM_NAME" mit PostgreSQL, n8n und Firecrawl.

  --vmid ID        VM-ID (Default: nächste freie ID)
  --name NAME      VM-Name (Default: $VM_NAME)
  --cores N        vCPU (Default: $CORES)
  --memory MB      RAM in MB (Default: $MEMORY)
  --disk GB        Disk in GB (Default: $DISK)
  --bridge NAME    Proxmox-Bridge (Default: $BRIDGE)
  --storage NAME   Storage für Disk/Cloud-Init (Default: $STORAGE)
  --ip IP          VM-IP für die SSH-Erkennung (Default: DHCP)
  --gateway IP     Gateway für statische IP (optional)
  --repo URL       GitHub-Repo (Default: $REPO_URL)
  --dry-run        Nur Plan ausgeben, nichts verändern
  --debug          Bash-Trace aktivieren
  --reboot-test    Nach der Installation VM neu starten und UI prüfen
  -h, --help       Hilfe
EOF
}

log()  { printf '\e[34m[INFO]\e[0m  %s\n' "$*"; }
ok()   { printf '\e[32m[OK]\e[0m    %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m  %s\n' "$*"; }
err()  { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; }

on_error() {
  local rc=$?
  trap - ERR
  set +e
  printf '\n\e[31m[ERROR] Installation abgebrochen\e[0m\n' >&2
  printf 'Zeile:  %s\n' "${BASH_LINENO[0]:-?}" >&2
  printf 'Befehl: %s\n' "${BASH_COMMAND:-?}" >&2
  printf 'Exit:   %s\n' "$rc" >&2
  if [[ -n "${VMID:-}" ]] && command -v qm >/dev/null 2>&1; then
    printf '\n--- qm status ---\n' >&2
    qm status "$VMID" >&2 || true
    printf '\n--- qm config ---\n' >&2
    qm config "$VMID" >&2 || true
  fi
  if [[ -n "${VM_IP:-}" && -n "${SSH_KEY:-}" && -f "$SSH_KEY" && -n "${SSH_OPTS+x}" ]]; then
    printf '\n--- Gast-Journal ---\n' >&2
    ssh "${SSH_OPTS[@]}" root@"$VM_IP" "journalctl -u telefonagent --no-pager -n 80" >&2 || true
    printf '\n--- Docker-Logs ---\n' >&2
    ssh "${SSH_OPTS[@]}" root@"$VM_IP" "cd /opt/telefonagent && docker compose --env-file .env -f vm/docker-compose.yml logs --tail=80" >&2 || true
  fi
  printf '\nVollständiges Log: %s\n' "$LOG_FILE" >&2
  printf 'Für mehr Kontext: erneut mit --debug starten (bash -x).\n' >&2
  exit "$rc"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2 ;;
    --name) VM_NAME="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --ip) IP_ADDR="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --reboot-test) REBOOT_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ "${EUID}" -eq 0 ]] || { err "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi
trap on_error ERR
[[ "$DEBUG" -eq 1 ]] && set -x

if [[ "$DRY_RUN" -eq 0 ]]; then
  for t in qm pvesh wget ssh scp openssl; do
    command -v "$t" >/dev/null || { err "Fehlt: $t"; exit 1; }
  done
fi

if command -v qm >/dev/null 2>&1; then
  FOUND="$(qm list 2>/dev/null | awk -v n="$VM_NAME" 'NR>1 && $2==n {print $1; exit}')"
  if [[ -n "$FOUND" ]]; then
    if [[ -n "$VMID" && "$VMID" != "$FOUND" ]]; then
      err "VM-Name $VM_NAME belegt bereits ID $FOUND, nicht $VMID."
      exit 1
    fi
    VMID="$FOUND"
    EXISTING=1
  fi
fi

if [[ -z "$VMID" ]]; then
  if command -v pvesh >/dev/null 2>&1; then
    VMID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
  fi
  if [[ -z "$VMID" ]]; then
    if command -v qm >/dev/null 2>&1; then
      LAST="$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
    else
      LAST=99
    fi
    VMID="$(( ${LAST:-0} + 1 ))"
  fi
fi

ask() {
  local var="$1" label="$2" def="${3:-}" val=""
  [[ -n "${!var:-}" ]] && return
  if [[ "$DRY_RUN" -eq 1 || "$EXISTING" -eq 1 ]]; then
    printf -v "$var" '%s' "$def"
    return
  fi
  read -r -p "$label [$def]: " val
  printf -v "$var" '%s' "${val:-$def}"
}

ask_secret() {
  local var="$1" label="$2" def="${3:-}" val=""
  [[ -n "${!var:-}" ]] && return
  if [[ "$DRY_RUN" -eq 1 || "$EXISTING" -eq 1 ]]; then
    printf -v "$var" '%s' "$def"
    return
  fi
  read -r -s -p "$label: " val
  echo
  printf -v "$var" '%s' "${val:-$def}"
}

ask SHOP_NAME "Shop-Name" "Beispielshop"
ask SHOP_BASE_URL "Öffentliche Shop-URL" "https://shop.example"
ask TUNNEL_HOST "Tunnel-Host für Webhooks (leer = lokal)" "agent.example.de"
ask_secret ELEVENLABS_API_KEY "ElevenLabs API-Key (leer = später)" ""
ask ELEVENLABS_VOICE_ID "ElevenLabs Voice-ID (leer = später)" ""
ask ELEVENLABS_AGENT_ID "ElevenLabs Agent-ID (leer = später)" ""
ask HUMAN_TRANSFER_NUMBER "Übergabe-Rufnummer" "+49..."
ask ELEVENLABS_PHONE_NUMBER "SIP-Rufnummer E.164" "+49..."
ask SIP_PROVIDER_IP "SIP-Provider-IP" "203.0.113.10"
ask NTFY_URL "ntfy-URL für Alarme" "https://ntfy.sh/CHANGE_ME"

SHOP_BASE_URL="${SHOP_BASE_URL%/}"
SHOP_SITEMAP_URL="${SHOP_BASE_URL}/sitemap.xml"
SHOP_INFO_PATHS="/versand,/lieferzeit,/rueckgabe,/zahlung,/kontakt,/oeffnungszeiten"
DB_PASSWORD="$(openssl rand -hex 24)"
N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"
AGENT_WEBHOOK_SECRET="$(openssl rand -hex 32)"
FIRECRAWL_API_KEY="$(openssl rand -hex 24)"
FIRECRAWL_BULL_AUTH_KEY="$(openssl rand -hex 24)"
ROOT_PW="$(openssl rand -hex 16)"
[[ "$(printf '%s' "$TUNNEL_HOST" | tr -d '[:space:]')" == "agent.example.de" ]] && TUNNEL_HOST=""

if [[ "$EXISTING" -eq 1 ]]; then
  warn "VM $VM_NAME (ID $VMID) existiert bereits; .env und Volumes bleiben erhalten."
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '\nDRY RUN\n'
  printf 'VM:       %s (%s)\n' "$VM_NAME" "$VMID"
  printf 'Ressourcen: %s vCPU, %s MB RAM, %s GB Disk\n' "$CORES" "$MEMORY" "$DISK"
  printf 'Netz:     %s, IP: %s\n' "$BRIDGE" "${IP_ADDR:-DHCP}"
  printf 'Storage:  %s\n' "$STORAGE"
  printf 'Repo:     %s\n' "$REPO_URL"
  printf 'n8n:      Port 5678\n'
  printf 'Secrets:  würden generiert (nicht angezeigt)\n'
  exit 0
fi

if [[ -n "$IP_ADDR" && -n "$GATEWAY" ]]; then
  IPCONFIG="ip=${IP_ADDR}/${CIDR},gw=${GATEWAY}"
else
  IPCONFIG="ip=dhcp"
fi

if [[ ! -f "$SSH_KEY" ]]; then
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY"
fi
PUBKEY="${SSH_KEY}.pub"

IMAGE_PATH="$IMAGE_DIR/debian-13-genericcloud-amd64.qcow2"

ensure_image() {
  mkdir -p "$IMAGE_DIR"
  if [[ -f "$IMAGE_PATH" ]]; then
    return 0
  fi
  log "Debian-13-Cloud-Image herunterladen"
  # In Tempdatei laden und atomar verschieben, damit ein abgebrochener
  # Download keine korrupte Datei hinterlässt, die beim nächsten Lauf importiert wird.
  if ! wget -q --show-progress -O "$IMAGE_PATH.part" "$IMAGE_URL"; then
    rm -f "$IMAGE_PATH.part"
    err "Image-Download fehlgeschlagen – bitte den Installer erneut starten."
    exit 1
  fi
  mv "$IMAGE_PATH.part" "$IMAGE_PATH"
}

ensure_disk() {
  local cfg volume logf
  cfg="$(qm config "$VMID")"
  if grep -q '^scsi0:' <<<"$cfg"; then
    return 0
  fi
  if qm status "$VMID" | grep -q running; then
    qm stop "$VMID"
  fi

  volume="$(awk -F': ' '/^unused[0-9]+:/{print $2; exit}' <<<"$cfg")"
  if [[ -z "$volume" ]]; then
    ensure_image
    log "Disk importieren"
    logf="$(mktemp)"
    if ! qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE" --format=qcow2 >"$logf" 2>&1; then
      cat "$logf" >&2
      rm -f "$logf"
      err "qm importdisk ist fehlgeschlagen."
      exit 1
    fi
    volume="$(awk -F': ' '/^unused[0-9]+:/{print $2; exit}' <<<"$(qm config "$VMID")")"
    if [[ -z "$volume" ]]; then
      volume="$(sed -n "s/.*as '\([^']*\)'.*/\1/p" "$logf" | tail -1)"
    fi
    if [[ -z "$volume" ]]; then
      cat "$logf" >&2
      rm -f "$logf"
      err "Importiertes Volume konnte nicht ermittelt werden."
      qm config "$VMID" >&2 || true
      exit 1
    fi
    rm -f "$logf"
  fi
  volume="$(printf '%s' "$volume" | sed 's/^unused[0-9]*://')"
  log "Disk anhängen: $volume"
  qm set "$VMID" --scsi0 "$volume" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
  qm resize "$VMID" scsi0 "${DISK}G" >/dev/null 2>&1 || true
  qm set "$VMID" --agent enabled=1 --ciuser root --sshkeys "$PUBKEY" \
    --ipconfig0 "$IPCONFIG" --cipassword "$ROOT_PW"
  qm cloudinit update "$VMID"
}

if [[ "$EXISTING" -eq 0 ]]; then
  log "VM $VMID ($VM_NAME) anlegen"
  qm create "$VMID" \
    --name "$VM_NAME" --memory "$MEMORY" --cores "$CORES" --sockets 1 \
    --cpu host --ostype l26 --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=$BRIDGE" --serial0 socket --onboot 1
  ensure_disk
  log "VM starten"
  qm start "$VMID"
else
  qm set "$VMID" --onboot 1 >/dev/null
  ensure_disk
  if ! qm status "$VMID" | grep -q running; then
    qm start "$VMID"
  fi
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -i "$SSH_KEY")

guest_ip() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for iface in data:
    for addr in iface.get("ip-addresses", []):
        ip=addr.get("ip-address","")
        if addr.get("ip-address-type")=="ipv4" and not ip.startswith("127."):
            print(ip); raise SystemExit
' 2>/dev/null || true
}

arp_ip() {
  local mac
  # qm config liefert die MAC als "net0: virtio=BC:24:11:...,bridge=..." – Modell-Präfix strippen.
  mac="$(qm config "$VMID" 2>/dev/null | awk -F'[ ,]' '/^net0:/{for(i=1;i<=NF;i++){m=$i; sub(/^[^=]*=/,"",m); if(m ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/){print m; exit}}}' || true)"
  [[ -n "$mac" ]] || return 0
  ip neigh show dev "$BRIDGE" 2>/dev/null | awk -v m="$mac" 'tolower($0) ~ tolower(m) {print $1; exit}' || true
}

log "Warte auf SSH in der VM"
for _ in $(seq 1 90); do
  CANDIDATE="${IP_ADDR:-$(guest_ip)}"
  [[ -z "$CANDIDATE" ]] && CANDIDATE="$(arp_ip)"
  if [[ -n "$CANDIDATE" ]] && ssh "${SSH_OPTS[@]}" root@"$CANDIDATE" true >/dev/null 2>&1; then
    VM_IP="$CANDIDATE"
    break
  fi
  sleep 2
done
[[ -n "$VM_IP" ]] || {
  err "Keine SSH-IP gefunden (180s gewartet)."
  err "Hinweise: IP in der VM prüfen (qm terminal/$VMID oder DHCP-Leases) und dann mit --ip <IP> erneut starten."
  exit 1
}
ok "VM erreichbar: $VM_IP"

log "Basiswerkzeuge im Gast installieren"
ssh "${SSH_OPTS[@]}" root@"$VM_IP" "export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends git curl ca-certificates"

log "Repo bereitstellen"
ssh "${SSH_OPTS[@]}" root@"$VM_IP" "if [ -d /opt/telefonagent/.git ]; then git -C /opt/telefonagent pull --ff-only; else rm -rf /opt/telefonagent; git clone --depth 1 '$REPO_URL' /opt/telefonagent; fi"

WEBHOOK_URL="http://${VM_IP}:5678/"
[[ -n "$TUNNEL_HOST" ]] && WEBHOOK_URL="https://${TUNNEL_HOST}/"

TMP_ENV="$(mktemp)"
trap 'rm -f "${TMP_ENV:-}"' EXIT
{
  printf 'TZ=Europe/Berlin\n'
  printf 'SHOP_NAME=%s\n' "$SHOP_NAME"
  printf 'SHOP_BASE_URL=%s\n' "$SHOP_BASE_URL"
  printf 'SHOP_URL=%s\n' "$SHOP_BASE_URL"
  printf 'SHOP_SITEMAP_URL=%s\n' "$SHOP_SITEMAP_URL"
  printf "SHOP_PRODUCT_PATTERN='/(produkt|product|p)/'\n"
  printf 'SHOP_INFO_PATHS=%s\n' "$SHOP_INFO_PATHS"
  printf 'HUMAN_TRANSFER_NUMBER=%s\n' "$HUMAN_TRANSFER_NUMBER"
  printf 'DB_HOST=127.0.0.1\nDB_PORT=5432\nDB_USER=shopagent\n'
  printf 'DB_PASSWORD=%s\nDB_ADMIN_USER=shopagent\nDB_ADMIN_PASSWORD=%s\n' "$DB_PASSWORD" "$DB_PASSWORD"
  printf 'N8N_DB_NAME=n8n\n'
  printf 'N8N_LAN_IP=%s\n' "$VM_IP"
  printf 'N8N_IMAGE=n8nio/n8n:latest\n'
  printf 'N8N_ENCRYPTION_KEY=%s\n' "$N8N_ENCRYPTION_KEY"
  printf 'WEBHOOK_URL=%s\n' "$WEBHOOK_URL"
  printf 'TUNNEL_HOST=%s\n' "$TUNNEL_HOST"
  printf 'AGENT_WEBHOOK_SECRET=%s\n' "$AGENT_WEBHOOK_SECRET"
  printf 'FIRECRAWL_HOST=127.0.0.1\nFIRECRAWL_PORT=3002\n'
  printf 'FIRECRAWL_API_KEY=%s\nFIRECRAWL_BULL_AUTH_KEY=%s\n' "$FIRECRAWL_API_KEY" "$FIRECRAWL_BULL_AUTH_KEY"
  printf 'FIRECRAWL_REF=%s\n' "$FIRECRAWL_REF"
  printf 'ELEVENLABS_API_KEY=%s\nELEVENLABS_AGENT_ID=%s\nELEVENLABS_VOICE_ID=%s\n' "${ELEVENLABS_API_KEY:-CHANGE_ME}" "${ELEVENLABS_AGENT_ID:-CHANGE_ME}" "${ELEVENLABS_VOICE_ID:-CHANGE_ME}"
  printf 'ELEVENLABS_LLM=gemini-2.0-flash\nELEVENLABS_PHONE_NUMBER=%s\nSIP_PROVIDER_IP=%s\n' "$ELEVENLABS_PHONE_NUMBER" "$SIP_PROVIDER_IP"
  printf 'BACKUP_DIR=/var/backups/shopagent\nBACKUP_RETAIN_DAYS=14\nNTFY_URL=%s\n' "$NTFY_URL"
} >"$TMP_ENV"
chmod 600 "$TMP_ENV"

scp "${SSH_OPTS[@]}" "$TMP_ENV" root@"$VM_IP":/tmp/telefonagent.env >/dev/null
ssh "${SSH_OPTS[@]}" root@"$VM_IP" "REPO_URL='$REPO_URL' FIRECRAWL_REF='$FIRECRAWL_REF' bash /opt/telefonagent/vm/setup.sh"

log "Verifiziere Dienst und Web-UI"
ssh "${SSH_OPTS[@]}" root@"$VM_IP" "systemctl is-active --quiet telefonagent.service && curl -fsS http://127.0.0.1:5678/healthz >/dev/null"
ok "n8n antwortet"

if [[ "$REBOOT_TEST" -eq 1 ]]; then
  log "Reboot-Test"
  qm reboot "$VMID"
  for _ in $(seq 1 90); do
    if ssh "${SSH_OPTS[@]}" root@"$VM_IP" "systemctl is-active --quiet telefonagent.service && curl -fsS http://127.0.0.1:5678/healthz >/dev/null" >/dev/null 2>&1; then
      ok "Web-UI nach Reboot erreichbar"
      break
    fi
    sleep 2
  done
  ssh "${SSH_OPTS[@]}" root@"$VM_IP" "systemctl is-active --quiet telefonagent.service && curl -fsS http://127.0.0.1:5678/healthz >/dev/null" >/dev/null || { err "Reboot-Test fehlgeschlagen"; exit 1; }
fi

printf '\n'
ok "Telefonagent installiert"
printf 'VM:        %s (ID %s)\n' "$VM_NAME" "$VMID"
printf 'IP:        %s\n' "$VM_IP"
printf 'n8n-UI:    http://%s:5678\n' "$VM_IP"
if [[ "$EXISTING" -eq 0 ]]; then printf 'Root-PW:   %s\n' "$ROOT_PW"; fi
printf '\nNächste Schritte:\n'
printf '  1. n8n öffnen und Owner-Konto anlegen.\n'
printf '  2. Workflows aus n8n/workflows importieren und Postgres-Credential anlegen.\n'
printf '  3. Cloudflare/ElevenLabs/SIP nach docs/runbooks/ einrichten.\n'
printf '  4. Reboot-Test: %s --reboot-test --vmid %s\n' "$0" "$VMID"
