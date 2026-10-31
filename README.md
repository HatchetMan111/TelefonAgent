# Telefonagent – lokaler KI-Telefonagent

Eingehender Telefonagent für den eigenen Shop. n8n + Firecrawl crawlen die
öffentliche Shop-Website nächtlich nach PostgreSQL; ElevenLabs beantwortet
Anrufe über fünf Webhook-Tools. Nur ElevenLabs und der SIP-Trunk sind extern.

## Schnellstart als eine VM (Proxmox)

Voraussetzungen auf dem Proxmox-Host:

- Proxmox VE 8/9, root-Zugang, `vmbr0`, Storage `local-lvm` (oder `--storage`)
- Internetzugang für Debian-Cloud-Image, Docker und GitHub
- Das Repo ist öffentlich

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TelefonAgent/main/install/telefonagent.sh)"
```

Der Installer fragt Shop-Name, Shop-URL, Tunnel-Host und optional ElevenLabs/SIP
ab. Leere optionale Werte bleiben Platzhalter. Danach:

- VM `telefonagent`, nächste freie ID, `onboot=1`
- Standard: 2 vCPU, 6 GB RAM, 50 GB Disk
- n8n-UI: `http://<VM-IP>:5678`
- PostgreSQL nur auf `127.0.0.1`
- Firecrawl nur im internen Docker-Netz

Optionen:

```bash
# Nur planen
bash install/telefonagent.sh --dry-run

# Ressourcen/Netz überschreiben
bash install/telefonagent.sh --vmid 120 --memory 8192 --cores 4 --disk 80 --bridge vmbr0 --storage local-lvm

# Nach der Installation Reboot + Web-UI prüfen
bash install/telefonagent.sh --reboot-test --vmid 120

# Ausführliches Trace-Log bei Fehlern
bash install/telefonagent.sh --debug
```

Nach der Installation bleibt die n8n-Erstkonfiguration manuell:

1. `http://<VM-IP>:5678` öffnen, Owner-Konto anlegen.
2. Workflows aus `n8n/workflows/` importieren.
3. Postgres-Credential `ShopAgent DB` anlegen:
   Host `postgres`, Port `5432`, DB `postgres`, User `shopagent`,
   Passwort aus `/opt/telefonagent/.env`.
4. Cloudflare/ElevenLabs/SIP nach `docs/runbooks/` einrichten.

## 3-LXC-Produktionspfad

Der bestehende, isolierte Pfad bleibt erhalten:

```bash
sudo bash install/shopagent.sh --role db
# Danach Rolle shopagent + DB n8n anlegen (Plan Task 5, Step 8)
sudo bash install/shopagent.sh --role n8n
sudo bash install/shopagent.sh --role crawler
```

Dienste: `shopagent-db`, `shopagent-n8n`, `shopagent-crawler`.

## Betrieb

- VM-Runbook: `docs/runbooks/vm-install.md`
- 3-LXC-Runbooks: `docs/runbooks/crawl.md`, `tunnel.md`, `sip.md`, `eval.md`,
  `backup.md`, `operations.md`, `go-live.md`
- Healthcheck: `scripts/healthcheck.sh`
- Agent-Eval: `node scripts/eval-agent.mjs`
- Backup/Restore: `scripts/backup.sh`, `scripts/restore.sh`

## Update

Auf dem Proxmox-Host denselben Einzeiler erneut ausführen. Die VM wird
wiederverwendet; Repo/Compose werden aktualisiert, Volumes und `.env` bleiben
erhalten.

## Deinstallation

```bash
VMID=$(qm list | awk '$2=="telefonagent"{print $1}')
qm stop "$VMID" && qm destroy "$VMID" --purge
rm -rf /var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2
```

Das löscht VM, Disks und Docker-Volumes unwiderruflich.

## Grenzen

- Kein automatischer n8n-Workflow-Import und kein n8n-Owner.
- Cloudflare, ElevenLabs und SIP bleiben manuelle externe Schritte.
- 6 GB RAM ist das Testminimum; 4 GB kann OOM verursachen.
- Die VM-Variante nutzt bewusst kein Supabase-Studio; die SQL-Migrationen laufen
  direkt gegen PostgreSQL.

- Spec (3-LXC): `docs/superpowers/specs/2026-10-28-telefonagent-design.md`
- Plan (3-LXC): `docs/superpowers/plans/2026-10-28-telefonagent-implementation.md`
- Spec (VM): `docs/superpowers/specs/2026-10-31-telefonagent-vm-installer-design.md`
- Plan (VM): `docs/superpowers/plans/2026-10-31-telefonagent-vm-installer.md`
