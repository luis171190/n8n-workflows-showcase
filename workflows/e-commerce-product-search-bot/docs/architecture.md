# Arquitectura — e-commerce-product-search-bot

## Diagrama de flujo

```
┌──────────────────────┐
│  POST /webhook/      │
│  acme-search         │  ← Cliente envía { session_id?, query, max_results? }
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Validate &          │  ← Normaliza payload, clasifica intención (keywords),
│  Classify            │     detecta marca, parsea price hints en lenguaje natural.
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  WooCommerce Store   │  ← GET {STORE_BASE_URL}/wp-json/wc/store/products
│  API (search)        │     Con per_page = max_results * 3 para tener margen
│                      │     después del pre-filter.
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Pre-filter & Rank   │  ← Filtra por stock + price_min/max.
│                      │     Si hay marca detectada, prioriza por nombre.
│                      │     Compacta a estructura mínima (id, name, price,
│                      │     in_stock, description, image, permalink).
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Switch: LLM         │  ← $env.LLM_PROVIDER decide rama.
│  Provider            │     openai → rama 0   anthropic → rama 1
└────┬─────────────┬───┘
     │             │
     ▼             ▼
┌─────────┐   ┌──────────┐
│ OpenAI  │   │ Anthropic│  ← Mismo system prompt en ambos. Pide JSON con
│         │   │ (Claude) │     mentioned_ids[] y reply_text.
└────┬────┘   └────┬─────┘
     │             │
     └──────┬──────┘
            ▼
┌──────────────────────┐
│  Normalize LLM       │  ← Extrae content según provider, parsea JSON,
│                      │     normaliza a { mentioned_ids, reply_text }.
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Anti-hallucination  │  ← (1) Real-ID extractor
│  Post-Processor      │     (2) Cross-check vs IDs reales
│                      │     (3) Stock & price verifier
│                      │     (4) Hallucination score + sanitization
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Telemetry           │  ← INSERT en bot_telemetry (Postgres).
│  (Postgres)          │     continueOnFail: true (no bloquea respuesta).
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Format Response     │  ← Calcula latency_ms, ensambla payload final.
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Respond to Webhook  │  → 200 { session_id, reply, products[], meta{} }
└──────────────────────┘
```

## Datos que viajan entre nodos

| Nodo                    | Output principal (campos clave)                                    |
|-------------------------|--------------------------------------------------------------------|
| Webhook                 | `body` con la request                                              |
| Validate & Classify     | `session_id, query, classification{type, brand, price_min/max, intent}, started_at, max_results` |
| Store API: Search       | Array de productos WooCommerce (formato Store API)                |
| Pre-filter & Rank       | + `real_products[]`, `real_count`, `no_results`                    |
| Switch                  | (passthrough, ramifica)                                            |
| OpenAI / Anthropic      | Response raw del provider                                          |
| Normalize LLM           | + `llm_provider, llm_parsed{mentioned_ids, reply_text}, parse_error`|
| Anti-hallucination      | + `final_reply, validation{hallucination_score, sanitized, ...}`   |
| Telemetry               | (passthrough, ejecuta INSERT)                                      |
| Format Response         | `{ session_id, reply, products[], meta{...} }`                     |
| Respond                 | (devuelve el body anterior con HTTP 200)                           |

## Decisiones arquitectónicas resumidas

1. **Webhook + responseNode** (no respuesta automática) — permite ensamblar la respuesta después de telemetría.
2. **Switch v3 con conditions completos** (`caseSensitive, leftValue, typeValidation, version`) — evita el bug *"Cannot read properties of undefined (reading 'caseSensitive')"* que aparece si faltan campos.
3. **`JSON.parse(JSON.stringify(...))` en Code nodes con cross-references** — materializa proxies de n8n y evita timeout del Task Runner cuando los datos cruzados tienen objetos anidados (productos de WooCommerce traen prices, images, attributes nested).
4. **Telemetría con `continueOnFail: true`** — si el INSERT falla, la respuesta al cliente sigue saliendo.
5. **`Math.min(per_page, 10)`** en Validate — protege la API y el LLM de queries con `max_results: 9999`.
6. **`per_page = max_results * 3`** en Store API — pedimos triple para tener margen tras pre-filter (out-of-stock, fuera de precio).
