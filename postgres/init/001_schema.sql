-- =========================================================================
-- AI Job Hunter - initial schema (runs automatically on first container boot)
-- =========================================================================

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- Raw job listings pulled by the scraper service through n8n
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS jobs (
    id              BIGSERIAL PRIMARY KEY,
    source          TEXT        NOT NULL,               -- keejob | tanitjobs | linkedin | emploi_tn
    external_id     TEXT,                               -- id parsed from the source URL
    title           TEXT        NOT NULL,
    company         TEXT,
    location        TEXT,
    description     TEXT,
    url             TEXT        NOT NULL,
    keywords        TEXT,                               -- search query that surfaced the job
    first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, url)
);

CREATE INDEX IF NOT EXISTS idx_jobs_first_seen_at ON jobs (first_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_title_trgm     ON jobs USING gin (to_tsvector('french', coalesce(title, '')));

-- ---------------------------------------------------------------------------
-- LLM scoring results (ai-service /score responses)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS job_scores (
    id            BIGSERIAL PRIMARY KEY,
    job_id        BIGINT      NOT NULL REFERENCES jobs (id) ON DELETE CASCADE,
    score         INTEGER     NOT NULL CHECK (score BETWEEN 0 AND 100),
    verdict       TEXT        NOT NULL,                 -- strong_match | maybe | skip
    matched_skills TEXT[],
    missing_skills TEXT[],
    rationale     TEXT,
    model         TEXT,                                 -- e.g. nvidia/nemotron-3-super-120b-a12b:free
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_job_scores_job_id  ON job_scores (job_id);
CREATE INDEX IF NOT EXISTS idx_job_scores_score   ON job_scores (score DESC);

-- ---------------------------------------------------------------------------
-- Outbound notifications (Telegram / Google Sheets)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
    id            BIGSERIAL PRIMARY KEY,
    job_id        BIGINT      NOT NULL REFERENCES jobs (id) ON DELETE CASCADE,
    channel       TEXT        NOT NULL,                 -- telegram | google_sheets
    payload       JSONB       NOT NULL,
    sent_at       TIMESTAMPTZ,
    error         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_job_id ON notifications (job_id);

-- ---------------------------------------------------------------------------
-- pgvector: ready for RAG over job descriptions / resume chunks
-- 1536 dims matches OpenAI text-embedding-3-small; adjust if you change model.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS embeddings (
    id           BIGSERIAL PRIMARY KEY,
    ref_table    TEXT        NOT NULL,                  -- 'jobs' | 'job_scores' | ...
    ref_id       BIGINT      NOT NULL,
    content      TEXT        NOT NULL,
    embedding    VECTOR(1536),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (ref_table, ref_id)
);

CREATE INDEX IF NOT EXISTS idx_embeddings_vector ON embeddings USING hnsw (embedding vector_cosine_ops);
