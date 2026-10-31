# Runbook: ShopAgent Crawl (n8n-Workflow)

## Zweck

Der Workflow **ShopAgent Crawl** füllt nachts `products` (aus JSON-LD der
Produktseiten) und `pages` (Versand-, Rückgabe-, Zahlungs- und Kontaktseiten)
und schreibt den Lauf nach `crawl_runs`. Zeitplan: täglich **03:00**
(`Europe/Berlin`, Cron `0 3 * * *`). Der Workflow bleibt nach dem Import
**inaktiv**, bis der Testlauf erfolgreich war.

Ablauf in 15 Schritten:

1. `Schedule Trigger` (Cron `0 3 * * *`)
2. `Run starten` → `insert into crawl_runs (status) values ('running') returning id`
3. `URLs sammeln` → `node /opt/shopagent/scripts/sitemap-urls.mjs` im n8n-Container
4. `URLs parsen` → ein Item pro Produkt-URL mit `run_id`
5. `URLs` (Split In Batches, Batch Size 5)
6. `Firecrawl scrape` → `POST $FIRECRAWL_URL/v2/scrape` mit `rawHtml` + `markdown`
7. `Extrahieren` → inline eingebetteter `extractProduct`/`normalizeProduct`-Code
8. `Fehler?` → `Fehler loggen` (zurück zu 5) oder `Upsert` (zurück zu 5)
9. `Info-URLs` (Done-Ausgang von 5) → Seiten aus `SHOP_INFO_PATHS`
10. `Firecrawl Seite` (Continue On Fail aktiv)
11. `Seite normalisieren`
12. `Seitenfehler?` → `Seitenfehler loggen` oder `Seite upsert`
13. `Weiter` (Execute Once) → sammelt den Seitenzweig
14. `Deaktivieren` → Produkte zweimal in Folge nicht gesehen ⇒ `is_active = false`
15. `Lauf abschließen` → Status `success`/`partial`, Zähler

## Voraussetzungen

### n8n-Container (Env)

Diese Variablen müssen im n8n-Container gesetzt sein (siehe
`docker/n8n/docker-compose.yml` / `.env`):

- `SHOP_SITEMAP_URL`, `SHOP_PRODUCT_PATTERN`, `SITEMAP_MAX_CHILD` (optional, Default 20)
- `SHOP_BASE_URL`, `SHOP_INFO_PATHS`
- `FIRECRAWL_URL`, `FIRECRAWL_API_KEY`
- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` (nur für das Credential)

### Postgres-Credential

Im n8n-UI ein Postgres-Credential namens **ShopAgent DB** anlegen:

| Feld | Wert |
|---|---|
| Host | `DB_HOST` (IP des LXC `shopagent-db`) |
| Port | `DB_PORT` (Default `54322`) |
| Database | `DB_NAME` (`postgres`) |
| User | `DB_USER` (`shopagent`) |
| Password | `DB_PASSWORD` |
| SSL | aus |

Die Workflow-JSON referenziert das Credential **nur über den Namen**
(`"credentials": {"postgres": {"name": "ShopAgent DB"}}`). Es gibt bewusst
keine Credential-ID in der Datei. Beim Import ordnet n8n das Credential über
den Namen zu; falls nicht, im UI pro Postgres-Node **ShopAgent DB** auswählen.

### Dateien im n8n-LXC

Der Workflow ruft das Sitemap-Skript per `Execute Command` im n8n-Container auf.
Vor dem ersten Lauf die Dateien auf den LXC bringen:

```bash
N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
pct exec "$N8N_CT" -- mkdir -p /opt/shopagent/scripts /opt/shopagent/n8n/code
pct push "$N8N_CT" scripts/sitemap-urls.mjs /opt/shopagent/scripts/sitemap-urls.mjs
pct push "$N8N_CT" n8n/code/sitemap-urls.js /opt/shopagent/n8n/code/sitemap-urls.js
pct exec "$N8N_CT" -- docker compose -f /opt/shopagent/docker-compose.yml up -d
```

Prüfen, dass das Skript im Container läuft (liefert ein JSON-Array von URLs):

```bash
N8N_CT="$(pct list | awk '/shopagent-n8n/{print $1}')"
pct exec "$N8N_CT" -- docker compose -f /opt/shopagent/docker-compose.yml exec -T n8n \
  node /opt/shopagent/scripts/sitemap-urls.mjs
```

Der Inline-Extraktor-Code im Node `Extrahieren` wird mit
`node n8n/code/build-inline.mjs` aus `n8n/code/extract-products.js` erzeugt und
ist in `n8n/workflows/01-crawl.json` eingebettet. **Bei Änderungen an
`extract-products.js`** den Generator laufen lassen, den Inhalt von
`/tmp/extract-node.js` in den Node `Extrahieren` übernehmen und den Workflow
neu exportieren.

## Import

1. n8n-UI im LAN öffnen (`http://<N8N_LAN_IP>:5678`).
2. **Workflows → Import from File** → `n8n/workflows/01-crawl.json`.
3. Credential-Zuordnung prüfen (siehe oben), Workflow **inaktiv** lassen.
4. Fehlerworkflow **erst nach Task 15** verknüpfen: In den
   Workflow-Settings unter **Error Workflow** `03-error-alert` auswählen.
   Die Importdatei enthält bewusst **kein** `errorWorkflow`, weil `03-error-alert`
   erst in Task 15 angelegt wird und beim Import noch keine Workflow-ID hat.
5. Erst nach erfolgreichem manuellem Testlauf aktivieren.

## Manueller Testlauf

Im n8n-UI den Workflow öffnen → **Execute Workflow**. Danach in der DB prüfen:

```bash
DB_CT="$(pct list | awk '/shopagent-db/{print $1}')"
pct exec "$DB_CT" -- bash -c "PGPASSWORD='$DB_ADMIN_PASSWORD' psql -h 127.0.0.1 -p 54322 -U '$DB_ADMIN_USER' -d postgres -c 'select count(*) from products; select status, urls_fetched, products_upserted from crawl_runs order by started_at desc limit 3;'"
```

Erwartet: `count > 0`, letzter Lauf `success` (bei einzelnen Firecrawl-Fehlern
`partial`, wenn die Fehler in `crawl_runs.errors` stehen).

## Idempotenz

Den Workflow zweimal hintereinander ausführen, dann:

```bash
DB_CT="$(pct list | awk '/shopagent-db/{print $1}')"
pct exec "$DB_CT" -- bash -c "PGPASSWORD='$DB_ADMIN_PASSWORD' psql -h 127.0.0.1 -p 54322 -U '$DB_ADMIN_USER' -d postgres -c 'select count(*) as total, count(distinct sku) as distinct_sku from products;'"
```

Erwartet: `total = distinct_sku`, keine Duplikate. Der Upsert nutzt
`on conflict (sku) do update`; `normalizeProduct` garantiert eine nicht-leere
SKU (Fallback: Slug).

## Betrieb

- **Zeitfenster:** Der Crawler-LXC startet Firecrawl um 02:50 und stoppt es um
  04:00. Der n8n-Crawl läuft um 03:00. Ein Lauf, der länger als eine Stunde
  dauert, wird um 04:00 mitten im Scrape abgeschnitten. Laufzeit im
  `crawl_runs`-Eintrag beobachten und ggf. Batch Size / Zeitfenster anpassen.
- **Fehlerworkflow:** `03-error-alert` (Task 15) nach dessen Import in den
  Workflow-Settings verknüpfen; bei Fehlern im Workflow selbst (z. B.
  Sitemap-Skript exit 1, DB weg) greift dieser Alarm.
- **Abgebrochene Läufe:** Bricht der Workflow vor `Lauf abschließen` ab, bleibt
  der `crawl_runs`-Eintrag auf `running` mit `finished_at = null`. Das ist ein
  Diagnosehinweis; der nächste Lauf legt einen neuen Eintrag an. Alte
  `running`-Einträge können manuell auf `failed` gesetzt werden.

## Live-Checkpoint-Risiken (hier nicht testbar)

Diese Umgebung hat **keine n8n-Instanz**. Import und Ausführung sind
dokumentierte, blockierte Live-Checkpoints; die JSON-Datei wurde nur statisch
(`jq`, Node-Validator) geprüft. Beim ersten echten Import prüfen:

1. **Seitenzweig-Warteschlange:** `Weiter` hat *Execute Once*; der Node kann
   beim ersten eintreffenden Seiten-Item laufen, bevor der zweite Seitenzweig
   (`Seite upsert`/`Seitenfehler loggen`) fertig ist. Dadurch können
   `Deaktivieren`/`Lauf abschließen` früher starten und Seiten-Zähler zu klein
   sein. Für v1 bewusst akzeptiert; bei Bedarf Seitenzweig über ein
   Merge-/Wait-Konstrukt zusammenführen.
2. **Postgres-Node-Version:** Die Query-Parameter nutzen Array-Ausdrücke, die
   erst ab Postgres-Node `typeVersion` 2.8 einen Bind-Wert pro Ausdruck
   ergeben (kein Split bei Kommas in `content_md`). Die n8n-Version im LXC
   muss das unterstützen; `n8nio/n8n:latest` beim Deployment pinnen und
   prüfen.
3. **Credential-Zuordnung:** Ohne Credential-ID im Import muss `ShopAgent DB`
   vorhanden sein; sonst schlagen alle Postgres-Nodes fehl.
4. **Conflict-Target:** Der Produkt-Upsert nutzt `sku` als Konfliktspalte. Ändert
   sich die SKU bei gleicher `product_url` (oder `slug`), kann der Upsert an
   einem anderen Unique-Index scheitern; dann Fehler im Lauf prüfen.
5. **Firecrawl Continue On Fail:** Bei HTTP-Fehlern liefert `Firecrawl Seite` ein
   Item mit `error`; `Seite normalisieren` loggt das als Seitenfehler. Prüfen,
   dass die Fehlerform (`$json.error.message`) zur installierten n8n-Version
   passt.
6. **Sitemap-Grenzen:** Sitemap-Index mit mehr als `SITEMAP_MAX_CHILD` (Default
   20) Kindern oder verschachtelte Indizes brechen den Lauf mit klarer
   Fehlermeldung ab (kein leerer Crawl).
7. **Netzwerk:** `Execute Command` läuft im n8n-Container; DNS/Erreichbarkeit
   des Shops und von Firecrawl aus diesem Container prüfen.

## Rollback

Workflow im n8n-UI deaktivieren. Bereits geschriebene Produkte/Seiten bleiben
stehen; ein erneuter Lauf korrigiert sie idempotent. Kein Schema-Rollback nötig.
