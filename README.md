# n8n Workflows Showcase

> Cuatro workflows de produccion construidos con n8n, IA y APIs externas. Cada uno resuelve un problema concreto de e-commerce / atencion al cliente / generacion de demanda y se publica con arquitectura documentada, SQL, ejemplos curl y coleccion Postman.

Los workflows estan **construidos desde cero como demos generalizadas** — no son codigo de proyectos bajo contrato. Las tiendas y clientes mencionados (ACME Store, ACME Corp, Bella Studio) son ficticios; los datos son sinteticos.

**v1.0.0 — Initial public release. 4 workflows production-grade.**

---

## Workflows

### 🛒 [E-commerce Product Search Bot](./workflows/e-commerce-product-search-bot)

Chatbot de busqueda de productos para WooCommerce con dual-LLM y post-procesador anti-hallucination de 4 etapas.

- **16 nodos** (12 funcionales + 4 sticky notes). 1 trigger (webhook).
- **Dual-LLM**: `LLM_PROVIDER=openai|anthropic`. OpenAI default `gpt-4o-mini`, Anthropic `claude-sonnet-4-5`.
- **Anti-hallucination post-processor**: extractor de IDs reales → cross-check vs Store API → drift detector precio/stock (>5%) → scoring + sanitizacion (threshold 0.3).
- **Bilingual**: `BOT_LANG=en|es`.
- **Telemetria**: Postgres `bot_telemetry` + rollup view `bot_telemetry_health`.
- 3 curl examples + Postman collection con 12 tests automatizados.

**Stack:** n8n · OpenAI GPT-4o-mini · Anthropic Claude Sonnet · WooCommerce Store API · Postgres

---

### 💬 [WhatsApp Booking System](./workflows/whatsapp-booking-system)

Sistema de reservas conversacional por WhatsApp con state machine persistido, reserva race-safe y manejo de timezone correcto.

- **25 nodos** (20 funcionales + 5 sticky notes). 3 triggers (2 webhooks + 1 cron de recordatorios).
- **State machine** en Postgres `booking_sessions` (key `business_id:phone`, JSONB context, TTL 30min). Estados: `IDLE → BOOKING_SERVICE → BOOKING_DATE → BOOKING_TIME → BOOKING_CONFIRM → BOOKED`.
- **Reserva race-safe**: `INSERT ... ON CONFLICT DO NOTHING RETURNING` sobre indice UNIQUE parcial `(service_id, start_at) WHERE status IN ('PENDING','CONFIRMED')` — two-phase commit lite.
- **Idempotencia** via `message_idempotency` table — duplicados short-circuit antes de cualquier side-effect.
- **Timezone-correct**: TIMESTAMPTZ UTC en storage, `BUSINESS_TIMEZONE` env para contexto LLM + Google Calendar + display via `Intl.DateTimeFormat`.
- Mismo dual-LLM + `BOT_LANG=en|es` que workflow 1.
- 4 curl examples + Postman collection con 12 tests + continuidad de sesion cross-request.

**Stack:** n8n · Evolution API (WhatsApp) · OpenAI / Anthropic · Google Calendar · Postgres

---

### 🔄 [Multi-store Inventory Sync](./workflows/multi-store-inventory-sync)

Sincronizacion bidireccional WooCommerce ↔ Odoo con source-of-truth por field, idempotencia cross-system, circuit breaker per-target, audit trail completo y reconciliacion nightly.

- **42 nodos** (36 funcionales + 6 sticky notes). **3 triggers en un archivo**: webhook WC, webhook Odoo, cron 03:00.
- **Source-of-truth matrix**: Odoo para stock + SKU, WooCommerce para precio + contenido. Eventos non-SoT logeados como `ignored_not_sot`, nunca propagados.
- **Idempotencia cross-system**: UNIQUE compuesto `(source_system, source_event_id)` — WC delivery IDs y Odoo UUIDs coexisten sin colision.
- **Circuit breaker per-target**: `CLOSED → OPEN → HALF_OPEN → CLOSED`. Target OPEN → evento cola en `sync_queue` + HTTP 202.
- **CTE atomico**: UPDATE `sync_audit` + UPDATE `system_health` en una sola sentencia SQL — sin race entre observacion y decision.
- **Reconciliacion nightly**: fetch all SKUs ambos lados, compute drift, persist `reconciliation_runs` + `reconciliation_drift_items`, alert proporcional a drift count.
- 7 tablas SQL + seed. 6 curl examples + Postman con 13 tests (todos los 4 execution paths: applied, ignored, dup, queued).

**Stack:** n8n · WooCommerce REST API · Odoo JSON-RPC · Postgres

---

### 📞 [Voice AI Lead Qualifier](./workflows/voice-ai-lead-qualifier)

Calificacion automatica de leads via llamadas salientes con voz IA. Inbound webhook → DNC check + compliance horario TZ-aware → llamada Retell AI → analisis BANT por LLM → ruteo hot/warm/cold.

- **43 nodos** (35 funcionales + 8 sticky notes). 3 triggers (2 webhooks + 1 cron drainer).
- **Async voice flow**: Subflow A dispara la llamada y responde en <500ms; Retell llama de vuelta a Subflow B cuando termina.
- **BANT con structured output**: schema JSON forzado (OpenAI response_format / Anthropic tool_use). Score 0-10, intent hot/warm/cold/disqualified, next_action reconciliado con reglas deterministicas.
- **Dedup de 2 capas**: inbound por UNIQUE `email` en `leads`; post-call por PRIMARY KEY `retell_call_id` en `processed_calls`.
- **Compliance TZ-aware**: `Intl.DateTimeFormat` con IANA timezone, rango horario configurable, next-slot calculado para out-of-hours.
- **Safe defaults**: `try/catch` en Normalize node, fallback BANT con `intent='warm'` para no descartar leads silenciosamente.
- **Backoff exponencial**: `POWER(2, retry_count) * 15 min` en drainer, GAVE_UP a los 10 intentos.
- **Cost tracking**: `call_costs` con costo Retell + costo analisis LLM (estimado por tokens).
- 7 tablas SQL + triggers + seed DNC. 6 curl examples + Postman con 12 tests.

**Stack:** n8n · Retell AI · OpenAI GPT-4o-mini / Anthropic Claude Sonnet · Google Calendar · Airtable · Postgres

---

## Como usar

Cada subcarpeta es independiente:

```
workflow-name/
├── workflow.json          # importar via n8n UI → Import from File
├── README.md              # problema, arquitectura, decisiones, replica
├── .env.example           # copiar a .env.local y completar
├── sql/                   # schema + seed, correr con psql $DATABASE_URL -f ...
└── docs/
    ├── architecture.md    # diagramas, datos por nodo, failure modes
    ├── curl-examples.md   # escenarios end-to-end sin Postman
    └── postman-collection.json
```

## Decisiones transversales

- **n8n self-hosted**, no n8n Cloud. Control total sobre datos, ejecuciones y costos.
- **Proxy materialization**: `JSON.parse(JSON.stringify(x))` en Code nodes con referencias cruzadas para evitar timeout del Task Runner con objetos anidados (JSONB, arrays de servicios).
- **Switch v3**: siempre con `conditions.options` completo (`caseSensitive`, `leftValue`, `typeValidation`, `version`) — sin esto tira `Cannot read properties of undefined (reading 'caseSensitive')`.
- **Idempotencia primero**: todo webhook comienza con un INSERT idempotente antes de cualquier side-effect.
- **Dual-LLM**: `LLM_PROVIDER=openai|anthropic` en todos los workflows que usan IA. Sin reiniciar n8n, cambio de provider cambiando la variable de entorno.
- **Postgres para estado**, no RAM. Estado conversacional, circuit breaker, queues, audit trails — todo en SQL para sobrevivir a restarts y permitir queries de debugging.

## Licencia

MIT — ver [LICENSE](./LICENSE).

## Autor

**Luis Molina Reinoso** — AI & Automation Engineer  
San Miguel de Tucuman, Argentina

[LinkedIn](https://linkedin.com/in/luis-molina-171190) · [GitHub](https://github.com/luis171190)

Disponible para proyectos en: integraciones n8n, chatbots WhatsApp, voice AI, sincronizaciones multi-sistema, dashboards Power BI / Tableau.
