#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/install/lib/common.sh"

# Werte aus .env für die Rollen-Installer (DB_*, N8N_*, FIRECRAWL_*, ...).
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

ROLE="all"; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --ctid) CT_ID="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) RAM="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) echo "Usage: $0 --role db|n8n|crawler|all [--dry-run]"; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; exit 1 ;;
  esac
done

require_root

if [[ "$DRY_RUN" == "1" ]]; then
  msg_info "DRY RUN: Rolle=$ROLE, CT_ID=${CT_ID:-<nächste freie>}, CORES=${CORES:-2}, RAM=${RAM:-4096}, DISK=${DISK:-20}"
  exit 0
fi

require_tools

case "$ROLE" in
  db) source "$ROOT/install/lib/db.sh"; install_db ;;
  n8n) source "$ROOT/install/lib/n8n.sh"; install_n8n ;;
  crawler) source "$ROOT/install/lib/crawler.sh"; install_crawler ;;
  all)
    source "$ROOT/install/lib/db.sh"; install_db
    source "$ROOT/install/lib/n8n.sh"; install_n8n
    source "$ROOT/install/lib/crawler.sh"; install_crawler
    ;;
  *) msg_error "Unbekannte Rolle: $ROLE"; exit 1 ;;
esac

msg_ok "Fertig."
