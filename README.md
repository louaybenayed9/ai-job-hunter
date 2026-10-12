# AI Job Hunter

Self-hosted job-hunting pipeline for the Tunisian market (Keejob, Tanitjobs,
LinkedIn Tunisia, Emploi.tn). **n8n** orchestrates, a **FastAPI scraper
service** collects listings, **PostgreSQL + pgvector** stores them, an
**ai-service** scores every listing against your master resume with
Gemini/OpenRouter, and results are pushed to **Telegram** and a
**Google Sheet**.

```
                       ┌─────────────────────────────────────┐
   manual / schedule ─▶│              n8n :5678              │
                       │  scrape ─ score ─ threshold ─ notify│
                       └───┬──────────────┬──────────┬───────┘
                           │ HTTP         │ HTTP     │ HTTPS
              ┌────────────▼───────┐  ┌───▼────────┐ │
              │ scraper-service    │  │ ai-service  │ │──▶ api.telegram.org
              │ :8000 (FastAPI +   │  │ :8001 (LLM  │ │──▶ Google Sheets API
              │ BeautifulSoup)     │  │ scoring)    │ │
              └────────┬───────────┘  └───┬────────┘ │
                       │ scrapes          │ reads    │
                 keejob.com        data/resume.md    │
                 tanitjobs.com                       │
                       │                             │
              ┌────────▼─────────────────────────────▼───┐
              │     PostgreSQL 17 + pgvector :5432       │
              │  jobs / job_scores / notifications /     │
              │  embeddings (ready for RAG)              │
              └──────────────────────────────────────────┘
```

## Repository layout

```
ai-job-hunter/
├── docker-compose.yml            # n8n + postgres(pgvector) + scraper + ai
├── .env.example                  # every configuration variable
├── .gitignore
├── README.md
├── data/
│   └── resume.md                 # master resume the LLM scores against
├── postgres/
│   └── init/
│       └── 001_schema.sql        # runs on first boot: pgvector + tables
├── n8n/
│   └── workflows/
│       └── ai-job-hunter-pipeline.json   # importable seed workflow
├── scraper-service/
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── requirements.txt
│   └── main.py                   # /health, /scrape/keejob, /scrape/tanitjobs, /scrape/all
└── ai-service/
    ├── Dockerfile
    ├── .dockerignore
    ├── requirements.txt
    └── main.py                   # /health, /score, /score/batch (Gemini/OpenRouter)
```

## Prerequisites

- Docker Engine 24+ and Docker Compose v2 (`docker compose version`)
- Free API key from [OpenRouter](https://openrouter.ai/keys) **or**
  [Google AI Studio](https://aistudio.google.com/apikey)
- (Optional) Telegram bot token from [@BotFather](https://t.me/BotFather)
- (Optional) Google Cloud project with Sheets API enabled + OAuth client for n8n

## Quick start

```bash
# 1. Configure the environment
cp .env.example .env
#    - set POSTGRES_PASSWORD to anything non-empty
#    - set N8N_ENCRYPTION_KEY:  openssl rand -hex 24
#    - set OPENROUTER_API_KEY (or GEMINI_API_KEY + LLM_PROVIDER=gemini)

# 2. Put your real resume in place (overwrite the sample)
#    data/resume.md

# 3. Build and start everything
docker compose up -d --build

# 4. Watch the logs until all services are healthy
docker compose ps
docker compose logs -f scraper-service ai-service n8n

# 5. Smoke-test the microservices
curl http://localhost:8000/health
curl "http://localhost:8000/scrape/keejob?keywords=developpeur&limit=5"
curl http://localhost:8001/health/detail
```

Stop everything with `docker compose down` (add `-v` to also drop the
database volume).

## Service endpoints

| Service | URL | Purpose |
|---|---|---|
| n8n | http://localhost:5678 | workflow UI + webhooks |
| scraper-service | http://localhost:8000 | `/health`, `/scrape/keejob`, `/scrape/tanitjobs`, `/scrape/all` |
| ai-service | http://localhost:8001 | `/health`, `/score`, `/score/batch` |
| PostgreSQL | localhost:5432 | `ai_job_hunter` / `ai_job_hunter` |

### scraper-service

```bash
# Keejob search -> job title, company, location, description, link
curl "http://localhost:8000/scrape/keejob?keywords=d%C3%A9veloppeur&page=1&limit=15"
```

```json
{
  "status": "ok",
  "source": "keejob",
  "keywords": "développeur",
  "page": 1,
  "count": 15,
  "jobs": [
    {
      "title": "Développeur Web FullStack (.NET) à Sousse",
      "company": "CISA INFORMATIQUE",
      "location": "Hammam Sousse, Sousse",
      "description": "Au coeur des nouvelles technologies, ...",
      "link": "https://www.keejob.com/offres-emploi/247189/...",
      "source": "keejob"
    }
  ]
}
```

Errors always use the same envelope n8n branches on:

```json
{ "status": "error", "message": "Missing input field: keywords" }
```

`GET /scrape/all` fans out to every configured source in parallel and tolerates
partial failures (a dead source simply contributes 0 jobs).

### ai-service

```bash
curl -X POST http://localhost:8001/score \
  -H "Content-Type: application/json" \
  -d '{
    "job": {
      "title": "Backend Developer (Python)",
      "company": "Acme",
      "location": "Tunis",
      "description": "We need FastAPI, PostgreSQL, Docker...",
      "link": "https://example.com/job/1",
      "source": "keejob"
    },
    "keywords": "python"
  }'
```

```json
{
  "status": "ok",
  "result": {
    "score": 84,
    "verdict": "strong_match",
    "matched_skills": ["Python", "FastAPI", "PostgreSQL", "Docker"],
    "missing_skills": ["Kubernetes"],
    "keywords": ["python", "fastapi", "backend", "senior"],
    "rationale": "The role's core stack matches ...",
    "model": "nvidia/nemotron-3-super-120b-a12b:free",
    "provider": "openrouter",
    "notify": true
  }
}
```

- Structured output is validated with pydantic; if the model returns prose or
  code fences the service makes **one repair round-trip** before failing with
  `{"status": "error", "message": ...}`.
- `notify` is `true` when `score >= MATCH_SCORE_THRESHOLD` (default 75, shared
  with the n8n IF node filter).
- `POST /score/batch` accepts `{"jobs": [...], "keywords": "..."}` and scores up
  to 3 jobs concurrently.
- With `LLM_PROVIDER=gemini` the service calls the Gemini API with
  `responseMimeType: application/json` + a `responseSchema`, so the reply is
  already JSON on the wire.

## n8n setup (first run)

1. **Open the UI**: http://localhost:5678 — create the owner account on first
   visit (self-hosted, no n8n cloud signup).
2. **Import the seed workflow**: `Workflows → Import from file →`
   `n8n/workflows/ai-job-hunter-pipeline.json`.
3. **Secrets** are read from the process environment (`$env.*`), *not* stored in
   n8n — that is why `docker-compose.yml` passes `OPENROUTER_API_KEY`,
   `TELEGRAM_BOT_TOKEN`, `SCRAPE_API_URL`, `AI_SERVICE_URL`, etc. into the n8n
   container. Change them in `.env` and run `docker compose up -d n8n`.
4. **Telegram**: follow the step-by-step [Telegram setup guide](#telegram-setup-guide)
   below (BotFather token, chat id, node test).
5. **Google Sheets node** (the only node needing a stored credential):
   - Google Cloud Console → enable *Google Sheets API* → create an *OAuth 2.0
     Client ID* (Web application) with redirect
     `http://localhost:5678/rest/oauth2-credential/callback`.
   - n8n → *Credentials → New → Google Sheets OAuth2 API* → paste client id/secret → *Sign in*.
   - Set `GOOGLE_SHEETS_SPREADSHEET_ID` and `GOOGLE_SHEETS_SHEET_NAME` in `.env`
     (or leave the node's resource selectors as-is and pick them in the UI).
   - The sheet must have the header row:
     `Title | Company | Location | Score | Verdict | Source | Link | Rationale | Checked at`.
6. **Postgres credential** (for your own persist nodes / SQL queries):
   - Host `postgres`, port `5432`, database `ai_job_hunter`,
     user `ai_job_hunter`, password = `POSTGRES_PASSWORD`, SSL `disable`.
   - Inside the compose network n8n reaches Postgres as `postgres`;
     from your host machine use `localhost:5432`.
7. **Schedule & activation**: the workflow ships with a Schedule Trigger node
   (`Daily 8AM (Tunis)`, cron `0 8 * * *`). The execution timezone is
   `Africa/Tunis` — set both in the node/workflow settings and via
   `GENERIC_TIMEZONE` in `.env`. Flip the workflow toggle to **Active** to let
   it run every day; use **Execute workflow** for an immediate manual run.

## Telegram setup guide

Every job with `match_score >= MATCH_SCORE_THRESHOLD` (default 75, set in
`.env`) produces one MarkdownV2 alert per job:

```
🎯 Match Score: 84/100
💼 Title: Développeur Web FullStack (.NET) à Sousse
🏢 Company: CISA INFORMATIQUE
📍 Location: Hammam Sousse, Sousse
🔗 Apply Link: https://www.keejob.com/offres-emploi/247189/...
💡 Key Match Rationale: Strong match on FastAPI/PostgreSQL...
⚠️ Missing Skills / Gaps: Kubernetes
```

(The words *Match Score*, *Title*, … are bold in Telegram; dynamic values are
MarkdownV2-escaped by the `Format Telegram Message` node so titles like
`(.NET)` or `m/f/d` never break the message.)

### a) Create the bot → `TELEGRAM_BOT_TOKEN`

1. In Telegram, open a chat with **[@BotFather](https://t.me/BotFather)** and send `/newbot`.
2. Give it a display name (e.g. `AI Job Hunter`), then a unique username that
   ends in `bot` (e.g. `ai_job_hunter_tn_bot`).
3. BotFather replies with an HTTP API token shaped like `123456789:AAF3xY...zQ`.
4. Copy it into `.env`:
   ```dotenv
   TELEGRAM_BOT_TOKEN=123456789:AAF3xY...zQ
   ```
5. Optional: `/setjoingroups` → *Enable* if you want the bot inside a group
   chat, and `/setprivacy` → *Disable* so it can see group messages.

### b) Get the chat id → `TELEGRAM_CHAT_ID`

**Option 1 — @userinfobot (easiest):** start a chat with
[@userinfobot](https://t.me/userinfobot) (or [@getmyid_bot](https://t.me/getmyid_bot))
and send any message; it replies with your numeric id, e.g. `987654321`.

**Option 2 — official Bot API (no third party):**

1. Send any message (e.g. `hi`) to **your own bot** first — the bot cannot
   message you until you start the chat.
2. Then call its updates endpoint:
   ```bash
   curl "https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/getUpdates"
   ```
3. Read `result[0].message.chat.id` from the JSON. For a **group** chat the id
   is negative (e.g. `-1001234567890`) — add the bot to the group and send a
   message there before calling `getUpdates`.
4. Put it into `.env` and restart n8n so the value is injected:
   ```dotenv
   TELEGRAM_CHAT_ID=987654321
   ```
   ```bash
   docker compose up -d n8n
   ```
   (The workflow reads `$env.TELEGRAM_BOT_TOKEN` / `$env.TELEGRAM_CHAT_ID`; no
   credential needs to be stored inside n8n.)

### c) Test the Telegram node from the n8n UI

1. Open the workflow `AI Job Hunter - Scrape & Score Pipeline` (leave it inactive).
2. Click the **Format Telegram Message** node. In its input panel choose
   **Pin/Broadcast test data** ("Add test event") and paste:
   ```json
   {
     "match_score": 84,
     "title": "Développeur Web FullStack (.NET) à Sousse",
     "company": "CISA INFORMATIQUE",
     "location": "Hammam Sousse, Sousse",
     "link": "https://www.keejob.com/offres-emploi/247189/demo/",
     "match_rationale": "Strong match on FastAPI/PostgreSQL (5+ yrs).",
     "missing_skills": ["Kubernetes"]
   }
   ```
   Press **Execute step** → the output item contains `telegram_text`.
3. Now click the **Telegram Notification** node and press **Execute step**. It
   POSTs to `https://api.telegram.org/bot<TOKEN>/sendMessage` — check your
   Telegram: the formatted alert arrives within seconds.
4. Troubleshooting:
   - `401 Unauthorized: Unauthorized` → wrong or empty `TELEGRAM_BOT_TOKEN`.
   - `400 Bad Request: chat not found` → wrong `TELEGRAM_CHAT_ID`, or you never
     messaged the bot first.
   - `400 Bad Request: can't parse entities` → an unescaped MarkdownV2
     character; confirm the text comes from the Format node, not hand-typed.
5. Full end-to-end test (scrape → score → Telegram): click **Execute workflow**
   — this needs `OPENROUTER_API_KEY` (or Gemini) set. Once a message arrives,
   toggle the workflow **Active**; the Schedule Trigger fires daily at
   **08:00 Africa/Tunis** (`0 8 * * *`).

## Database

`postgres/init/001_schema.sql` runs on first boot and creates:

| Table | Contents |
|---|---|
| `jobs` | raw listings (unique per source+url) |
| `job_scores` | every LLM score with skills/rationale |
| `notifications` | Telegram/Sheets delivery log |
| `embeddings` | `vector(1536)` + HNSW index — ready for RAG |

```bash
docker compose exec postgres psql -U ai_job_hunter -d ai_job_hunter \
  -c "SELECT title, url FROM jobs ORDER BY first_seen_at DESC LIMIT 10;"
```

To change the embedding dimension later, edit `VECTOR(1536)` before the first
boot (the volume persists afterwards).

## Politeness & rate limits

`SCRAPE_DELAY_SECONDS` (default 1s) is enforced between pages, requests carry a
real browser User-Agent, and `SCRAPE_MAX_PAGES` caps pagination per call.
Keep the defaults: these are small local boards. For LinkedIn, use their
official jobs API or an authenticated session — a bare HTML scraper will be
blocked.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `POSTGRES_PASSWORD is required` on `compose up` | `.env` missing — `cp .env.example .env` |
| scraper returns `HTTP 403` | site changed fingerprint rules: rotate `SCRAPE_USER_AGENT` or add delays |
| scraper returns 0 jobs | markup changed — selectors live in `_parse_keejob` / `_parse_tanitjobs` in `scraper-service/main.py` |
| ai-service `Missing input field: OPENROUTER_API_KEY` | key not set in `.env`, restart with `docker compose up -d ai-service` |
| n8n can't reach services | use compose service names (`http://scraper-service:8000`), never `localhost`, inside workflows |
| credentials unreadable after key change | `N8N_ENCRYPTION_KEY` was rotated; restore the original key |
| `frontend`/`$env` errors in expressions | keep `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` in compose |

## Extending

- **New source** (e.g. Emploi.tn): add a `_parse_<site>` function plus a route in
  `scraper-service/main.py`, register it in `/scrape/all`.
- **RAG over past jobs**: the `embeddings` table and `data/resume.md` are already
  in place — add an `/embed` endpoint to ai-service and a Postgres node in n8n.
- **LinkedIn Tunisia**: keep it as a manual/CSV import node in n8n until you
  have an authenticated session; scraping logged-out LinkedIn HTML will fail.
