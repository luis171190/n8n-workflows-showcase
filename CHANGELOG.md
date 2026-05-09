# Changelog

All notable changes to this repository will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- `voice-ai-lead-qualifier` — Retell AI + n8n outbound qualifier

## [0.3.0] - 2026-05-08

### Added
- `multi-store-inventory-sync` — bidirectional inventory sync between WooCommerce and Odoo with source-of-truth-per-field, cross-system idempotency, circuit breaker per target, full audit trail, and nightly reconciliation.
  - 42-node workflow (36 functional + 6 sticky notes) with **three triggers in one file**: webhook from WC, webhook from Odoo, daily reconciliation cron.
  - **Source-of-truth matrix**: Odoo for stock + SKU, WooCommerce for price + content. Non-SoT events are filtered with audit log entry `status='ignored_not_sot'` and never propagate.
  - **Cross-system idempotency** via compound UNIQUE `(source_system, source_event_id)` on `sync_events` — WC delivery IDs and Odoo event UUIDs share the table without colliding.
  - **Circuit breaker per target** with state machine `CLOSED → OPEN → HALF_OPEN → CLOSED`. Pre-flight check before every outbound HTTP. OPEN target → events queued in `sync_queue` with HTTP 202 acknowledgement.
  - **Atomic audit + health update** — single SQL CTE updates `sync_audit` row and `system_health` counters in one statement, no race between observation and decision.
  - **Daily reconciliation** at 03:00 — fetches all SKUs from both sides, computes drift (`stock_drift`, `price_drift`, `missing_in_wc`, `missing_in_odoo`), persists to `reconciliation_runs` + `reconciliation_drift_items`, optionally auto-fixes (env-controlled), surfaces alerts.
  - 7 SQL tables + seed for `system_health` (WC + Odoo).
  - 6 curl examples + Postman collection with 13 automated tests covering all four execution paths (applied, ignored, dup, queued).
  - Architecture documented with flow diagram, circuit breaker state machine, per-node data table, and failure-mode table.

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
