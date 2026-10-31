# Runbook: Backup und Restore

## Zweck

`scripts/backup.sh` erstellt naechtlich einen logischen Dump der Datenbanken
`postgres` (ShopAgent-Schema: `products`, `pages`, `crawl_runs`) und `n8n`.
Die Dumps liegen unter `BACKUP_DIR` (Default `/var/backups/shopagent`), ein
Unterordner pro Lauf im Format `JJJJ-MM-TT-HHMM`:

- `postgres.dump` – `pg_dump -Fc` der Datenbank `postgres`
- `n8n.dump` – `pg_dump -Fc` der Datenbank `n8n`
- `SHA256SUMS` – Pruefsummen beider Dumps

Der Lauf startet taeglich um **04:30** ueber `shopagent-backup.timer`
(`Persistent=true`, ein verpasster Lauf wird nachgeholt). Laeufe, deren
Unterordner aelter als `BACKUP_RETAIN_DAYS` (Default 14) Tage ist, werden
geloescht. Das Backup laeuft im DB-LXC `shopagent-db` als Systemdienst.

## Speicherort und Disaster Recovery

`BACKUP_DIR` liegt per Default unter `/var/backups/shopagent` **im DB-LXC**.
Dieser container-lokale Default ist **kein Disaster Recovery**: Geht der LXC
oder sein Storage verloren, sind auch die Dumps weg. Fuer echte
Wiederherstellbarkeit muss `BACKUP_DIR` auf Proxmox-/PBS-gestuetztem Storage
liegen und als Bind-Mount in den DB-LXC eingebunden sein, **oder** nach jedem
Lauf muss ein Kopierschritt die Dumps vom Container auf externen
Proxmox-/PBS-Storage bringen (z. B. per Cron auf dem Proxmox-Host). Ohne einen
dieser beiden Schritte schuetzt das Backup nur vor Datenfehlern, nicht vor
Verlust des Containers oder Hosts.

## Voraussetzungen

- `.env` liegt unter `/opt/shopagent/.env` (Modus `600`) und setzt
  `DB_PORT`, `DB_ADMIN_USER`, `DB_ADMIN_PASSWORD`, `BACKUP_DIR`,
  `BACKUP_RETAIN_DAYS`.
- `pg_dump`, `pg_restore`, `psql` und `sha256sum` sind installiert.
- Der Dienst greift ueber `127.0.0.1` auf Postgres zu; Passwort kommt aus
  `DB_ADMIN_PASSWORD`.

## Manuelles Backup

```bash
/opt/shopagent/scripts/backup.sh
```

Ausgabe: `Backup: /var/backups/shopagent/JJJJ-MM-TT-HHMM`.
Exit-Code ungleich 0 bedeutet, dass ein `pg_dump` fehlgeschlagen ist; dann
keinen Restore mit diesem Ordner versuchen.

## Restore in eine Scratch-DB

Der Restore schreibt **nie** in `postgres` oder `n8n`, sondern nur in eine
separate Scratch-Datenbank:

```bash
/opt/shopagent/scripts/restore.sh /var/backups/shopagent/JJJJ-MM-TT-HHMM/postgres.dump
```

Optional als zweites Argument der Scratch-Name (Default `restore_test`).
Erlaubt sind nur `^[a-z_][a-z0-9_]*$`; `postgres`, `n8n` und Namen mit
Praefix `template` werden abgelehnt. Eine bestehende Scratch-DB wird vorher
geloescht.

Liegt neben dem Dump eine `SHA256SUMS`, wird die Pruefsumme vor dem Restore
geprueft und bei Abweichung abgebrochen. Fehlt sie, laeuft der Restore mit
einer Warnung weiter.

Erwartete Ausgabe am Ende:

```
products=<n>
pages=<n>
```

Die Werte muessen den Produktivzahlen entsprechen (Vergleich z. B. mit
`select count(*) from products;` auf der Produktiv-DB).

## Dienst installieren

Im DB-LXC:

```bash
chmod +x scripts/backup.sh scripts/restore.sh
DB_CT="$(pct list | awk '/shopagent-db/{print $1}')"
pct exec "$DB_CT" -- mkdir -p /opt/shopagent/scripts /var/backups/shopagent
pct push "$DB_CT" scripts/backup.sh /opt/shopagent/scripts/backup.sh
pct push "$DB_CT" scripts/restore.sh /opt/shopagent/scripts/restore.sh
pct push "$DB_CT" .env /opt/shopagent/.env
pct exec "$DB_CT" -- chmod 600 /opt/shopagent/.env
pct exec "$DB_CT" -- chmod +x /opt/shopagent/scripts/backup.sh /opt/shopagent/scripts/restore.sh
pct push "$DB_CT" systemd/shopagent-backup.service /etc/systemd/system/shopagent-backup.service
pct push "$DB_CT" systemd/shopagent-backup.timer /etc/systemd/system/shopagent-backup.timer
pct exec "$DB_CT" -- bash -c 'systemctl daemon-reload && systemctl enable --now shopagent-backup.timer'
```

Status und naechster Lauf:

```bash
systemctl status shopagent-backup.timer
systemctl list-timers shopagent-backup.timer
journalctl -u shopagent-backup.service -n 50
```

## Fehlerbehebung

- **`pg_dump` schlaegt fehl**: Postgres laeuft nicht oder `DB_ADMIN_PASSWORD`
  ist falsch; `pct exec "$DB_CT" -- systemctl status postgresql`.
- **Keine neuen Ordner**: Timer-Status pruefen, danach manuell starten mit
  `systemctl start shopagent-backup.service`.
- **Retention loescht zu viel**: `BACKUP_RETAIN_DAYS` in `.env` pruefen; das
  Skript loescht nur Unterordner von `BACKUP_DIR`, keine Dateien.
- **Restore bricht mit Pruefsummenfehler ab**: Dump ist beschaedigt oder
  wurde nachtraeglich geaendert; einen aelteren Backup-Ordner verwenden.
