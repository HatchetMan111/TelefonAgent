# Agent-Eval ausführen

Voraussetzungen: `.env` enthält `ELEVENLABS_API_KEY` und
`ELEVENLABS_AGENT_ID`; der Agent aus Task 11 ist angewendet; der Tunnel ist
erreichbar, weil die Test-Tools die echten Webhooks aufrufen.

```bash
node scripts/eval-agent.mjs
```

Ablauf: Das Skript legt für jeden Fall in `tests/eval-cases.json` einen
temporären Simulationstest an, startet alle Tests zusammen und pollt den
Lauf, bis jeder Test `passed`, `failed` oder `cancelled` ist.

Ergebnis: `eval-report.json` mit `id`, `status`, `ok`, `rationale`.
Exit-Code 0 nur, wenn alle Fälle bestehen. Bei Fehlschlägen die `rationale` lesen,
Prompt/Tools korrigieren, Task 11 erneut anwenden und das Skript erneut
starten.
