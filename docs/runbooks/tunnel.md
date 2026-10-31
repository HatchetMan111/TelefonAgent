# Runbook: Cloudflare Tunnel und WAF

## Zweck

Der Cloudflare Tunnel veröffentlicht **ausschließlich** den Agent-Webhook
`https://<TUNNEL_HOST>/webhook/shopagent/*`. Alle anderen Pfade antworten mit
`404`. n8n selbst bleibt nur im LAN erreichbar; ein direkter Port auf dem
n8n-LXC wird nicht geöffnet. Die WAF drosselt zusätzlich pro IP.

| Komponente | Datei / Dienst |
|---|---|
| Tunnel-Config (Vorlage) | `docker/n8n/cloudflared-config.yml` |
| Gerenderte Config im LXC | `/etc/cloudflared/config.yml` |
| Credentials im LXC | `/etc/cloudflared/credentials.json` |
| systemd-Unit | `shopagent-cloudflared.service` |
| Upstream | n8n auf `localhost:5678` |

Die Config enthält nur Platzhalter `${TUNNEL_ID}` und `${TUNNEL_HOST}`. Sie
wird beim Deployment per `sed` gerendert; **niemals** die gerenderte Datei mit
echter Tunnel-ID committen.

## Voraussetzungen

- Domain liegt bei Cloudflare (Zone aktiv, Nameserver bei Cloudflare).
- **Admin-Rechner:** `cloudflared` installiert, `~/.cloudflared/` beschreibbar.
- **Proxmox-Host:** `pct` verfügbar, n8n-LXC `shopagent-n8n` läuft und ist per
  `http://<N8N_LAN_IP>:5678/healthz` erreichbar.
- **Repo-Checkout auf dem Admin-Rechner** mit gefüllter `.env` (600), u. a.
  `TUNNEL_ID`, `TUNNEL_HOST`, `AGENT_WEBHOOK_SECRET`. `TUNNEL_ID` steht erst
  nach dem Anlegen des Tunnels fest (Schritt 2).
- Der Agent-Webhook (Tasks 8/9) ist importiert und **aktiv**; ohne aktiven
  Workflow liefert n8n für `/webhook/shopagent/*` einen 404.

## 1. Tunnel-Config prüfen (Vorlage)

`docker/n8n/cloudflared-config.yml`:

```yaml
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json
ingress:
  - hostname: ${TUNNEL_HOST}
    path: ^/webhook/shopagent/.*
    service: http://localhost:5678
  - service: http_status:404
```

Die Reihenfolge der `ingress`-Regeln ist bindend: erst der Webhook-Pfad, dann
der Catch-all `http_status:404`. Ein zusätzlicher oder breiterer Pfad öffnet
n8n unbeabsichtigt öffentlich.

## 2. Tunnel anlegen (einmalig, auf dem Admin-Rechner)

```bash
set -a; source .env; set +a
: "${TUNNEL_HOST:?TUNNEL_HOST fehlt in .env}"
cloudflared tunnel login
cloudflared tunnel create shopagent
cloudflared tunnel route dns shopagent "$TUNNEL_HOST"
```

`TUNNEL_HOST` muss aus `.env` gesetzt sein, damit der CNAME auf den richtigen
Namen zeigt.

Erwartet:

- `~/.cloudflared/<TUNNEL_ID>.json` (Credentials),
- ein DNS-CNAME `<TUNNEL_HOST>` → `<TUNNEL_ID>.cfargotunnel.com`,
- die Tunnel-ID aus der Ausgabe von `cloudflared tunnel create` bzw. aus
  `ls ~/.cloudflared/*.json` in `.env` als `TUNNEL_ID` eintragen.

## 3. Credentials und Config in den n8n-LXC bringen

```bash
set -a; source .env; set +a
: "${TUNNEL_ID:?TUNNEL_ID fehlt in .env}"
: "${TUNNEL_HOST:?TUNNEL_HOST fehlt in .env}"
N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
pct exec "$N8N_CT" -- mkdir -p /etc/cloudflared
pct push "$N8N_CT" ~/.cloudflared/"$TUNNEL_ID".json /etc/cloudflared/credentials.json
pct exec "$N8N_CT" -- chmod 600 /etc/cloudflared/credentials.json
sed -e "s|\${TUNNEL_ID}|$TUNNEL_ID|" -e "s|\${TUNNEL_HOST}|$TUNNEL_HOST|" \
  docker/n8n/cloudflared-config.yml > /tmp/cloudflared-config.yml
pct push "$N8N_CT" /tmp/cloudflared-config.yml /etc/cloudflared/config.yml
pct exec "$N8N_CT" -- chmod 600 /etc/cloudflared/config.yml
pct exec "$N8N_CT" -- systemctl restart shopagent-cloudflared.service
```

Hinweise:

- `set -a; source .env; set +a` exportiert alle Variablen für die nachfolgenden
  Befehle; die beiden `: "${...:?}"`-Zeilen brechen mit klarer Meldung ab,
  wenn `TUNNEL_ID` oder `TUNNEL_HOST` fehlt oder leer ist.
- Die `sed`-Ersetzung rendert nur die zwei Platzhalter. Das Ergebnis in
  `/tmp/cloudflared-config.yml` enthält danach **keine** `${...}`-Zeichen mehr.
- `chmod 600` gilt für Credentials **und** Config, da die Config die
  Tunnel-ID enthält. Beide Dateien liegen unter dem schreibgeschützt
  eingebundenen `/etc/cloudflared` (siehe `cloudflared.service`).
- n8n muss auf `localhost:5678` lauschen; im LXC läuft der Container mit
  `network_mode: host`, die Unit startet cloudflared mit `--network host`.

### Prüfen, dass die Config gerendert ist

```bash
N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
pct exec "$N8N_CT" -- sh -c 'grep -n "\${" /etc/cloudflared/config.yml && exit 1 || true'
pct exec "$N8N_CT" -- sh -c 'sed -n "1,3p" /etc/cloudflared/config.yml'
pct exec "$N8N_CT" -- stat -c '%a %n' /etc/cloudflared/config.yml /etc/cloudflared/credentials.json
```

Erwartet: `grep` findet nichts (Exit 0), Zeile 1 zeigt die echte Tunnel-ID,
Zeile 2 `credentials-file`, die Rechte sind `600`.

## 4. cloudflared starten und Status prüfen

```bash
N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
pct exec "$N8N_CT" -- systemctl enable --now shopagent-cloudflared.service
pct exec "$N8N_CT" -- systemctl status shopagent-cloudflared.service --no-pager
pct exec "$N8N_CT" -- journalctl -u shopagent-cloudflared.service -n 50 --no-pager
```

Erwartet im Log: `Registered tunnel connection` mit mehreren Connectors
(`lhr`, `fra`, …) und **keine** `failed to`/`error`-Zeilen.

## 5. WAF-Rate-Limit setzen (Cloudflare Dashboard)

Security → WAF → Rate limiting rules → **Create**:

| Feld | Wert |
|---|---|
| Name | `shopagent-webhook` |
| Expression | `(http.host eq "<TUNNEL_HOST>" and starts_with(http.request.uri.path, "/webhook/shopagent/"))` |
| Requests | 30 pro Minute |
| Zeitraum | 60 s |
| Action | `Block` |

`<TUNNEL_HOST>` durch den echten Host ersetzen. Die Regel greift nur auf den
Webhook-Pfad; UI- und sonstige Anfragen werden bereits vom Tunnel mit 404
beantwortet. Nach dem Speichern im Dashboard prüfen, dass die Regel **aktiv**
ist und der Expression-Editor keine Syntaxfehler meldet.

## 6. Test von außen

```bash
set -a; source .env; set +a
: "${TUNNEL_HOST:?TUNNEL_HOST fehlt in .env}"
: "${AGENT_WEBHOOK_SECRET:?AGENT_WEBHOOK_SECRET fehlt in .env}"
# ohne Secret -> 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST "https://$TUNNEL_HOST/webhook/shopagent/search" \
  -H 'Content-Type: application/json' -d '{"query":"x"}'
# mit Secret -> 200
curl -s -X POST "https://$TUNNEL_HOST/webhook/shopagent/search" \
  -H "Authorization: Bearer $AGENT_WEBHOOK_SECRET" -H 'Content-Type: application/json' \
  -d '{"query":"Regenschuh"}'
# fremder Pfad -> 404
curl -s -o /dev/null -w '%{http_code}\n' "https://$TUNNEL_HOST/"
```

Erwartet:

1. erster Aufruf ohne Secret: `401`,
2. zweiter Aufruf: HTTP 200 und JSON mit `products` (Produktdaten aus dem
   Crawl; leere Trefferliste ist bei fehlendem Crawl ebenfalls 200),
3. Wurzelpfad: `404`.

Die beiden `: "${...:?}"`-Zeilen stellen sicher, dass `.env` geladen und
`AGENT_WEBHOOK_SECRET` nicht leer ist; andernfalls würde der „mit Secret“-Test
still ohne Bearer-Header laufen.

Zusätzlich prüfen, dass die n8n-UI **nicht** öffentlich ist (muss 404 liefern):

```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://$TUNNEL_HOST/home/workflows"
```

## Betrieb

- **Connectors:** `systemctl status` zeigt `active (running)`; das Log nennt
  mindestens zwei registrierte Verbindungen. Cloudflare verteilt Traffic auf
  alle Connectors.
- **Updates:** `CLOUDFLARED_IMAGE` ist in `.env` gepinnt. Image-Tag ändern →
  `systemctl restart shopagent-cloudflared.service`.
- **Logs:** `journalctl -u shopagent-cloudflared.service -f` auf dem n8n-LXC.
- **Secret-Rotation:** `TUNNEL_ID`/Credentials nur bei neuem Tunnel ersetzen;
  `AGENT_WEBHOOK_SECRET` rotiert unabhängig davon (siehe Runbook Secret-Rotation).

## Fehlerbehebung

### Tunnel down / keine Verbindung

Symptome: externe `curl`-Aufrufe liefern Cloudflare-Fehler 502/1033, im Log
`failed to connect` oder `context canceled`.

1. Unit-Status und letzte Logzeilen prüfen:
   ```bash
   N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
   pct exec "$N8N_CT" -- systemctl status shopagent-cloudflared.service --no-pager
   pct exec "$N8N_CT" -- journalctl -u shopagent-cloudflared.service -n 100 --no-pager
   ```
2. Läuft der Container? `pct exec "$N8N_CT" -- docker ps -a --filter name=shopagent-cloudflared`.
3. Erreichbarkeit nach außen aus dem LXC: `pct exec "$N8N_CT" -- getent hosts region1.v2.argotunnel.com`
   bzw. `curl -sS -o /dev/null -w '%{http_code}\n' https://cloudflare.com`.
4. Uhrzeit/DNS im LXC prüfen (`timedatectl`, `resolvectl status`); falsche Zeit
   oder DNS bricht den TLS-Handshake.
5. Unit neu starten: `pct exec "$N8N_CT" -- systemctl restart shopagent-cloudflared.service`.
6. Bleibt es dabei: Tunnel im Cloudflare-Dashboard (Zero Trust → Networks →
   Tunnels) auf `Down` prüfen und neu anlegen (Abschnitt Rollback, dann
   Schritt 2–4).

### Config nicht gerendert (Platzhalter im LXC)

Symptome: cloudflared startet nicht oder loggt `invalid tunnel ID` bzw.
`hostname ""`; `/etc/cloudflared/config.yml` enthält noch `${TUNNEL_ID}` oder
`${TUNNEL_HOST}`.

```bash
N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
pct exec "$N8N_CT" -- grep -n '\${' /etc/cloudflared/config.yml
set -a; source .env; set +a
: "${TUNNEL_ID:?TUNNEL_ID fehlt in .env}"
: "${TUNNEL_HOST:?TUNNEL_HOST fehlt in .env}"
```

Ursache ist meist ein leeres `TUNNEL_ID`/`TUNNEL_HOST` beim `sed`-Lauf oder ein
`sed`-Aufruf ohne die beiden `-e`-Ausdrücke. Schritt 3 vollständig wiederholen
(inkl. `chmod 600`) und die Unit neu starten. Die gerenderte Datei nie aus dem
Repo kopieren – dort stehen absichtlich nur Platzhalter.

### Falscher Hostname (404/1033 oder Zertifikatsfehler)

Symptome: `curl` liefert 404 für den Webhook, Cloudflare-Fehler 1033, oder der
Browser meldet ein Zertifikat für eine fremde Domain.

1. DNS prüfen: `dig +short "$TUNNEL_HOST"` muss den CNAME auf
   `<TUNNEL_ID>.cfargotunnel.com` zeigen.
2. Config im LXC prüfen: `hostname:` muss exakt `$TUNNEL_HOST` sein (ohne
   Schema, ohne Pfad, ohne Port). `pct exec "$N8N_CT" -- sed -n '1,6p' /etc/cloudflared/config.yml`.
3. `TUNNEL_HOST` in `.env` mit dem bei `cloudflared tunnel route dns`
   verwendeten Namen vergleichen.
4. Bei Abweichung: DNS-Route mit dem richtigen Namen neu setzen
   (`cloudflared tunnel route dns shopagent "$TUNNEL_HOST"`), Config neu
   rendern/pushen und die Unit neu starten. Alten CNAME im Dashboard löschen.

### Webhook liefert 404, obwohl Hostname stimmt

- Pfad muss mit `/webhook/shopagent/` beginnen; die Regex ist
  `^/webhook/shopagent/.*`. Ein Aufruf auf `/webhook-test/...` oder
  `/webhook/search` läuft in den Catch-all und ergibt 404.
- Ist der n8n-Workflow aktiv? Test-Webhooks (`webhook-test`) sind nur bei
  geöffneter UI-Ausführung erreichbar.
- n8n im LXC direkt prüfen:
  `pct exec "$N8N_CT" -- curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:5678/webhook/shopagent/search -H 'Content-Type: application/json' -d '{}'`.
  Kommt dort 401, liegt das Problem im Tunnel; kommt dort 404, ist der
  Workflow/Pfad falsch.

### 429 / Block durch die WAF

Symptome: schnelle Testschleifen liefern `429` oder die Cloudflare-Blockseite.

- Das ist die Rate-Limit-Regel (30/min/IP). Testsequenzen drosseln oder kurz
  warten; nicht die Regel deaktivieren, außer zur Fehlersuche mit sofortigem
  Wiederaktivieren.
- Bei legitimem Bedarf (z. B. Lasttest) die Regel temporär erhöhen und danach
  auf 30/min zurücksetzen.

## Rollback

1. Tunnel-Dienst stoppen und deaktivieren:
   ```bash
   N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
   pct exec "$N8N_CT" -- systemctl disable --now shopagent-cloudflared.service
   ```
2. DNS-Eintrag im Cloudflare-Dashboard (DNS) löschen: der CNAME
   `<TUNNEL_HOST>` → `<TUNNEL_ID>.cfargotunnel.com` muss weg sein, bevor der
   Tunnel gelöscht wird. Danach auf dem Admin-Rechner:
   ```bash
   cloudflared tunnel delete shopagent
   ```
3. WAF-Regel `shopagent-webhook` im Dashboard deaktivieren oder löschen.
4. Optional Dateien im LXC entfernen:
   ```bash
   pct exec "$N8N_CT" -- rm -f /etc/cloudflared/config.yml /etc/cloudflared/credentials.json
   ```
5. Lokal `~/.cloudflared/<TUNNEL_ID>.json` löschen oder sicher archivieren;
   `TUNNEL_ID` in `.env` auf `CHANGE_ME` zurücksetzen.

Nach dem Rollback ist der Agent von außen nicht mehr erreichbar; n8n bleibt im
LAN erreichbar. Der Webhook selbst (Workflow, Secret) bleibt unverändert.

## Live-Checkpoint-Risiken (hier nicht testbar)

Diese Umgebung hat **kein Cloudflare-Konto, keinen Tunnel und keinen
Proxmox-Host**. Tunnel-Anlage, DNS, WAF-Regel und die externen `curl`-Checks
sind dokumentierte, blockierte Live-Checkpoints. Statisch geprüft wurde nur die
YAML-Syntax der Vorlage (Platzhalter, Pfad-Regex, Catch-all). Beim ersten
echten Deployment besonders prüfen:

1. **Regex-Verhalten:** cloudflared wertet `path` als Go-Regex gegen den Pfad
   aus. `^/webhook/shopagent/.*` deckt alle Tool-Endpunkte ab, aber keinen
   Query-String-Fall ohne Pfad; nach dem Deployment mit allen fünf Endpunkten
   (`search`, `product`, `info`, `callback`, `handoff`) testen.
2. **`chmod 600` und Mount:** Die Unit bindet `/etc/cloudflared` read-only ein;
   Dateien müssen vor dem Start vorhanden und lesbar sein. Fehlt
   `credentials.json`, startet der Container, der Tunnel scheitert aber.
3. **n8n `WEBHOOK_URL`:** n8n läuft hinter dem Tunnel mit
   `WEBHOOK_URL=https://${TUNNEL_HOST}/`; nach dem ersten Tunnel-Start die
   Webhook-URL in der UI/Logs gegen `TUNNEL_HOST` prüfen.
4. **WAF-Expression:** Dashboard-Syntax kann von der hier dokumentierten
   abweichen (Feldnamen je Cloudflare-Plan). Nach dem Speichern einen
   Testaufruf über 30/min hinaus wiederholen und den Block verifizieren.
5. **Rate-Limit pro IP:** Der Agent (ElevenLabs) und der Admin-Rechner haben
   unterschiedliche Quell-IPs; die 30/min gelten je IP, nicht global.
