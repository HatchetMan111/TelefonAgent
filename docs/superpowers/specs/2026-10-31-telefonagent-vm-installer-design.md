# Telefonagent – Ein-VM-Installer für Proxmox

**Datum:** 2026-10-31  
**Status:** Freigegebenes Design

## Ziel

Der bestehende Telefonagent soll auf einem Proxmox-Host mit einem Einzeiler als
eine Debian-VM installiert werden. Die VM ist der kleinste sinnvolle Testaufbau:
PostgreSQL, n8n und Firecrawl laufen gemeinsam in Docker. Die bestehenden
3-LXC-Installer bleiben als separater, isolierter Produktionspfad erhalten.

Nicht Teil dieses Designs: Cloudflare-Tunnel, ElevenLabs-Agent, SIP-Trunk,
n8n-Workflow-Import und das n8n-Erstkonto. Diese Schritte brauchen externe
Zugangsdaten und bleiben dokumentierte Live-Schritte.

## Entscheidungen

- **Eine VM**, kein LXC: Docker-in-LXC mit Supabase/Firecrawl ist unnötig fragil.
- **Schlanker Stack:** PostgreSQL + n8n + Firecrawl; kein Supabase-CLI/Studio.
- **VM-Name:** `telefonagent`; VM-ID: nächste freie ID.
- **Testprofil:** 2 vCPU, 6 GB RAM, 50 GB Disk, `onboot=1`; per Flags änderbar.
- **Web-UI:** n8n auf `http://<VM-IP>:5678`; PostgreSQL nur auf `127.0.0.1`.
- **Firecrawl** läuft intern im Docker-Netz `telefonagent`; n8n erreicht es als
  `http://api:3002`.
- **Interaktive Abfrage** der Shop-/Tunnel-/ElevenLabs-/SIP-Werte auf dem
  Proxmox-Host. Leere optionale Werte bleiben Platzhalter.
- **Idempotenz:** vorhandene VM wird wiederverwendet; Compose/Config werden
  aktualisiert, Volumes bleiben erhalten.
- **Fehlerausgabe:** vollständige Befehlskette, Zeile, Exit-Code, `qm status`,
  `qm config`, Gast-Journal und Docker-Logs; `--debug` mit `bash -x`.

## Architektur

```text
Proxmox-Host
└── VM telefonagent (Debian 13, 2 vCPU, 6 GB, 50 GB, onboot)
    ├── systemd telefonagent.service
    │   └── vm/run.sh: Firecrawl-Up + n8n-Compose im Vordergrund
    ├── Docker-Netz telefonagent
    │   ├── postgres:15 (App-DB postgres, n8n-DB n8n)
    │   ├── n8n (Port 5678)
    │   └── Firecrawl (api/worker/playwright/redis)
    └── /opt/telefonagent/.env (0600)
```

### Datenbank

- `POSTGRES_USER=shopagent`, `POSTGRES_PASSWORD=<generiert>`,
  `POSTGRES_DB=postgres`.
- Init-SQL legt `n8n` an und führt die vorhandenen Migrationen aus.
- Die App nutzt weiterhin `DB_NAME=postgres`, `DB_USER=shopagent`.
- n8n nutzt `N8N_DB_NAME=n8n` und denselben Benutzer.

### Ports

- `5678/tcp` – n8n-UI und Webhooks (LAN).
- `5432/tcp` – PostgreSQL nur `127.0.0.1` (Diagnose).
- Firecrawl `3002` – nicht öffentlich; nur im Docker-Netz.

## Installationsablauf

1. Root-/Tool-Check: `qm`, `pvesh`, `wget`, `ssh`, `scp`, `openssl`.
2. Nächste VM-ID ermitteln; vorhandene VM `telefonagent` wiederverwenden.
3. Interaktive Werte abfragen und Ressourcen bestätigen.
4. Secrets generieren: DB-Passwort, n8n-Encryption-Key, Webhook-Secret,
   Root-Passwort.
5. Debian-13-Genericcloud-Image herunterladen und importieren.
6. VM anlegen: `scsi0`, Cloud-Init, DHCP, SSH-Key, `agent=1`, `onboot=1`.
7. Starten; IP über Gast-Agent oder ARP ermitteln; alternativ `--ip`.
8. Per SSH: Git/Docker installieren, Repo klonen, `.env` ablegen.
9. `vm/setup.sh`: Docker, Firecrawl-Repo, Netzwerk, systemd, Stack starten.
10. Verifizieren: `systemctl is-active`, `docker compose ps`,
    `curl http://127.0.0.1:5678/healthz`.
11. Optional `--reboot-test`: VM rebooten und UI erneut prüfen.
12. URL, VM-ID, Root-Passwort und n8n-Erstkonto-Hinweis ausgeben.

## Dateien

- `install/telefonagent.sh` – Host-Installer/Einzeiler.
- `vm/docker-compose.yml` – PostgreSQL + n8n.
- `vm/init/00-n8n-db.sql` – n8n-Datenbank.
- `vm/firecrawl.override.yml` – Firecrawl-Netzwerk/Ports.
- `vm/setup.sh` – Installation im Gast.
- `vm/run.sh` / `vm/stop.sh` – Stack-Lebenszyklus.
- `systemd/telefonagent.service` – reboot-sicherer Dienst.
- `README.md` – Einzeiler, Update, Deinstallation, Grenzen.
- `docs/runbooks/vm-install.md` – Betrieb und Fehlerbehebung.

## Fehlerbehandlung

- `set -Eeuo pipefail` in allen Skripten.
- `ERR`-Trap im Host-Installer gibt Zeile, Befehl, Exit-Code und den
  vollständigen Kontext aus; keine gekürzte „letzte Zeile“.
- Log unter `/var/log/telefonagent-install.log`; `--debug` aktiviert `bash -x`.
- Bei Fehlern nach der VM-Erstellung: `qm status`, `qm config`, letzte
  `journalctl`-/`docker compose logs`-Ausgaben.

## Verifikation und Tests

- Host-Installer: `bash -n`, `--dry-run` mit geprüften Defaults.
- Gast-Setup: `bash -n`.
- Compose: `docker compose config` mit Test-`.env`.
- Datenbank: vorhandene SQL-Suite `tests/sql/run.sh`.
- Lokaler Docker-Smoke-Test: PostgreSQL-Migrationen + n8n-Health, falls Docker
  verfügbar; kein Ersatz für den echten VM-/Reboot-Test.
- Echter Test auf Proxmox: Installation, Reboot, UI erneut erreichbar.

## Grenzen

- Der Einzeiler funktioniert erst nach öffentlichem Push; `USER` ersetzen.
- n8n-Workflows, Postgres-Credential und Owner-Konto bleiben manuell.
- Cloudflare, ElevenLabs und SIP bleiben extern.
- 6 GB RAM ist das Testminimum; 4 GB kann OOM verursachen.
- Der echte Proxmox-Test kann in dieser Umgebung nicht ausgeführt werden.
