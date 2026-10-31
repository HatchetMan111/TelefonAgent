# Telefonagent Ein-VM-Installer – Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Einen Proxmox-Einzeiler bauen, der eine Debian-13-VM `telefonagent` mit PostgreSQL, n8n und Firecrawl installiert, reboot-sicher macht und die n8n-UI verifiziert.

**Architecture:** Host-Installer legt eine Cloud-Init-VM an und arbeitet per SSH. Im Gast installiert `vm/setup.sh` Docker, klont das Repo und Firecrawl, schreibt `.env`, startet den Compose-Stack und aktiviert `telefonagent.service`.

**Tech Stack:** Bash, Proxmox `qm`, Debian 13 Cloud-Image, Docker Compose, PostgreSQL 15, n8n, Firecrawl.

**Spec:** `docs/superpowers/specs/2026-10-31-telefonagent-vm-installer-design.md`

## Global Constraints

- Immer `set -Eeuo pipefail`.
- VM-Name `telefonagent`; nächste freie VM-ID.
- Default: 2 vCPU, 6144 MB RAM, 50 GB Disk, `onboot=1`, DHCP.
- Web-UI: `http://<VM-IP>:5678`; PostgreSQL nur `127.0.0.1`; Firecrawl intern.
- Secrets nur in `/opt/telefonagent/.env` (0600), nie im Repo.
- Leere externe Werte bleiben Platzhalter (`CHANGE_ME`, `+49...`).
- Keine Cloudflare-/ElevenLabs-/SIP-Automatisierung in diesem Plan.
- Fehlerausgabe vollständig; `--debug` bietet `bash -x`.
- Idempotent: vorhandene VM/Volumes bleiben erhalten.

## Review Focus

- Netzwerk/SSH-Erreichbarkeit nach Cloud-Init und DHCP.
- Reboot: systemd startet n8n und Firecrawl erneut.
- `.env`-Sonderzeichen und `chmod 600`.
- Firecrawl- und n8n-Netzwerk erreichen sich über `api:3002`.
- Fehlerpfad darf keine halbe VM ohne Diagnose hinterlassen.

---

### Task 1: Compose-Stack und Datenbank-Init

**Files:**
- Create: `vm/docker-compose.yml`
- Create: `vm/firecrawl.override.yml`
- Create: `vm/init/00-n8n-db.sql`
- Create: `vm/env.template`

**Interfaces:**
- Produces: `postgres`, `n8n` im externen Docker-Netz `telefonagent`; n8n-UI auf 5678.
- Consumes: `supabase/migrations/*.sql`, `docker/crawler/firecrawl.env.example`.

- [ ] Step 1: Compose mit PostgreSQL 15, Init-Mounts, n8n, Healthchecks, externem Netz `telefonagent` schreiben.
- [ ] Step 2: `00-n8n-db.sql` legt `n8n` an; Migrationen werden als Init-Skripte gemountet.
- [ ] Step 3: Firecrawl-Override setzt externes Netz, `USE_DB_AUTHENTICATION=false`, `shm_size`.
- [ ] Step 4: `docker compose config` mit Test-`.env` ausführen; erwartet valide YAML.
- [ ] Step 5: Commit `feat(vm): add all-in-one compose stack`.

### Task 2: Gast-Setup und systemd

**Files:**
- Create: `vm/setup.sh`
- Create: `vm/run.sh`
- Create: `vm/stop.sh`
- Create: `systemd/telefonagent.service`

**Interfaces:**
- Consumes: `vm/docker-compose.yml`, `vm/firecrawl.override.yml`, `/tmp/telefonagent.env`.
- Produces: `/opt/telefonagent/.env`, Docker-Netz `telefonagent`, `telefonagent.service`.

- [ ] Step 1: `setup.sh` installiert Docker/git/curl, klont Repo und Firecrawl, übernimmt `.env`, erzeugt Firecrawl-`.env`, legt Netzwerk an.
- [ ] Step 2: `run.sh` startet Firecrawl detached und n8n im Vordergrund; `stop.sh` stoppt beide.
- [ ] Step 3: `telefonagent.service` als `Type=simple`, `Restart=always`, `After=network-online.target docker.service`.
- [ ] Step 4: `bash -n` und ein lokaler Setup-Trockentest ohne Docker-Pull.
- [ ] Step 5: Commit `feat(vm): add guest setup and systemd service`.

### Task 3: Proxmox-Host-Installer

**Files:**
- Create: `install/telefonagent.sh`
- Create: `vm/cloud-init.txt`

**Interfaces:**
- Consumes: `vm/setup.sh` aus dem geklonten Repo, Debian-13-Cloud-Image.
- Produces: VM `telefonagent`, SSH-Zugang, IP, verifizierte n8n-UI.

- [ ] Step 1: Variablen/Defaults, Root-/Tool-Check, `ERR`-Trap, Logging, `--dry-run`, `--debug`.
- [ ] Step 2: Interaktive Abfrage von Shop-, Tunnel-, ElevenLabs- und SIP-Werten; Secrets generieren; `.env` per SSH übertragen.
- [ ] Step 3: VM per `qm create`/`importdisk`/Cloud-Init anlegen, Disk resize, starten, IP per Agent/ARP/`--ip` ermitteln.
- [ ] Step 4: SSH-Wartezeit, Repo klonen, `vm/setup.sh` ausführen, systemd/HTTP prüfen, optional `--reboot-test`.
- [ ] Step 5: `bash -n` und `--dry-run`; Commit `feat(install): add one-line vm installer`.

### Task 4: README, Runbook und Abnahme

**Files:**
- Modify: `README.md`
- Create: `docs/runbooks/vm-install.md`

**Interfaces:**
- Consumes: Einzeiler und Installer.
- Produces: Update-/Deinstallations-/Fehlerbehebungsanleitung.

- [ ] Step 1: Einzeiler mit `USER`-Platzhalter, Voraussetzungen, Ports, Ressourcen, externe Rest-Schritte.
- [ ] Step 2: Runbook: Reboot-Test, Logs, Update, Deinstallation, IP-Probleme, Firecrawl/N8n-Fehler.
- [ ] Step 3: `bash -n` aller Skripte, Compose-Config, SQL-Suite; Commit `docs: add vm installer runbook`.

## Self-Review

- Spec-Abdeckung: VM, schlanker Stack, interaktive Werte, Idempotenz, Reboot, Verifikation, Fehlerkette, Einzeiler, Runbook.
- Keine TBD/TODO-Platzhalter; externe Werte sind bewusst `CHANGE_ME`.
- Typen/Pfade: `.env`-Variablen entsprechen dem bestehenden Stack; `DB_HOST=postgres`, `FIRECRAWL_URL=http://api:3002`.
- Review Focus: SSH/DHCP, Reboot, Quoting, Netzwerk, Fehlerpfad.
