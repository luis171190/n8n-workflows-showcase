-- ============================================================================
-- ACME Studio booking schema.
-- Tables: services, bookings, booking_sessions, message_idempotency.
-- All timestamps in UTC (TIMESTAMPTZ). Display TZ is applied at the edge.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- services: catalog (in-demo it's hardcoded in the Code node, but a real install
-- would CRUD this table from an admin panel and the Build LLM Context node
-- would SELECT from it instead).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS services (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id      UUID NOT NULL,
    name             TEXT NOT NULL,
    duration_minutes INT  NOT NULL CHECK (duration_minutes > 0),
    price            NUMERIC(10,2),
    active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- bookings: confirmed appointments. UNIQUE constraint on (service_id, start_at)
-- WHERE status IN ('PENDING','CONFIRMED') is the optimistic lock that prevents
-- double-booking under race conditions.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bookings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id     UUID NOT NULL,
    service_id      UUID NOT NULL REFERENCES services(id),
    start_at        TIMESTAMPTZ NOT NULL,
    end_at          TIMESTAMPTZ NOT NULL CHECK (end_at > start_at),
    customer_phone  TEXT NOT NULL,
    customer_name   TEXT,
    status          TEXT NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','CONFIRMED','CANCELLED','EXPIRED')),
    google_event_id TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    cancelled_at    TIMESTAMPTZ
);

-- Partial UNIQUE index = the lock. Two concurrent INSERTs for the same slot:
-- one wins (gets the row back), the other gets DO NOTHING (returns 0 rows).
CREATE UNIQUE INDEX IF NOT EXISTS uniq_active_booking
    ON bookings (service_id, start_at)
    WHERE status IN ('PENDING', 'CONFIRMED');

CREATE INDEX IF NOT EXISTS idx_bookings_phone      ON bookings (customer_phone);
CREATE INDEX IF NOT EXISTS idx_bookings_start_at   ON bookings (start_at);
CREATE INDEX IF NOT EXISTS idx_bookings_status     ON bookings (status, created_at);

-- ----------------------------------------------------------------------------
-- booking_sessions: conversational state. Keyed by business_id:phone.
-- Expires after 30 min of inactivity. context is JSONB so the LLM can put
-- partial data (chosen service, tentative slot, etc.) without schema changes.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS booking_sessions (
    session_key     TEXT PRIMARY KEY,
    business_id     UUID NOT NULL,
    phone           TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'IDLE',
    context         JSONB NOT NULL DEFAULT '{}'::JSONB,
    last_message_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '30 minutes'
);

CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON booking_sessions (expires_at);

-- ----------------------------------------------------------------------------
-- message_idempotency: dedup of inbound webhooks from Evolution API.
-- Evolution may retry on timeouts; without dedup the same message books twice.
-- TTL: 24h (cron clears stale rows).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS message_idempotency (
    message_id   TEXT PRIMARY KEY,
    business_id  UUID NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_idempotency_processed_at
    ON message_idempotency (processed_at);

-- ----------------------------------------------------------------------------
-- Sweepers (run via cron, e.g. every 5 minutes / nightly).
-- ----------------------------------------------------------------------------

-- Reap PENDING bookings older than 60s — these are leftovers from cases where
-- the Insert succeeded but the Google Calendar create failed afterwards.
-- DO NOT reap CONFIRMED bookings.
-- Cron: every minute.
--
--   UPDATE bookings
--   SET    status = 'EXPIRED'
--   WHERE  status = 'PENDING' AND created_at < NOW() - INTERVAL '60 seconds';

-- Drop expired idempotency keys after 24h.
-- Cron: nightly.
--
--   DELETE FROM message_idempotency
--   WHERE  processed_at < NOW() - INTERVAL '24 hours';

-- Drop expired sessions.
-- Cron: hourly.
--
--   DELETE FROM booking_sessions
--   WHERE  expires_at < NOW() - INTERVAL '1 hour';

-- ----------------------------------------------------------------------------
-- Seed: ACME Studio + 4 demo services
-- (the IDs match what the workflow's Build LLM Context node hardcodes)
-- ----------------------------------------------------------------------------
INSERT INTO services (id, business_id, name, duration_minutes, price)
VALUES
    ('11111111-aaaa-bbbb-cccc-111111111111', '00000000-0000-0000-0000-000000000001', 'Classic haircut', 30, 25.00),
    ('22222222-aaaa-bbbb-cccc-222222222222', '00000000-0000-0000-0000-000000000001', 'Haircut + beard', 45, 38.00),
    ('33333333-aaaa-bbbb-cccc-333333333333', '00000000-0000-0000-0000-000000000001', 'Hair color',      90, 75.00),
    ('44444444-aaaa-bbbb-cccc-444444444444', '00000000-0000-0000-0000-000000000001', 'Manicure',        45, 30.00)
ON CONFLICT (id) DO NOTHING;
