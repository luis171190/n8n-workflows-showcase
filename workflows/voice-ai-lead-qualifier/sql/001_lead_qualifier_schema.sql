-- ============================================================
-- Voice AI Lead Qualifier — Schema v1.0
-- ============================================================
-- Tables:
--   leads              Master lead record (idempotency key: email UNIQUE)
--   call_attempts      One row per outbound call (linked to lead + call_queue)
--   processed_calls    Idempotency table for Retell post-call webhooks
--   call_queue         Queued calls (out-of-hours, retries)
--   call_costs         Granular cost tracking per call
--   dnc_list           Do-Not-Call registry
--   nurture_queue      Warm leads pending follow-up sequence
-- ============================================================

-- --------------------------------------------------------
-- leads
-- --------------------------------------------------------
CREATE TABLE IF NOT EXISTS leads (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email               TEXT NOT NULL UNIQUE,          -- idempotency key
    phone               TEXT NOT NULL,
    first_name          TEXT,
    last_name           TEXT,
    company             TEXT,
    company_domain      TEXT,                          -- extracted from email
    source              TEXT,                          -- landing_page | webinar | referral | ...
    status              TEXT NOT NULL DEFAULT 'new'
                            CHECK (status IN ('new','queued','calling','called','disqualified','converted','dnc')),
    -- BANT fields (populated after post-call analysis)
    bant_budget         TEXT,                          -- 'confirmed' | 'unconfirmed' | 'no_budget'
    bant_authority      TEXT,                          -- 'decision_maker' | 'influencer' | 'unknown'
    bant_need           TEXT,                          -- 'strong' | 'moderate' | 'weak'
    bant_timing         TEXT,                          -- 'immediate' | '1_3_months' | '3_6_months' | 'unknown'
    bant_score          SMALLINT CHECK (bant_score BETWEEN 0 AND 10),
    intent              TEXT CHECK (intent IN ('hot','warm','cold','disqualified')),
    next_action         TEXT,                          -- 'schedule_meeting' | 'nurture' | 'disqualify'
    call_summary        TEXT,
    objections          JSONB DEFAULT '[]',
    -- Enrichment (from domain lookup)
    enriched_industry   TEXT,
    enriched_size       TEXT,
    enriched_country    TEXT,
    -- Metadata
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_called_at      TIMESTAMPTZ,
    converted_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_leads_status ON leads (status);
CREATE INDEX IF NOT EXISTS idx_leads_intent ON leads (intent);
CREATE INDEX IF NOT EXISTS idx_leads_created_at ON leads (created_at DESC);

-- --------------------------------------------------------
-- call_attempts
-- --------------------------------------------------------
CREATE TABLE IF NOT EXISTS call_attempts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id         UUID NOT NULL REFERENCES leads (id) ON DELETE CASCADE,
    queue_id        UUID,                              -- FK to call_queue if originated from drainer
    retell_call_id  TEXT UNIQUE,                       -- Retell's call_id (populated on callback)
    direction       TEXT NOT NULL DEFAULT 'outbound',
    status          TEXT NOT NULL DEFAULT 'initiated'
                        CHECK (status IN ('initiated','ringing','in_progress','completed','failed','no_answer')),
    duration_sec    INTEGER,
    recording_url   TEXT,
    cost_usd        NUMERIC(8,4),
    error_message   TEXT,
    triggered_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_call_attempts_lead_id ON call_attempts (lead_id);
CREATE INDEX IF NOT EXISTS idx_call_attempts_retell_id ON call_attempts (retell_call_id);

-- --------------------------------------------------------
-- processed_calls
-- Idempotency table for Retell post-call webhooks
-- --------------------------------------------------------
CREATE TABLE IF NOT EXISTS processed_calls (
    retell_call_id  TEXT PRIMARY KEY,
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- --------------------------------------------------------
-- call_queue
-- Holds leads that couldn't be called immediately
-- (out-of-hours or Retell rate-limit)
-- --------------------------------------------------------
CREATE TABLE IF NOT EXISTS call_queue (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id         UUID NOT NULL REFERENCES leads (id) ON DELETE CASCADE,
    reason          TEXT NOT NULL CHECK (reason IN ('out_of_hours','rate_limit','retry')),
    status          TEXT NOT NULL DEFAULT 'WAITING'
                        CHECK (status IN ('WAITING','PROCESSING','TRIGGERED','GAVE_UP')),
    retry_count     SMALLINT NOT NULL DEFAULT 0,
    scheduled_at    TIMESTAMPTZ NOT NULL,              -- when to next attempt
    last_error      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_call_queue_status_scheduled ON call_queue (status, scheduled_at)
    WHERE status IN ('WAITING','PROCESSING');

-- --------------------------------------------------------
-- call_costs
-- Granular cost rows (one per call, supports future multi-item billing)
-- --------------------------------------------------------
CREATE TABLE IF NOT EXISTS call_costs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_attempt_id UUID NOT NULL REFERENCES call_attempts (id) ON DELETE CASCADE,
    lead_id         UUID NOT NULL REFERENCES leads (id) ON DELETE CASCADE,
    provider        TEXT NOT NULL DEFAULT 'retell',
    duration_sec    INTEGER,
    cost_usd        NUMERIC(8,4),
    model_used      TEXT,                              -- 'gpt-4o-mini' | 'claude-sonnet-4-5' | etc.
    analysis_cost_usd NUMERIC(8,4),                   -- LLM cost for transcript analysis
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_call_costs_lead_id ON call_costs (lead_id);

-- --------------------------------------------------------
-- dnc_list
-- Do-Not-Call registry. Phone numbers here skip the call flow.
-- --------------------------------------------------------
CREATE TABLE IF NOT EXISTS dnc_list (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone       TEXT NOT NULL UNIQUE,
    email       TEXT,
    reason      TEXT,                                  -- 'user_request' | 'legal' | 'bounced' | etc.
    added_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    added_by    TEXT                                   -- 'system' | 'manual' | 'retell_opt_out'
);

-- --------------------------------------------------------
-- nurture_queue
-- Warm leads that need follow-up outreach
-- --------------------------------------------------------
CREATE TABLE IF NOT EXISTS nurture_queue (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id         UUID NOT NULL REFERENCES leads (id) ON DELETE CASCADE,
    step            SMALLINT NOT NULL DEFAULT 1,       -- 1=day1, 2=day3, 3=day7, ...
    scheduled_at    TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','SENT','SKIPPED')),
    channel         TEXT NOT NULL DEFAULT 'email'
                        CHECK (channel IN ('email','whatsapp','call')),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_nurture_queue_scheduled ON nurture_queue (scheduled_at)
    WHERE status = 'PENDING';

-- --------------------------------------------------------
-- Helper: auto-update updated_at on leads and call_queue
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_leads_updated_at
    BEFORE UPDATE ON leads
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE TRIGGER trg_call_queue_updated_at
    BEFORE UPDATE ON call_queue
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- --------------------------------------------------------
-- Seed: sample DNC entry (for testing the DNC filter)
-- --------------------------------------------------------
INSERT INTO dnc_list (phone, reason, added_by)
VALUES ('+15550000000', 'test_dnc_entry', 'system')
ON CONFLICT (phone) DO NOTHING;
