# ShopAgent – lokaler KI-Telefonagent

Eingehender Telefonagent für den eigenen Shop. n8n + Firecrawl crawlen die
öffentliche Shop-Website nächtlich nach Supabase; ElevenLabs beantwortet Anrufe
über fünf Webhook-Tools. Nur ElevenLabs und der SIP-Trunk sind extern.

- Spec: `docs/superpowers/specs/2026-10-28-telefonagent-design.md`
- Plan: `docs/superpowers/plans/2026-10-28-telefonagent-implementation.md`
- Dienste: `shopagent-db`, `shopagent-n8n`, `shopagent-crawler` (Proxmox LXC)
- Installation: `install/shopagent.sh --role db|n8n|crawler|all`
- Health: `scripts/healthcheck.sh`
