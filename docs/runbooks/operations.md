# Runbook: Betrieb

## Zweck

Dieses Runbook beschreibt den laufenden Betrieb des ShopAgent: Healthcheck und
Alarm, manuellen Re-Crawl, Secret-Rotation, erneutes Anwenden der
Agent-Konfiguration, DB-Restore, Tunnel-Neustart, Firecrawl-Update und
Kostenprüfung. Die Detail-Runbooks bleiben maßgeblich:

- `docs/runbooks/crawl.md` – Crawl-Workflow
- `docs/runbooks/tunnel.md` – Cloudflare Tunnel und WAF
- `docs/runbooks/backup.md` – Backup und Restore-Test
- `docs/runbooks/eval.md` – Agent-Eval
- `docs/runbooks/sip.md` – SIP-Trunk

## Voraussetzungen

- Repo-Checkout auf dem Admin-Rechner mit gefüllter `.env` (Modus `600`).
- `curl` und `postgresql-client`:
  `apt-get install -y curl postgresql-client`.
- `pct` auf dem Proxmox-Host; die LXC `shopagent-db`, `shopagent-n8n` und
  `shopagent-crawler` laufen.
- Ein ntfy-Topic als `NTFY_URL` in `.env`; das Topic ist ein Geheimnis und
  gehört nicht ins Repo.

## Healthcheck und Alarm

`scripts/healthcheck.sh` prüft in dieser Reihenfolge:

1. Postgres erreichbar (`pg_isready`).
2. n8n erreichbar (`http://$N8N_LAN_IP:5678/healthz`).
3. Firecrawl erreichbar (`http://$FIRECRAWL_HOST:$FIRECRAWL_PORT/health/liveness`) –
   **nur im Crawl-Fenster 02:50 bis 04:00**. Außerhalb dieses Fensters wird
   der Check übersprungen, weil der Crawler-Stack planmäßig gestoppt ist.
4. Produktdaten nicht älter als 36 Stunden (`max(last_seen_at)`).
5. Letzter Crawl-Lauf in `crawl_runs`: Status ungleich `success` alarmiert mit
   Fehlerzahl. Gibt es noch keinen Lauf, wird nicht alarmiert.
6. Aktive Produktzahl nicht unter 80 % des letzten bekannten Werts
   (Zustand in `${XDG_STATE_HOME:-$HOME/.local/state}/shopagent/product-count`,
   überschreibbar mit `STATE_DIR`).
7. Auth-Pfad: `POST <Ziel>/webhook/shopagent/search` ohne Secret muss `401`
   liefern. Ziel ist `https://$TUNNEL_HOST`; wenn `TUNNEL_HOST` leer ist
   (lokal ohne Tunnel), wird `http://$N8N_LAN_IP:5678` geprüft.

Jeder Fehler setzt `FAIL=1`, wird als `FAIL: ...` auf stderr gemeldet und am
Ende per `POST` an `NTFY_URL` alarmiert. Exit-Code `0` nur bei `HEALTH OK`,
sonst `1`. Fehlgeschlagene Produktdaten- und Crawl-Abfragen sind nicht fatal:
Das Skript notiert den Fehler und prüft Produktzahl, Tunnel und Alarm weiter.

Aufruf:

```bash
./scripts/healthcheck.sh; echo "exit=$?"
```

Das Skript braucht `.env` im Repo-Wurzelverzeichnis. Es kann regelmäßig auf
dem Admin-Rechner laufen, z. B. alle 15 Minuten per Cron:

```cron
*/15 * * * * cd /pfad/zu/shopagent && ./scripts/healthcheck.sh >>/var/log/shopagent-health.log 2>&1
```

Außerhalb des Crawl-Fensters löst der gestoppte Firecrawl-Stack keinen
Dauer-Alarm aus, weil der Firecrawl-Check nur zwischen 02:50 und 04:00 aktiv
ist. Ein `FAIL`-Eintrag ist ein Alarm, kein stiller Logeintrag.

### n8n-Fehlerworkflow importieren und verknüpfen

`n8n/workflows/03-error-alert.json` ist der Workflow **ShopAgent Error
Alert**: `Error Trigger` → `HTTP Request` an `{{$env.NTFY_URL}}` mit dem Body
`ShopAgent Fehler: <Fehlermeldung>`. Die Datei enthält bewusst keine
Workflow- oder Credential-IDs; Import und Aktivierung sind Live-Checkpoints.

1. n8n-UI im LAN öffnen (`http://<N8N_LAN_IP>:5678`).
2. **Workflows → Import from File** → `n8n/workflows/03-error-alert.json`.
3. Workflow aktivieren. `NTFY_URL` muss im n8n-Container als Umgebungsvariable
   gesetzt sein (siehe `docker/n8n/docker-compose.yml`).
4. Die Workflows **ShopAgent Crawl** und **ShopAgent API** öffnen und in den
   Workflow-Settings unter **Error Workflow** jeweils **ShopAgent Error
   Alert** auswählen. Die Importdateien von Task 8/9 setzen absichtlich kein
   `errorWorkflow`, weil die Ziel-ID beim Import noch nicht existiert. Ohne
   diesen Schritt greift der Alarm nicht.
5. Test: einen der beiden Workflows absichtlich fehlschlagen lassen (z. B.
   Firecrawl stoppen und den Crawl manuell starten) und den Eingang im
   ntfy-Topic prüfen.

## Manueller Re-Crawl

Außerhalb des nächtlichen Fensters (02:50–04:00) zuerst die Firecrawl-Stack
starten:

```bash
CRAWLER_CT="$(pct list | awk '/shopagent-crawler/{print $1}')"
pct exec "$CRAWLER_CT" -- systemctl start shopagent-crawler.service
pct exec "$CRAWLER_CT" -- curl -fsS http://127.0.0.1:3002/health/liveness >/dev/null && echo "firecrawl ok"
```

Dann im n8n-UI **ShopAgent Crawl** öffnen → **Execute Workflow**. Der Workflow
lässt sich auch im inaktiven Zustand manuell ausführen; für den nächtlichen
Zeitplan muss er aktiv sein. Er schreibt einen neuen Lauf in `crawl_runs`.

Ergebnis prüfen:

```bash
set -a; source .env; set +a
DB_CT="$(pct list | awk '/shopagent-db/{print $1}')"
pct exec "$DB_CT" -- bash -c "PGPASSWORD='$DB_ADMIN_PASSWORD' psql -h 127.0.0.1 -p 54322 -U '$DB_ADMIN_USER' -d postgres -c \"select status, urls_fetched, products_upserted, products_deactivated from crawl_runs order by started_at desc limit 1;\""
```

Nach dem Lauf den Stack wieder stoppen, wenn er nicht bis 04:00 laufen soll:

```bash
pct exec "$CRAWLER_CT" -- systemctl start shopagent-crawler-stop.service
```

Der nächste reguläre Lauf startet Firecrawl um 02:50 und stoppt es um 04:00
(`shopagent-crawler.timer` / `shopagent-crawler-stop.timer`). Läufe, die in
dieses Fenster fallen, nicht parallel manuell starten.

## Secret-Rotation

`AGENT_WEBHOOK_SECRET` schützt den Agent-Webhook und wird quartalsweise
rotiert. Er steht in `.env` auf dem Admin-Rechner, im n8n-LXC
(`/opt/shopagent/.env`) und wird von `elevenlabs/apply-agent.mjs` in die
HTTP-Header der ElevenLabs-Tools geschrieben.

1. Neues Secret erzeugen:

   ```bash
   NEW_SECRET="$(openssl rand -hex 32)"
   echo "$NEW_SECRET"
   ```

2. In der lokalen `.env` `AGENT_WEBHOOK_SECRET` ersetzen.
3. Im n8n-LXC die `.env` aktualisieren und n8n neu starten:

   ```bash
   N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
   pct exec "$N8N_CT" -- sed -i "s|^AGENT_WEBHOOK_SECRET=.*|AGENT_WEBHOOK_SECRET=$NEW_SECRET|" /opt/shopagent/.env
   pct exec "$N8N_CT" -- bash -c 'cd /opt/shopagent && docker compose up -d'
   ```

4. Agent-Tools mit dem neuen Secret neu anwenden (siehe unten):
   `node elevenlabs/apply-agent.mjs`.
5. Prüfen: `./scripts/healthcheck.sh` muss weiter `HEALTH OK` liefern (der
   Tunnel-Check erwartet ohne Secret `401`), und ein Eval-Lauf
   (`node scripts/eval-agent.mjs`) muss bestehen.

`N8N_ENCRYPTION_KEY` nicht routinemäßig rotieren: Ein Wechsel macht die
gespeicherten Credentials in der n8n-DB unlesbar. Nur bei Verdacht auf
Kompromittierung mit vorherigem n8n-Dump wechseln.

`FIRECRAWL_API_KEY` und `FIRECRAWL_BULL_AUTH_KEY` werden im Crawler-LXC in
`/opt/shopagent-crawler/firecrawl/.env` gepflegt; nach Änderung den
Firecrawl-Stack neu starten (siehe Firecrawl-Update).

## Agent-Config erneut anwenden

Nach Änderungen an `elevenlabs/prompt.md`, `elevenlabs/agent.json` oder den
Tool-Dateien unter `elevenlabs/tools/`:

```bash
node elevenlabs/apply-agent.mjs --dry-run   # Payload ansehen, keine API-Aufrufe
node elevenlabs/apply-agent.mjs             # Tools und Agent aktualisieren
```

Voraussetzungen: `.env` enthält `ELEVENLABS_API_KEY`, `ELEVENLABS_AGENT_ID`,
`ELEVENLABS_VOICE_ID`, `HUMAN_TRANSFER_NUMBER`, `TUNNEL_HOST` und
`AGENT_WEBHOOK_SECRET`; Platzhalter (`CHANGE_ME`, `+49...`) brechen den Lauf
ab. Das Skript legt fehlende Tools an, aktualisiert vorhandene über den Namen
und setzt die Tool-IDs am Agenten neu.

Danach `node scripts/eval-agent.mjs` ausführen; Exit-Code `0` nur, wenn alle
Fälle aus `tests/eval-cases.json` bestehen. Bei Fehlschlägen die `rationale`
im Report lesen, Prompt/Tools korrigieren und erneut anwenden.

## DB-Restore

Backup-Erzeugung und Restore-Test stehen in `docs/runbooks/backup.md`. Ein
Restore wird **zuerst immer** in eine Scratch-DB geprüft:

```bash
set -a; source .env; set +a
DB_CT="$(pct list | awk '/shopagent-db/{print $1}')"
BACKUP="/var/backups/shopagent/JJJJ-MM-TT-HHMM"
pct push "$DB_CT" scripts/restore.sh /opt/shopagent/scripts/restore.sh
pct exec "$DB_CT" -- chmod +x /opt/shopagent/scripts/restore.sh
pct exec "$DB_CT" -- /opt/shopagent/scripts/restore.sh "$BACKUP/postgres.dump"
```

Erwartet: `products=<n>` und `pages=<n>` passen zur Produktion. Der Dump liegt
im DB-LXC unter `/var/backups/shopagent/...`; Pfad entsprechend anpassen.

Produktiv-Restore nur im Notfall und nur nach erfolgreichem Scratch-Test:

1. n8n-Crawl und Firecrawl stoppen, damit keine Schreiber laufen:

   ```bash
   CRAWLER_CT="$(pct list | awk '/shopagent-crawler/{print $1}')"
   pct exec "$CRAWLER_CT" -- systemctl start shopagent-crawler-stop.service
   N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
   pct exec "$N8N_CT" -- bash -c 'cd /opt/shopagent && docker compose stop n8n'
   ```

2. Im DB-LXC `postgres` mit dem geprüften Dump überschreiben:

   ```bash
   set -a; source .env; set +a
   pct exec "$DB_CT" -- bash -c "PGPASSWORD='$DB_ADMIN_PASSWORD' pg_restore -h 127.0.0.1 -p 54322 -U '$DB_ADMIN_USER' -d postgres --clean --if-exists '$BACKUP/postgres.dump'"
   ```

3. n8n und Crawler wieder starten:

   ```bash
   pct exec "$N8N_CT" -- bash -c 'cd /opt/shopagent && docker compose start n8n'
   pct exec "$CRAWLER_CT" -- systemctl start shopagent-crawler.service
   ```

4. `./scripts/healthcheck.sh` und einen manuellen Re-Crawl ausführen.

Ein Produktiv-Restore ist ein blockierter Live-Checkpoint; vorher den
Scratch-Restore und die Prüfsummen aus `SHA256SUMS` verifizieren.

## Datenaufbewahrung

`scripts/backup.sh` loescht nach jedem Dump-Lauf `callbacks`-Eintraege, die
aelter als 30 Tage sind (`created_at < now() - interval '30 days'`, als
`DB_ADMIN_USER`). Die Loeschfrist ist damit implementiert, nicht nur
dokumentiert. Zum Pruefen:

```bash
set -a; source .env; set +a
DB_CT="$(pct list | awk '/shopagent-db/{print $1}')"
pct exec "$DB_CT" -- bash -c "PGPASSWORD='$DB_ADMIN_PASSWORD' psql -h 127.0.0.1 -p 54322 -U '$DB_ADMIN_USER' -d postgres -c \"select count(*) from callbacks where created_at < now() - interval '30 days';\""
```

Erwartet nach einem Backup-Lauf: `0`. Der Purge laeuft nur zusammen mit dem
naechtlichen Backup, nicht als eigener Timer.

## Tunnel-Neustart

Die Unit liegt im n8n-LXC:

```bash
N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
pct exec "$N8N_CT" -- systemctl restart shopagent-cloudflared.service
pct exec "$N8N_CT" -- systemctl status shopagent-cloudflared.service --no-pager
pct exec "$N8N_CT" -- journalctl -u shopagent-cloudflared.service -n 50 --no-pager
```

Erwartet: `active (running)` und `Registered tunnel connection` im Log.
Danach von außen prüfen:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "https://$TUNNEL_HOST/webhook/shopagent/search" \
  -H 'Content-Type: application/json' -d '{}'
```

`401` bedeutet Tunnel und Auth funktionieren. `502`/`1033` deuten auf einen
Tunnel- oder n8n-Fehler; dann `docs/runbooks/tunnel.md` befolgen. Die
gerenderte Config unter `/etc/cloudflared/config.yml` nie aus dem Repo
überschreiben – dort stehen nur Platzhalter.

## Firecrawl-Update

Images und Firecrawl-Ref sind in `.env` gepinnt (`FIRECRAWL_REF`,
`FIRECRAWL_IMAGE`, `PLAYWRIGHT_IMAGE`, `REDIS_IMAGE`). Upgrade-Reihenfolge:
**db → n8n → crawler**; erst nach erfolgreichem Healthcheck der Vorstufe.

1. Neuen Ref/Image-Tag in `.env` setzen.
2. Im Crawler-LXC den Checkout und die Images aktualisieren:

   ```bash
   CRAWLER_CT="$(pct list | awk '/shopagent-crawler/{print $1}')"
   pct exec "$CRAWLER_CT" -- bash -c '
     set -euo pipefail
     cd /opt/shopagent-crawler
     docker compose -f firecrawl/docker-compose.yaml -f docker-compose.override.yml pull
     docker compose -f firecrawl/docker-compose.yaml -f docker-compose.override.yml up -d
   '
   ```

   Bei einem neuen `FIRECRAWL_REF` zusätzlich den Checkout im LXC auf den Ref
   bringen (`git -C /opt/shopagent-crawler/firecrawl fetch --depth 1 origin <ref>`
   und `git -C ... checkout FETCH_HEAD`) oder `install/shopagent.sh --role crawler`
   erneut ausführen. Der Installer klont nur, wenn noch kein Checkout existiert.

3. Erreichbarkeit prüfen:

   ```bash
   pct exec "$CRAWLER_CT" -- curl -fsS http://127.0.0.1:3002/health/liveness >/dev/null && echo "firecrawl ok"
   ```

4. Manuellen Re-Crawl ausführen und `crawl_runs` prüfen. Schlägt der neue
   Stand fehl, den vorherigen Image-Tag in `.env` zurücksetzen und den Stack
   erneut starten (Rollback über Image-Tag).

## Kostenprüfung

Monatlich (bzw. am Monatsanfang) prüfen:

1. **ElevenLabs-Kontingent und -Verbrauch** im Dashboard unter Usage, oder
   per API:

   ```bash
   curl -s -H "xi-api-key: $ELEVENLABS_API_KEY" \
     https://api.elevenlabs.io/v1/user/subscription \
     | jq '{character_count, character_limit, next_character_count_reset_unix}'
   ```

   Die Tabelle `calls` im Schema bleibt derzeit unbeschrieben – kein Workflow
   schreibt Post-Call-Daten hinein. Die Gesprächsminuten daher im
   ElevenLabs-Dashboard (Conversations/Usage) ablesen, nicht aus der DB.
   Wer sie automatisch haben will, richtet den ElevenLabs Post-Call-Webhook
   ein und ergänzt einen Insert in `calls`.

   Faustwert: 0,08–0,10 USD pro Minute. Bei unerwartetem Anstieg zuerst
   Prompt/Tool-Schleifen und die Eval-Fälle prüfen, dann das Minuten-Budget
   im ElevenLabs-Konto anpassen.

2. **Rufnummer/SIP-Provider:** ca. 1–10 EUR/Monat, Rechnung mit dem
   Provider-Portal abgleichen.

3. **Firecrawl, Supabase und n8n:** keine Lizenzkosten (self-hosted). Nur
   Proxmox-Storage, Backup-Speicher und Traffic fallen an.

Bei auffälligen Kosten den Alarmpfad prüfen: `03-error-alert` muss mit beiden
Workflows verknüpft und aktiv sein, `NTFY_URL` muss im n8n-Container gesetzt
sein.

## Fehlerbehebung Healthcheck

| Meldung | Erste Prüfung |
|---|---|
| `FAIL: postgres` | `pct exec "$DB_CT" -- systemctl status postgresql`; `DB_HOST`/`DB_PORT` in `.env` |
| `FAIL: n8n` | n8n-Container im n8n-LXC (`docker compose ps`), Unit/Logs prüfen |
| `FAIL: firecrawl` | Tritt nur zwischen 02:50 und 04:00 auf; Crawler-Stack im Fenster starten/prüfen (außerhalb wird der Check übersprungen) |
| `FAIL: produktdaten ...` | Letzten `crawl_runs`-Eintrag und Firecrawl-Log prüfen; Re-Crawl |
| `FAIL: letzter Crawl: ...` | `crawl_runs.errors` und Firecrawl-Antworten prüfen; Re-Crawl starten |
| `FAIL: produktzahl sinkt` | Crawl auf Teilausfall prüfen; `crawl_runs.errors` und Firecrawl-Antworten |
| `FAIL: webhook/auth` | Ohne `TUNNEL_HOST`: n8n-Workflow-Aktivierung prüfen (Workflow muss aktiv sein, sonst 404). Mit Tunnel: Tunnel-Status; `docs/runbooks/tunnel.md` |

Der Healthcheck fasst mehrere Fehler zusammen und alarmiert einmal pro Lauf.
Nach der Behebung erneut ausführen, bis `HEALTH OK` erscheint.

## Live-Checkpoint-Risiken (hier nicht testbar)

Diese Umgebung hat **keine Proxmox-, n8n-, Postgres- oder ntfy-Instanz**.
Healthcheck-Lauf, Alarmzustellung, Workflow-Import und Fehlerworkflow-
Verknüpfung sind dokumentierte, blockierte Live-Checkpoints. Statisch geprüft
wurden nur `bash -n` (Skript) und `jq` (Workflow-JSON). Beim ersten echten
Lauf prüfen:

1. **n8n-Version:** Der HTTP-Request-Node nutzt `typeVersion` 4.2,
   `contentType: "raw"` und `rawContentType: "text/plain"`. Ältere/neuere
   n8n-Versionen können ein anderes Body-Feld erwarten; nach dem Import einen
   Testfehler auslösen und den ntfy-Eingang verifizieren.
2. **`$env` in n8n:** `NTFY_URL` muss im Container sichtbar sein; n8n filtert
   je nach Version Umgebungsvariablen. Fehlt sie, schlägt der HTTP-Request
   fehl und der Alarm bleibt aus.
3. **Error-Workflow-Verknüpfung:** Beide Workflows (Crawl und API) müssen den
   Fehlerworkflow in den Settings referenzieren. Die Verknüpfung ist bewusst
   nicht in den Importdateien enthalten.
4. **ntfy-Topic:** Topic-Name ist ein Geheimnis; bei öffentlichem ntfy.sh
   ein ausreichend zufälliges Topic verwenden. Zustellung und Rate-Limits des
   Servers beim ersten Alarm prüfen.
5. **Healthcheck-Zustand:** `product-count` liegt lokal auf dem Admin-Rechner.
   Auf einem frischen Rechner ist der Vorwert leer, daher schlägt der
   Rückgangs-Check beim ersten Lauf nicht an.
