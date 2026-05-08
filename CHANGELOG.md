# Changelog

All notable changes to this repository will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- `multi-store-inventory-sync` — WooCommerce <-> Odoo bidirectional sync
- `voice-ai-lead-qualifier` — Retell AI + n8n outbound qualifier

## [0.2.0] - 2026-05-08

### Added
- `whatsapp-booking-system` — conversational booking workflow over WhatsApp (Evolution API) with persistent state, race-safe slot reservation, idempotent webhook handling, and timezone-correct datetime handling.
  - 25-node workflow (20 functional + 5 sticky notes documenting the four key technical decisions).
  - **Conversational state machine** persisted in Postgres `booking_sessions` (key `business_id:phone`, JSONB context, 30-min TTL).
  - **Race-safe slot reservation** via `INSERT … ON CONFLICT DO NOTHING RETURNING` against a partial UNIQUE index on `(service_id, start_at) WHERE status IN ('PENDING','CONFIRMED')` — atomic two-phase commit lite (Insert PENDING → Calendar create → Mark CONFIRMED).
  - **Idempotent webhook intake** via `message_idempotency` table — duplicates short-circuit before any side-effect with HTTP 200.
  - **Timezone-correct** datetime handling: TIMESTAMPTZ UTC in storage, `BUSINESS_TIMEZONE` env for LLM context + Calendar event + user-facing display via `Intl.DateTimeFormat`.
  - Same dual-LLM provider switch as workflow 1 (`LLM_PROVIDER=openai|anthropic`).
  - Same `BOT_LANG=en|es` i18n.
  - 4 SQL tables + partial UNIQUE index + 4-service ACME Studio seed.
  - 4 curl examples (greeting → slot filling → confirm → idempotency replay) + Postman collection with 12 automated tests + cross-request session continuity.
  - Architecture documented with flow diagram, state-machine diagram, per-node data table, and failure modes table.

## [0.1.0] - 2026-05-08

### Added
- Initial release.
- `e-commerce-product-search-bot` — dual-LLM workflow (OpenAI / Anthropic) for WooCommerce product search with anti-hallucination post-processor.
  - 16-node workflow (12 functional + 4 sticky notes for in-canvas documentation).
  - Provider switching via `LLM_PROVIDER` env var (`openai` | `anthropic`).
    - OpenAI default model: `gpt-4o-mini`.
    - Anthropic default model: `claude-sonnet-4-5` (alternative: `claude-haiku-4-5-20251001`).
  - Bilingual responses via `BOT_LANG` env var (`en` default | `es`).
  - 4-stage anti-hallucination post-processor:
    1. Real-ID extractor.
    2. Cross-check against the Store API's actual ID set.
    3. Stock & price verifier (>5% drift detection).
    4. Hallucination scoring + sanitization (threshold 0.3).
  - Telemetry to Postgres (`bot_telemetry` table + `bot_telemetry_health` rollup view).
  - 3 curl examples + Postman collection with schema-level automated tests.
  - Architecture documented in ASCII diagram + per-node data table.
- Repository scaffold: root `README.md`, `LICENSE` (MIT), `.gitignore`.
