# KI-Telefonagent für den eigenen Shop – Design

- **Datum:** 2026-10-28
- **Status:** Entwurf zur Freigabe
- **Projektordner:** `telefonagent-proxmox/`

## 1. Kontext und Ziel

Der Shop soll telefonisch erreichbar sein, ohne dass jemand ans Telefon gehen muss.
Ein eingehender KI-Telefonagent beantwortet Fragen zu Produkten, Preisen,
Verfügbarkeit, Öffnungszeiten, Versand und Rückgabe. Die Wissensbasis entsteht
automatisch aus der öffentlichen Shop-Website.

Alles läuft im eigenen Proxmox-Homelab. Nur ElevenLabs (ASR, LLM, TTS) und die
Telefonie sind extern. Der Agent liest live aus der lokalen Datenbank, es gibt
keine Datenkopie der Produktdaten in der Cloud.

### 1.1 Entscheidungen aus der Klärung

| Thema | Entscheidung |
|---|---|
| Aufgabe | Eingehende Produkt-/Shop-Auskunft (kein Bestellstatus, kein Outbound) |
| Telefonie | Eigener SIP-Trunk mit deutscher Rufnummer, per SIP-Trunk an ElevenLabs |
| Datenquelle | Eigener Shop, ausschließlich öffentliche Website, kein Admin-Zugriff |
| Datenzugriff | Live-Webhook über Cloudflare Tunnel, Supabase bleibt privat |
| Kataloggröße | Mittel: 100–1.000 Produkte |
| Aktualität | Nächtlicher Crawl; Agent darf Preise und grobe Verfügbarkeit nennen |
| Aufbau | Drei getrennte LXCs: `shopagent-db`, `shopagent-n8n`, `shopagent-crawler` |
| Suche | Postgres-Volltext + Trigram, kein pgvector in v1 |

### 1.2 Nicht-Ziele (v1)

- Bestellstatus, Kundenkonto, Bestellannahme oder Zahlungen am Telefon
- Outbound-Anrufe
- Multi-Shop oder mehrere Sprachen parallel (Deutsch primär, Englisch als Fallback)
- Vektor-/Embedding-Suche
- Supabase Auth, Storage, Realtime
- Sprach-Cloning oder eigene TTS-Modelle

## 2. Annahmen (in Phase 0 zu verifizieren)

1. Der Shop liefert `sitemap.xml` und produktseitig `schema.org/Product` als JSON-LD.
2. Der Shop blockiert den Crawler nicht (kein Bot-Schutz, der eigene IPs aussperrt).
3. Der Proxmox-Host hat mindestens 10 GB RAM und 50 GB Disk frei.
4. Ein deutscher SIP-Provider unterstützt statisches Routing zu
   `sip.rtc.elevenlabs.io` (Telnyx ist dokumentiert; sipgate/Telekom zu prüfen).
5. Eine Domain liegt bei Cloudflare (für den Tunnel) oder ein eigener
   Reverse Proxy mit TLS ist vorhanden.
6. Der ElevenLabs-Plan erlaubt Phone-Agents und eine deutsche Stimme.

## 3. Architektur

```
Anrufer ──PSTN──▶ SIP-Provider ──SIP/TLS──▶ ElevenLabs (Cloud)
                                              │ Webhook-Tool, HTTPS + Bearer
                                              ▼
                                   Cloudflare Tunnel (nur /webhook/*)
                                              ▼
                          LXC shopagent-n8n  (n8n, intern :5678)
                                              │ SQL (privates Netz)
                                              ▼
                          LXC shopagent-db   (Supabase/Postgres)

Nachts:
n8n-Cron ──HTTP──▶ LXC shopagent-crawler (Firecrawl)
                        │ sitemap → Produktseiten → HTML/Markdown
                        ▼
                  n8n: JSON-LD parsen → Upsert
                        ▼
                  Supabase
```

### 3.1 Komponenten und Ressourcen

| LXC | Inhalt | vCPU | RAM | Disk | Öffentlich |
|---|---|---|---|---|---|
| `shopagent-db` | Postgres + Studio (Supabase minimal, PostgREST optional) | 2 | 4 GB | 20 GB | nein |
| `shopagent-n8n` | n8n + cloudflared | 2 | 2 GB | 10 GB | nur `/webhook/*` |
| `shopagent-crawler` | Firecrawl (api, worker, playwright, redis) | 2 | 4 GB | 20 GB | nein |

- Alle LXCs: Debian 13, unprivilegiert, `nesting=1`, `onboot=1`, Docker nur wo nötig.
- n8n nutzt dieselbe Postgres-Instanz wie Supabase (eigene Datenbank `n8n`),
  damit es nur eine Sicherung gibt.
- Firecrawl läuft nur nachts. Ein systemd-Timer startet die Container um 02:50
  und stoppt sie um 04:00, falls der Crawl früher fertig ist.
- Alle Images mit festen Tags, keine `latest`.

### 3.2 Latenzbudget pro Anruf

| Schritt | Ziel |
|---|---|
| ASR | 200–400 ms |
| LLM erster Token | 300–600 ms |
| Tool-Call (Tunnel → n8n → SQL) | **p95 < 500 ms** |
| TTS | 150–300 ms |

Firecrawl ist nie im Anrufpfad. Der Webhook macht genau eine SQL-Abfrage,
kein LLM, kein Firecrawl-Aufruf.

## 4. Datenmodell

```sql
create extension if not exists pg_trgm;

create table products (
  id            uuid primary key default gen_random_uuid(),
  sku           text unique,
  slug          text unique,
  name          text not null,
  description   text,
  price_cents   integer,
  currency      char(3) not null default 'EUR',
  availability  text check (availability in ('instock','outofstock','preorder','unknown')),
  category      text,
  brand         text,
  attributes    jsonb not null default '{}'::jsonb,
  image_url     text,
  product_url   text not null,
  source_hash   text not null,
  is_active     boolean not null default true,
  miss_count    smallint not null default 0,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index products_fts_idx on products
  using gin (to_tsvector('german', coalesce(name,'') || ' ' || coalesce(description,'')));
create index products_name_trgm_idx on products using gin (name gin_trgm_ops);
create index products_active_idx on products (is_active) where is_active;

create table pages (
  id           uuid primary key default gen_random_uuid(),
  url          text unique not null,
  title        text,
  content_md   text not null,
  topic        text,
  content_hash text not null,
  updated_at   timestamptz not null default now()
);

create table crawl_runs (
  id                   uuid primary key default gen_random_uuid(),
  started_at           timestamptz not null default now(),
  finished_at          timestamptz,
  status               text not null default 'running'
                         check (status in ('running','success','partial','failed')),
  urls_total           integer not null default 0,
  urls_fetched         integer not null default 0,
  products_upserted    integer not null default 0,
  products_deactivated integer not null default 0,
  errors               jsonb not null default '[]'::jsonb
);

create table callbacks (
  id         uuid primary key default gen_random_uuid(),
  name       text,
  phone      text not null,
  reason     text,
  created_at timestamptz not null default now(),
  handled_at timestamptz
);

create table calls (
  id              uuid primary key default gen_random_uuid(),
  conversation_id text unique,
  started_at      timestamptz,
  duration_sec    integer,
  summary         text,
  tool_calls      jsonb not null default '[]'::jsonb,
  outcome         text,
  created_at      timestamptz not null default now()
);
```

### 4.1 Suchfunktion

```sql
create or replace function search_products(
  q text,
  p_category text default null,
  p_max_price_cents integer default null,
  p_in_stock_only boolean default false,
  p_limit integer default 5
) returns jsonb
language sql stable as $$
  with base as (
    select p.*,
           ts_rank(
             to_tsvector('german', coalesce(p.name,'') || ' ' || coalesce(p.description,'')),
             websearch_to_tsquery('german', coalesce(nullif(trim(q), ''), 'x'))
           ) as rank
    from products p
    where p.is_active
      and (p_category is null or p.category = p_category)
      and (p_max_price_cents is null or p.price_cents <= p_max_price_cents)
      and (not p_in_stock_only or p.availability = 'instock')
  ),
  fts as (
    select * from base
    where to_tsvector('german', coalesce(name,'') || ' ' || coalesce(description,''))
          @@ websearch_to_tsquery('german', coalesce(nullif(trim(q), ''), 'x'))
    order by rank desc
    limit p_limit
  ),
  fuzzy as (
    select * from base
    where not exists (select 1 from fts)
    order by similarity(name, q) desc
    limit p_limit
  )
  select jsonb_build_object(
    'as_of', to_char(now(), 'YYYY-MM-DD'),
    'products', coalesce(jsonb_agg(jsonb_build_object(
      'sku', sku,
      'name', name,
      'price_eur', round(price_cents / 100.0, 2),
      'availability', availability,
      'url', product_url,
      'last_seen', last_seen_at
    )), '[]'::jsonb)
  )
  from (select * from fts union all select * from fuzzy) t;
$$;
```

## 5. Crawl-Pipeline

1. **Trigger:** n8n-Cron täglich 03:00.
2. **Discovery:** `sitemap.xml` (inkl. Sitemap-Index) laden, Produkt-URLs per
   Include-/Exclude-Muster filtern (`/produkt/`, `/product/`, `/p/`;
   ausgeschlossen: Warenkorb, Kasse, Konto, Suche, Filter-URLs).
3. **Inkrementell:** URLs mit unverändertem `lastmod` überspringen; optionaler
   Voll-Crawl per manuellem n8n-Trigger.
4. **Fetch:** Firecrawl `/v2/scrape` mit `formats: ["rawHtml","markdown"]`,
   `onlyMainContent: true`, Timeout 30 s, Concurrency 2, max. 1 Request/s,
   User-Agent `ShopAgentCrawler/1.0 (+<kontakt-url>)`. `robots.txt` wird respektiert.
5. **Extraktion:** JSON-LD (`schema.org/Product`) aus `rawHtml` parsen:
   `name`, `sku`, `description`, `offers.price`, `offers.priceCurrency`,
   `offers.availability`, `image`, `brand`, `category`.
   - `AggregateOffer` (Preisspanne) → niedrigster Preis, `attributes.price_range` setzen.
   - Fehlt JSON-LD → CSS-Selektor-Fallback pro Shop-Template (in n8n konfiguriert).
   - Kein LLM im Standardpfad.
6. **Normalisieren:** Preise in Cent, Verfügbarkeit auf ENUM abbilden,
   Whitespace/HTML bereinigen, `source_hash` über die normalisierten Felder bilden.
7. **Upsert:** `on conflict (sku)` (Fallback `slug`), Update nur wenn
   `source_hash` abweicht; `last_seen_at` und `miss_count = 0` immer setzen.
8. **Deaktivieren:** Nicht gesehene Produkte `miss_count + 1`; bei `>= 2`
   `is_active = false`. Kein hartes Löschen.
9. **Protokoll:** `crawl_runs` schreiben (Zähler, Dauer, Fehlerliste).
10. **Alarm:** n8n-Fehlerworkflow bei `status != success` oder wenn die
    Produktzahl um mehr als 20 % gegenüber dem Vortag fällt.

**Laufzeit:** 1.000 Seiten × ~1–2 s bei 2 parallelen Requests ≈ 20–35 min.

## 6. Agent und Tools

### 6.1 ElevenLabs-Konfiguration

| Einstellung | Wert |
|---|---|
| Agent-Typ | Phone (Inbound) |
| Sprache | Deutsch, „Sie“; Wechsel auf Englisch bei englischsprachigem Anrufer |
| ASR | Scribe |
| TTS | Eleven Flash v2.5, deutsche Stimme, Stability ~0.5, Similarity ~0.75 |
| LLM | schnelles Modell, Temperatur 0.2, max. ~150 Tokens |
| Turn-Taking | VAD + Unterbrechung, Antworten ≤ 2 Sätze |
| Dynamische Variablen | `shop_name`, `shop_url`, `today`, `caller_number` |
| Max. Gesprächsdauer | 10 min, danach Rückruf/Mitarbeiter anbieten |
| Aufzeichnung | standardmäßig aus (siehe 9) |

Die Agent-Konfiguration liegt versioniert in `elevenlabs/agent.json`, der Prompt
in `elevenlabs/prompt.md` und wird per Skript über die ElevenLabs-API angewendet.

### 6.2 Pflicht-Guardrails

1. **KI-Offenlegung** in der Begrüßung; auf Nachfrage ehrlich bejahen.
2. **Nur aus Tool-Ergebnissen antworten.** Kein Treffer → ehrlich sagen,
   Rückruf oder Shop-URL anbieten. Nichts erfinden.
3. **Preise** nur als „laut Shop <Preis>, Stand <Datum>“; Preise im Shop sind
   verbindlich. Keine Rabatte, keine Lieferzusagen, keine Bestelländerungen.
4. **Eskalation** bei Beschwerde, Reklamation, „Mitarbeiter“, Drohung oder
   wiederholtem Missverständnis → `handoff_to_human`.
5. **Keine** Rechts-, Medizin- oder Finanzberatung; keine Zahlungsdaten am Telefon.
6. Nach zwei erfolglosen Verständigungsversuchen Rückruf anbieten.

### 6.3 Tool-Verträge

Alle Tools: `POST`, `Authorization: Bearer <secret>`, JSON, Timeout 10 s.
Basis: `https://<tunnel-domain>/webhook/shopagent/`.

| Tool | Pfad | Parameter | Antwort |
|---|---|---|---|
| `search_products` | `search` | `query` (req.), `category?`, `max_price_eur?`, `in_stock_only?` | `{ as_of, products: [{sku,name,price_eur,availability,url,last_seen}] }` |
| `get_product` | `product` | `name?` oder `sku?` | `{ as_of, product: {...}, variants: [...] }` |
| `get_shop_info` | `info` | `topic` (Öffnungszeiten, Versand, Lieferzeit, Rückgabe, Zahlung, Kontakt) | `{ answer, source_url, as_of }` |
| `create_callback` | `callback` | `name`, `phone`, `reason` | `{ ok, reference }` |
| `handoff_to_human` | `handoff` | `reason` (Beschwerde, Reklamation, Beratung, Sonstiges) | `{ ok, action: "transfer"\|"callback" }` |

- Ein n8n-Webhook mit Switch auf den Pfad; je Tool ein eigener Endpunkt,
  damit die Tool-Beschreibung im Prompt eindeutig bleibt.
- `pre_tool_speech` für `search_products` an („Einen Moment, ich schaue nach.“).
- Fehlerantworten sind sprechbar: `{ "ok": false, "message": "Die Daten sind gerade nicht erreichbar." }`.

### 6.4 Beispiel: Tool-Antwort

```json
{
  "as_of": "2026-10-28",
  "products": [
    {
      "sku": "REGEN-42-BLK",
      "name": "Regenschuh Urban 42 schwarz",
      "price_eur": 89.9,
      "availability": "instock",
      "url": "https://shop.example/produkt/regenschuh-urban-42-schwarz",
      "last_seen": "2026-10-28T03:12:41Z"
    }
  ]
}
```

## 7. Sicherheit

- Webhook nur mit 32-Byte-Bearer-Secret, Rotation quartalsweise, Secret in `.env` (600).
- Cloudflare WAF: Rate-Limit 30 Requests/min pro IP auf den Webhook-Pfad.
- Supabase/Postgres und n8n-UI sind nicht aus dem Internet erreichbar.
- n8n greift über die interne LXC-IP auf Postgres zu (eigener DB-User, nur
  `select/insert/update` auf die Agent-Tabellen).
- Firecrawl-API-Key nur im internen Netz; ElevenLabs-API-Key nur auf dem
  Admin-Rechner bzw. in n8n, nicht im Agent-Prompt.
- Keine personenbezogenen Daten außer Rufnummer und freiwilliger Rückrufnotiz.

## 8. Betrieb

- **Sicherung:** täglich `pg_dump` (Produkte, Seiten, Callbacks, Calls, n8n-DB)
  auf Proxmox-Storage/PBS, 14 Tage Aufbewahrung, Restore einmal monatlich getestet.
- **Monitoring:** Healthchecks für Postgres, n8n, Firecrawl; n8n-Fehlerworkflow
  und Crawl-Alarm per ntfy/E-Mail; ElevenLabs-Kontingent beobachten.
- **Updates:** gepinnte Images, Upgrade-Reihenfolge dokumentiert
  (db → n8n → crawler), Rollback über Image-Tag und DB-Dump.
- **Runbook:** manueller Re-Crawl, Secret-Rotation, Agent-Config erneut anwenden,
  DB-Restore, Tunnel-Neuaufbau.
- **Kosten:** ElevenLabs ca. 0,08–0,10 USD/min, Rufnummer/Provider ca. 1–10 EUR/Monat.
  Firecrawl, Supabase und n8n verursachen keine Lizenzkosten. Preise in Phase 0 prüfen.

## 9. Recht und Datenschutz

- **EU AI Act Art. 50:** KI-Offenlegung ist seit 08/2026 Pflicht; der Agent sagt
  in der Begrüßung, dass er ein KI-Assistent ist.
- **DSGVO:** Rufnummer, Transkript und Rückrufnotiz sind personenbezogen.
  Zweckbindung, Löschfrist (Vorschlag 30 Tage), Löschprozess und Auskunftsprozess
  dokumentieren. Aufzeichnung standardmäßig aus; nur mit ausdrücklicher
  Einwilligung aktivieren.
- **Auftragsverarbeitung:** AVV/DPA mit ElevenLabs und dem Telefonieprovider;
  EU-Datenresidenz und Drittlandtransfer prüfen und dokumentieren.
- **Eigener Shop:** Crawling der eigenen öffentlichen Seiten, `robots.txt`
  respektieren, Rate-Limit, kein Personenbezug.
- **Keine** besonderen Datenkategorien; der Agent nimmt keine Bestellungen oder
  Zahlungen entgegen.

## 10. Phasen

| # | Phase | Ergebnis | Prüfung |
|---|---|---|---|
| 0 | Discovery | Shop-URL, Sitemap, JSON-LD-Check, SIP-Provider, Tunnel-Domain, Host-Kapazität, DSGVO-Entscheidungen | Stichprobe von 3 Produktseiten mit vollständigem JSON-LD |
| 1 | Repo + Installer-Skelett | `telefonagent-proxmox/` mit Ordnern, `.env.example`, README | `shellcheck`, Trockenlauf |
| 2 | DB-LXC + Schema | Supabase minimal läuft, Migrationen, Testdaten | `psql`-Smoke-Test, Studio erreichbar |
| 3 | Crawler-LXC + Firecrawl | Firecrawl läuft, Test-Crawl von 10 Seiten | 10/10 Seiten, JSON-LD gefunden |
| 4 | n8n-Crawl-Workflow | vollständiger Crawl, Upsert, `crawl_runs` | 2 Läufe hintereinander ohne Duplikate |
| 5 | Suche + Webhook + Tunnel | SQL-Funktion, 5 Endpunkte, Auth | Contract-Tests per `curl`, 401 ohne Secret |
| 6 | ElevenLabs-Agent | Prompt, Tools, Stimme, Config-Skript | 20 Simulate-Gespräche |
| 7 | SIP-Trunk + Nummer | Nummer importiert, Agent zugewiesen | 5 echte Testanrufe |
| 8 | Härtung | Backups, Monitoring, Runbook, Rate-Limits | Restore-Test, Alarm-Test |
| 9 | Eval + Go-live | 20 Goldfragen, Latenzmessung, Abnahme | alle Kriterien aus 11 |

### 10.1 Meilensteine

Der Umsetzungsplan wird in vier unabhängig abnehmbare Meilensteine geteilt:

- **M1 Wissensbasis:** Phase 1–4 (Repo, DB, Crawler, Crawl-Workflow).
  Ergebnis: Produkte stehen aktuell und idempotent in Supabase.
- **M2 Live-Abfrage:** Phase 5 (Suche, Webhook, Tunnel).
  Ergebnis: `curl`-Test liefert korrekte Treffer, Auth greift.
- **M3 Telefonie:** Phase 6–7 (Agent, SIP, echte Anrufe).
  Ergebnis: Anrufer bekommt korrekte Produktantworten am Telefon.
- **M4 Härtung/Go-live:** Phase 8–9 (Backups, Monitoring, Eval).
  Ergebnis: alle Abnahmekriterien erfüllt, Betrieb dokumentiert.

## 11. Abnahmekriterien

- **Crawl:** ≥ 95 % der Sitemap-Produkt-URLs verarbeitet, 0 doppelte SKUs,
  zweiter Lauf ohne Duplikate, Laufzeit < 30 min, Alarm bei > 20 % Rückgang.
- **Suche:** p95 < 300 ms, mindestens 80 % Top-1-Treffer bei 20 Goldfragen.
- **Agent:** 100 % KI-Offenlegung, keine erfundenen Preise in 20 Tests,
  Webhook-Tool p95 < 500 ms (siehe 3.2) und im Gespräch wahrgenommene
  Tool-Antwort < 1,5 s, Handoff funktioniert, unbekannte Produkte werden
  ehrlich verneint.
- **Sicherheit:** Webhook ohne Secret → 401, Supabase und n8n-UI nicht öffentlich,
  Firecrawl nicht öffentlich.
- **Betrieb:** Restore aus Backup verifiziert, Crawl-Fehler löst Alarm aus.

## 12. Risiken und Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| Shop blockiert Crawler / Bot-Schutz | Eigene Crawler-IP freigeben, Rate-Limit senken, notfalls Produkt-Feed als Fallback |
| Kein oder unvollständiges JSON-LD | CSS-Selektor-Fallback, Alarm bei fehlenden Feldern, lokales Ollama nur als letzter Ausweg |
| SIP-Provider unterstützt kein statisches Routing | Provider wechseln (Telnyx dokumentiert) oder lokale Asterisk davor |
| Tunnel/ElevenLabs nicht erreichbar | Agent sagt festen Fallback-Satz, bietet Rückruf an; Provider-Failover auf menschliche Nummer |
| Latenz zu hoch | schnelleres LLM/TTS, Webhook entschlacken, Tool-Antworten auf max. 5 Treffer begrenzen |
| Kosten laufen weg | Minuten-Budget in ElevenLabs, monatlicher Kostenbericht, Alarm |
| Rechts-/DSGVO-Lücke | Offenlegung, Aufzeichnung aus, AVV, Löschfrist, dokumentierte Prüfung |

## 13. Offene Punkte für Phase 0

1. Genaue Shop-URL und Shop-System (WooCommerce, Shopware, Shopify, JTL …).
2. Vorhandene `sitemap.xml` und JSON-LD-Qualität (Stichprobe).
3. SIP-Provider und Rufnummer; Unterstützung für statisches Routing.
4. Domain für den Cloudflare Tunnel (oder alternativer Reverse Proxy).
5. Freie Ressourcen auf dem Proxmox-Host.
6. ElevenLabs-Plan, Wunschstimme, Minutenbudget.
7. Aufzeichnung: aus (Default) oder mit Einwilligung?
8. Aufbewahrungsfrist für Transkripte und Rückrufnotizen.
9. Zielrufnummer für menschliche Übergabe.
