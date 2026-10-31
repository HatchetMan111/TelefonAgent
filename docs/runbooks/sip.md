# SIP-Trunk

1. Beim Provider einen SIP-Trunk mit statischem Routing bestellen
   (Telnyx ist dokumentiert; sipgate/Telekom nur, wenn statisches Routing möglich ist).
2. Inbound-Regel: Ziel `sip.rtc.elevenlabs.io`, Port 5060, Transport TLS.
3. Rufnummer im E.164-Format, identisch mit `ELEVENLABS_PHONE_NUMBER`
   (führendes `+` muss auf beiden Seiten gleich sein).
4. Provider-IP in `SIP_PROVIDER_IP` eintragen (für `allowed_addresses`).
5. Bei TLS: SRTP aktivieren; `media_encryption` bleibt `required`.
6. Testanruf: Nummer wählen, Begrüßung muss die KI-Offenlegung enthalten.

## Nummer importieren und zuweisen

`.env` laden und den Import zuerst als Dry-Run ansehen, dann anwenden:

```bash
set -a; source .env; set +a
node scripts/import-number.mjs --dry-run
node scripts/import-number.mjs
```

## Zuweisung prüfen

```bash
curl -s -H "xi-api-key: $ELEVENLABS_API_KEY" \
  https://api.elevenlabs.io/v1/convai/phone-numbers | jq '.phone_numbers[] | {phone_number, assigned_agent}'
```

Erwartet: Die Nummer zeigt mit `assigned_agent` auf `ELEVENLABS_AGENT_ID`.
