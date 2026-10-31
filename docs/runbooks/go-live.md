# Go-live-Checkliste

Diese Checkliste wird vor dem Produktivstart vollständig abgearbeitet.
Punkte, die eine laufende Umgebung (Shop, ElevenLabs, Proxmox, Tunnel)
brauchen, sind **blockierte Live-Checkpoints**: Sie können in einem
Repo-Checkout ohne Infrastruktur nicht erfüllt und nicht ersetzt werden.

## Goldfragen: Platzhalter, nicht finale Abnahme

`tests/eval-cases.json` enthält 7 Basisfälle plus 20 Goldfälle
(`gold-01` bis `gold-20`). Die 20 Goldfälle sind **repräsentative
Platzhalter**, abgeleitet aus dem geseedeten Katalog (`REGEN-42`,
Regenschuh/Regenjacke/Teebeutel) und den Info-Themen (Öffnungszeiten,
Versand, Lieferzeit, Rückgabe, Zahlung, Kontakt). Echte Kundenfragen lagen
zum Erstellungszeitpunkt nicht vor.

**Vor dem Launch** die 20 Platzhalter durch echte Kundenfragen ersetzen und
den Eval-Lauf erneut ausführen. Ein `27/27`-Ergebnis auf Platzhaltern ist
**kein** Abnahmebeleg. Alle Live-Checkpoints unten bleiben unabhängig davon
verpflichtend.

## Checkliste

- [ ] Crawl: ≥95 % der Sitemap-URLs, 0 doppelte SKUs, 2. Lauf ohne Duplikate, <30 min
- [ ] Suche: p95 <300 ms, ≥80 % Top-1 bei 20 Goldfragen
- [ ] Agent: alle Eval-Fälle grün (7 Basis + 20 Goldfragen), KI-Offenlegung hörbar, keine erfundenen Preise
- [ ] Telefonie: 5 echte Anrufe, Übergabe an Menschen funktioniert
- [ ] Sicherheit: Webhook ohne Secret 401, Supabase/n8n-UI/Firecrawl nicht öffentlich
- [ ] Backup: Restore getestet, Alarm getestet
- [ ] Recht: KI-Offenlegung, Aufzeichnung aus, Callback-Löschfrist 30 Tage per Backup-Purge implementiert
- [ ] Runbooks vorhanden: crawl, tunnel, sip, eval, backup, operations

## Wie die Punkte belegt werden

| Punkt | Beleg | Runbook |
|---|---|---|
| Crawl-Metriken | `crawl_runs` letzter und vorletzter Lauf: `urls_fetched`, `products_upserted`, `products_deactivated`, Dauer; Sitemap-URL-Zahl aus `scripts/sitemap-urls.mjs` | `docs/runbooks/crawl.md` |
| Suchlatenz und Top-1 | `EXPLAIN ANALYZE` bzw. Lasttest gegen `search_products`; Trefferqualität aus den 20 Goldfragen | `docs/runbooks/crawl.md`, `docs/runbooks/eval.md` |
| Agent-Eval | `node scripts/eval-agent.mjs` mit Exit-Code 0; `eval-report.json` archivieren | `docs/runbooks/eval.md` |
| KI-Offenlegung und Preise | Baseline-Fall `ai` grün; Preisantworten nennen `as_of` und „Preis im Shop ist verbindlich“ | `elevenlabs/prompt.md` |
| Telefonie | 5 dokumentierte echte Anrufe inkl. mindestens einer Übergabe an einen Menschen | `docs/runbooks/sip.md` |
| Sicherheit | `tests/api-contract.sh` `OK auth`; von außen kein Zugriff auf Supabase, n8n-UI, Firecrawl | `docs/runbooks/tunnel.md` |
| Backup und Alarm | Scratch-Restore erfolgreich; Testalarm im ntfy-Topic angekommen | `docs/runbooks/backup.md`, `docs/runbooks/operations.md` |
| Recht | Prompt enthält KI-Offenlegung; Aufzeichnung aus; Callback-Löschfrist 30 Tage per Backup-Purge implementiert und im Runbook dokumentiert | `elevenlabs/prompt.md`, `scripts/backup.sh`, `docs/runbooks/operations.md` |

## Blockierte Live-Checkpoints

In dieser Umgebung gibt es keinen echten Shop, kein ElevenLabs-Konto und
keine Proxmox-/n8n-/Postgres-Instanz. Daher sind nicht ausführbar und
**nicht als erledigt zu markieren**:

- der 27/27-Eval-Lauf gegen den echten Agenten,
- die Crawl-Metriken aus echten Läufen,
- die Suchlatenz-/Top-1-Messung,
- die 5 echten Anrufe inkl. menschlicher Übergabe,
- der Restore- und Alarm-Test,
- die externe Sicherheitsprüfung über den Tunnel.

Jeder dieser Punkte wird beim ersten echten Lauf mit dem oben genannten Beleg
abgehakt. Bis dahin bleibt die Abnahme offen.
