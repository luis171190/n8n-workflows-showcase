# Changelog

All notable changes to this repository will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- `whatsapp-booking-system` — n8n + Evolution API + Google Calendar
- `multi-store-inventory-sync` — WooCommerce <-> Odoo bidirectional sync
- `voice-ai-lead-qualifier` — Retell AI + n8n outbound qualifier

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
