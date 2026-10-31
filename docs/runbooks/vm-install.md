# Telefonagent-VM – Installations- und Betriebsrunbook

## Voraussetzungen

- Proxmox VE 8/9, root auf dem Host
- Bridge `vmbr0`, Storage `local-lvm` (oder per `--storage`/`--bridge`)
- Internet für Debian-Cloud-Image, Docker Hub, GitHub und Firecrawl
- Öffentliches Repo; `USER` im Einzeiler ersetzen

## Installation

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/telefonagent/main/install/telefonagent.sh)"
```

Der Installer:

1. ermittelt die nächste freie VM-ID,
2. legt die VM `telefonagent` an (2 vCPU, 6 GB, 50 GB, `onboot=1`),
3. installiert Debian 13 per Cloud-Init und SSH-Key,
4. klont Repo und Firecrawl,
5. startet PostgreSQL, n8n und Firecrawl,
6. aktiviert `telefonagent.service`,
7. prüft `systemctl` und `http://127.0.0.1:5678/healthz`.

Am Ende werden VM-ID, IP, n8n-URL und Root-Passwort ausgegeben.

## Ports

| Dienst | Port | Erreichbarkeit |
|---|---|---|
| n8n-UI/Webhooks | 5678/tcp | LAN |
| PostgreSQL | 5432/tcp | nur `127.0.0.1` |
| Firecrawl | 3002/tcp | nur Docker-Netz |

Firecrawl wird nicht auf dem Host veröffentlicht; n8n erreicht es als
`http://api:3002`.

## Nach der Installation

1. `http://<VM-IP>:5678` öffnen und n8n-Owner anlegen.
2. Workflows `01-crawl.json`, `02-agent-api.json`, `03-error-alert.json`
   importieren.
3. Postgres-Credential `ShopAgent DB` anlegen:
   - Host `postgres`
   - Port `5432`
   - DB `postgres`
   - User `shopagent`
   - Passwort aus `/opt/telefonagent/.env`
4. Cloudflare-Tunnel, ElevenLabs-Agent und SIP-Trunk nach den jeweiligen
   Runbooks einrichten.
5. Go-live-Checkliste abarbeiten.

## Reboot-Test

```bash
bash install/telefonagent.sh --reboot-test --vmid <ID>
```

Erwartet nach dem Reboot:

```bash
systemctl is-active telefonagent
curl -fsS http://127.0.0.1:5678/healthz
```

## Logs und Diagnose

```bash
journalctl -u telefonagent -n 200 --no-pager
cd /opt/telefonagent
docker compose --env-file .env -f vm/docker-compose.yml ps
docker compose --env-file .env -f vm/docker-compose.yml logs --tail=200
```

Firecrawl:

```bash
cd /opt/telefonagent/firecrawl
docker compose -f docker-compose.yaml -f ../vm/firecrawl.override.yml ps
docker compose -f docker-compose.yaml -f ../vm/firecrawl.override.yml logs --tail=200
```

Host-Installer-Log:

```bash
tail -200 /var/log/telefonagent-install.log
```

Bei einem Fehler zeigt der Installer Zeile, Befehl, Exit-Code, `qm status`,
`qm config`, Gast-Journal und Docker-Logs. Für `bash -x`:

```bash
bash install/telefonagent.sh --debug
```

## Keine IP gefunden

Der Installer versucht zuerst den QEMU-Guest-Agent, dann ARP. Falls beides
scheitert:

```bash
qm list
qm config <ID>
# IP im Router/DHCP nachsehen, dann:
bash install/telefonagent.sh --vmid <ID> --ip <IP>
```

Für eine statische IP:

```bash
bash install/telefonagent.sh --ip 192.168.1.50 --gateway 192.168.1.1
```

## Update

Einzeiler erneut ausführen. Die VM wird wiederverwendet; Repo und Compose
werden aktualisiert, Volumes und `/opt/telefonagent/.env` bleiben erhalten.

Nach einem Update:

```bash
systemctl restart telefonagent
curl -fsS http://127.0.0.1:5678/healthz
```

## Deinstallation

```bash
VMID=$(qm list | awk '$2=="telefonagent"{print $1}')
qm stop "$VMID"
qm destroy "$VMID" --purge
rm -f /var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2
```

## Bekannte Grenzen

- n8n-Workflows, Credential und Owner sind manuell.
- Cloudflare, ElevenLabs und SIP sind extern.
- 6 GB RAM ist das Testminimum.
- Firecrawl-Images werden beim ersten Start gebaut/gezogen; das kann dauern.
- Die VM nutzt kein Supabase-Studio; PostgreSQL ist direkt erreichbar.
