-- ============================================================================
-- bot_telemetry — schema mínimo para tracking de ejecuciones del search bot.
-- Capturamos lo necesario para responder: ¿que tan seguido el LLM alucina?
-- ¿que provider tiene mejor accuracy? ¿que queries no encuentran resultados?
-- ============================================================================

CREATE TABLE IF NOT EXISTS bot_telemetry (
    id                   BIGSERIAL PRIMARY KEY,
    session_id           TEXT NOT NULL,
    query                TEXT NOT NULL,
    intent               TEXT,                          -- category_search | brand_search | free_text
    llm_provider         TEXT,                          -- openai | anthropic
    hallucination_score  NUMERIC(4,3),                  -- 0.000 .. 1.000
    sanitized            BOOLEAN NOT NULL DEFAULT FALSE,
    sanitization_reason  TEXT,                          -- no_results | llm_parse_error | hallucination_threshold_exceeded
    products_returned    INTEGER NOT NULL DEFAULT 0,
    mentioned_count      INTEGER NOT NULL DEFAULT 0,
    invalid_count        INTEGER NOT NULL DEFAULT 0,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_bot_telemetry_session    ON bot_telemetry (session_id);
CREATE INDEX IF NOT EXISTS idx_bot_telemetry_created_at ON bot_telemetry (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bot_telemetry_provider   ON bot_telemetry (llm_provider, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bot_telemetry_sanitized  ON bot_telemetry (sanitized) WHERE sanitized = TRUE;

-- Vista de salud rápida
CREATE OR REPLACE VIEW bot_telemetry_health AS
SELECT
    DATE_TRUNC('hour', created_at)             AS hour,
    llm_provider,
    COUNT(*)                                   AS total,
    AVG(hallucination_score)::NUMERIC(4,3)     AS avg_hallucination_score,
    SUM(CASE WHEN sanitized THEN 1 ELSE 0 END) AS sanitized_count,
    SUM(CASE WHEN sanitized THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS sanitization_rate,
    SUM(CASE WHEN products_returned = 0 THEN 1 ELSE 0 END) AS no_result_count
FROM bot_telemetry
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
