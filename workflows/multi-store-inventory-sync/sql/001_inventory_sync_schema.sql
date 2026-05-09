-- ============================================================================
-- ACME Multi-channel Retailer — inventory sync schema.
-- Tables: sync_events, sync_audit, sync_queue, system_health,
--         reconciliation_runs, reconciliation_drift_items, alerts.
-- All timestamps in TIMESTAMPTZ (UTC).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- sync_events: every inbound webhook lands here. Compound UNIQUE
-- (source_system, source_event_id) makes the dedup atomic and cross-system.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_events (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_system    TEXT NOT NULL CHECK (source_system IN ('woocommerce', 'odoo')),
    source_event_id  TEXT NOT NULL,
    raw_payload      JSONB NOT NULL,
    received_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_system, source_event_id)
);

CREATE INDEX IF NOT EXISTS idx_sync_events_received_at ON sync_events (received_at DESC);

-- ----------------------------------------------------------------------------
-- sync_audit: every action taken on a sync_event. Append-only log.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_audit (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sync_event_id    UUID NOT NULL REFERENCES sync_events(id),
    source_system    TEXT NOT NULL,
    target_system    TEXT NOT NULL,
    sku              TEXT,
    field            TEXT,
    action           TEXT,
    status           TEXT NOT NULL CHECK (status IN ('received','ignored_not_sot','queued','applied','failed')),
    before_value     JSONB,
    after_value      JSONB,
    error_message    TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sync_audit_event_id ON sync_audit (sync_event_id);
CREATE INDEX IF NOT EXISTS idx_sync_audit_sku      ON sync_audit (sku, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_audit_status   ON sync_audit (status, created_at DESC);

-- ----------------------------------------------------------------------------
-- sync_queue: events waiting because the target system was OPEN (down).
-- A drainer cron processes this once health returns to CLOSED.
-- UNIQUE (sync_event_id, target_system) prevents accidental double-queue.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_queue (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sync_event_id   UUID NOT NULL REFERENCES sync_events(id),
    target_system   TEXT NOT NULL,
    payload         JSONB NOT NULL,
    status          TEXT NOT NULL DEFAULT 'WAITING_FOR_TARGET'
                     CHECK (status IN ('WAITING_FOR_TARGET','RETRY','APPLIED','GAVE_UP')),
    retry_count     INT NOT NULL DEFAULT 0,
    last_attempt_at TIMESTAMPTZ,
    last_error      TEXT,
    scheduled_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (sync_event_id, target_system)
);

CREATE INDEX IF NOT EXISTS idx_sync_queue_status_target ON sync_queue (status, target_system, scheduled_at);

-- ----------------------------------------------------------------------------
-- system_health: circuit breaker state per external system.
-- One row per (system_name).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS system_health (
    system_name           TEXT PRIMARY KEY,
    state                 TEXT NOT NULL DEFAULT 'CLOSED'
                            CHECK (state IN ('CLOSED','OPEN','HALF_OPEN')),
    consecutive_failures  INT  NOT NULL DEFAULT 0,
    opened_at             TIMESTAMPTZ,
    last_check_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO system_health (system_name) VALUES ('woocommerce'), ('odoo')
ON CONFLICT (system_name) DO NOTHING;

-- Half-open transition: a separate cron runs every 30s and promotes OPEN systems
-- to HALF_OPEN once 60s have passed since opened_at:
--
--   UPDATE system_health
--   SET    state = 'HALF_OPEN'
--   WHERE  state = 'OPEN' AND opened_at < NOW() - INTERVAL '60 seconds';

-- ----------------------------------------------------------------------------
-- reconciliation_runs / reconciliation_drift_items: nightly drift report.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reconciliation_runs (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at          TIMESTAMPTZ NOT NULL,
    finished_at         TIMESTAMPTZ NOT NULL,
    total_skus_checked  INT NOT NULL,
    stock_drift_count   INT NOT NULL DEFAULT 0,
    price_drift_count   INT NOT NULL DEFAULT 0,
    missing_count       INT NOT NULL DEFAULT 0,
    auto_fix            BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_recon_runs_started_at ON reconciliation_runs (started_at DESC);

CREATE TABLE IF NOT EXISTS reconciliation_drift_items (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id    UUID NOT NULL REFERENCES reconciliation_runs(id) ON DELETE CASCADE,
    sku       TEXT NOT NULL,
    kind      TEXT NOT NULL CHECK (kind IN ('stock_drift','price_drift','missing_in_wc','missing_in_odoo')),
    details   JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_drift_items_run_id ON reconciliation_drift_items (run_id);
CREATE INDEX IF NOT EXISTS idx_drift_items_sku    ON reconciliation_drift_items (sku);

-- ----------------------------------------------------------------------------
-- alerts: surfaces critical events (drift, prolonged OPEN circuit, etc.)
-- An external consumer (Slack notifier, email, PagerDuty) reads this.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alerts (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    severity     TEXT NOT NULL CHECK (severity IN ('info','warning','critical')),
    source       TEXT NOT NULL,
    message      TEXT NOT NULL,
    payload      JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    acknowledged BOOLEAN NOT NULL DEFAULT FALSE,
    acknowledged_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_alerts_unack ON alerts (acknowledged, severity, created_at DESC) WHERE acknowledged = FALSE;

-- ----------------------------------------------------------------------------
-- Sweepers (cron — examples)
-- ----------------------------------------------------------------------------
-- Promote OPEN systems to HALF_OPEN after 60s. Runs every 30s.
--   UPDATE system_health SET state='HALF_OPEN'
--   WHERE state='OPEN' AND opened_at < NOW() - INTERVAL '60 seconds';
--
-- Drop sync_events older than 30 days. Runs nightly.
--   DELETE FROM sync_events WHERE received_at < NOW() - INTERVAL '30 days';
--
-- Mark queued events that retried >10 times as GAVE_UP. Runs hourly.
--   UPDATE sync_queue SET status='GAVE_UP'
--   WHERE status IN ('WAITING_FOR_TARGET','RETRY') AND retry_count >= 10;
--
-- Drop reconciliation_runs older than 90 days (cascades to drift_items).
--   DELETE FROM reconciliation_runs WHERE started_at < NOW() - INTERVAL '90 days';
