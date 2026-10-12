#!/usr/bin/env bash
# ==========================================================================
# AI Job Hunter - end-to-end go-live verification
#
# Steps:
#   1  pre-flight (scripts/check-env.sh)
#   2  health: scraper + ai-service, keys/resume/threshold loaded
#   3  live scrape from Tunisian portals
#   4  LLM scoring of one real job  (score 0-100 + notify vs threshold)
#   5  Telegram: format MarkdownV2 alert and send it
#   6  n8n: reachable + workflow ready to import
#
# Usage:
#   bash scripts/e2e-test.sh
#   bash scripts/e2e-test.sh path/to/.env     # non-default env file
#   AI_PORT=8011 N8N_PORT=5679 bash scripts/e2e-test.sh   # force host ports
#   SKIP_TELEGRAM=1 bash scripts/e2e-test.sh              # stop after scoring
#   KEYWORDS=developpeur LIMIT=5 bash scripts/e2e-test.sh
#
# Exit code: 0 = every executed step passed, 1 = at least one FAIL.
# ==========================================================================
set -uo pipefail

# Windows terminals default to cp1252; scraped jobs and model output contain
# non-ASCII (e.g. U+2011) which crashes python's stdout encoder mid-assertion.
export PYTHONUTF8=1

# Run from the project root regardless of where this script is invoked from,
# so `docker compose port` and the n8n/workflows/... path resolve correctly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ORIG_PWD="$PWD"

ENV_FILE="${1:-.env}"
if [[ "$ENV_FILE" != /* && ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ORIG_PWD/$ENV_FILE" ]]; then
    ENV_FILE="$ORIG_PWD/$ENV_FILE"
  elif [[ -f "$PROJECT_ROOT/$ENV_FILE" ]]; then
    ENV_FILE="$PROJECT_ROOT/$ENV_FILE"
  fi
fi

cd "$PROJECT_ROOT" || { echo "FAIL  cannot cd to project root $PROJECT_ROOT"; exit 1; }

[[ -f "$ENV_FILE" ]] || { echo "FAIL  $ENV_FILE not found"; exit 1; }

env_val() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '\r'; }

# Resolve a host port: explicit env var > actual docker compose mapping > .env.
# The compose mapping wins because this machine also runs other projects on the
# default 5678/8001 ports (agent-n8n / agent-skills), so .env may point at a
# foreign service.
resolve_port() { # resolve_port <env-var> <compose service> <container port> <env key>
  local var="$1" svc="$2" cport="$3" key="$4" mapped=""
  if [[ -n "${!var:-}" ]]; then echo "${!var}"; return 0; fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    mapped=$(docker compose port "$svc" "$cport" 2>/dev/null | awk -F: 'NF{print $NF}' | tail -1)
  fi
  [[ -n "$mapped" ]] && { echo "$mapped"; return 0; }
  env_val "$key"
}

SCRAPER_URL="http://localhost:${SCRAPER_PORT_R:-$(resolve_port SCRAPER_PORT scraper-service 8000 SCRAPER_PORT)}"
AI_URL="http://localhost:${AI_PORT_R:-$(resolve_port AI_PORT ai-service 8001 AI_PORT)}"
N8N_URL="http://localhost:${N8N_PORT_R:-$(resolve_port N8N_PORT n8n 5678 N8N_PORT)}"
SCRAPER_URL="${SCRAPER_URL%/}"; AI_URL="${AI_URL%/}"; N8N_URL="${N8N_URL%/}"

KEYWORDS="${KEYWORDS:-developpeur}"
LIMIT="${LIMIT:-5}"
THRESHOLD="$(env_val MATCH_SCORE_THRESHOLD)"; THRESHOLD="${THRESHOLD:-75}"

WORKDIR="$(mktemp -d 2>/dev/null || echo ".e2e_tmp")"
mkdir -p "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

FAILS=0
STEP=0
step() { STEP=$((STEP + 1)); echo; echo "== Step $STEP: $1 =="; }
ok()   { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
note() { printf '      %s\n' "$1"; }

command -v python3 >/dev/null || { echo "FAIL  python3 is required"; exit 1; }

echo "Targets: scraper=$SCRAPER_URL  ai=$AI_URL  n8n=$N8N_URL  threshold=$THRESHOLD"

# --------------------------------------------------------------------------
step "Pre-flight validation"
if bash "$SCRIPT_DIR/check-env.sh" "$ENV_FILE"; then
  ok "check-env.sh -> READY"
else
  fail "check-env.sh reported failures"
  echo; echo "NOT READY - fix the FAIL lines in $ENV_FILE first."; exit 1
fi

# --------------------------------------------------------------------------
step "Service health"
H=$(curl -s --max-time 15 "$SCRAPER_URL/health" || true)
if echo "$H" | grep -q '"status": *"ok"'; then ok "scraper $SCRAPER_URL/health -> $H"; else fail "scraper health: $H"; fi

D=$(curl -s --max-time 15 "$AI_URL/health/detail" || true)
if ! echo "$D" | grep -q '"status": *"ok"'; then
  fail "ai-service $AI_URL/health/detail -> ${D:0:200}"
else
  ok "ai-service healthy at $AI_URL"
  echo "$D" > "$WORKDIR/health.json"
  if python3 - "$WORKDIR/health.json" "$THRESHOLD" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))["config"]
want = int(sys.argv[2])
checks = [
    ("resume_loaded", cfg.get("resume_loaded") is True, cfg.get("resume_loaded")),
    ("resume_chars>500", (cfg.get("resume_chars") or 0) > 500, cfg.get("resume_chars")),
    ("threshold==%d" % want, cfg.get("match_score_threshold") == want, cfg.get("match_score_threshold")),
    ("llm_key_present", bool(cfg.get("openrouter_key_present") or cfg.get("gemini_key_present")),
     "openrouter=%s gemini=%s" % (cfg.get("openrouter_key_present"), cfg.get("gemini_key_present"))),
    ("provider", cfg.get("provider") in ("openrouter", "gemini"), cfg.get("provider")),
]
bad = 0
for name, good, value in checks:
    print(("PASS  " if good else "FAIL  ") + "%s: %s" % (name, value))
    bad += (0 if good else 1)
sys.exit(1 if bad else 0)
PY
  then ok "config verified (resume + threshold + LLM key)"
  else fail "ai-service config incomplete (see FAIL lines above)"
  fi
fi

# --------------------------------------------------------------------------
step "Live scrape ($KEYWORDS, limit $LIMIT)"
SCRAPE=$(curl -s --max-time 180 "$SCRAPER_URL/scrape/all?keywords=$KEYWORDS&limit=$LIMIT" || true)
echo "$SCRAPE" > "$WORKDIR/scrape.json"
if python3 - "$WORKDIR/scrape.json" <<'PY'
import json, sys
try:
    jobs = json.load(open(sys.argv[1], encoding="utf-8")).get("jobs") or []
except Exception:
    jobs = []
if not jobs:
    sys.exit(1)
for i, j in enumerate(jobs[:5]):
    print("      [%d] %s @ %s (%s)" % (i, j.get("title"), j.get("company"), j.get("source")))
PY
then
  N=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("jobs") or []))' "$WORKDIR/scrape.json" 2>/dev/null || echo 0)
  ok "scraped $N job(s)"
else
  fail "scrape returned no jobs: ${SCRAPE:0:300}"
fi

if [[ ! -s "$WORKDIR/scrape.json" ]] || ! python3 -c 'import json,sys;j=json.load(open(sys.argv[1])).get("jobs") or [];sys.exit(0 if j else 1)' "$WORKDIR/scrape.json" 2>/dev/null; then
  echo; echo "ABORT: no job to score (FAILS=$FAILS)."; exit 1
fi

# --------------------------------------------------------------------------
step "LLM scoring of a real job"
python3 - "$WORKDIR/scrape.json" "$WORKDIR/payload.json" <<'PY'
import json, sys
jobs = json.load(open(sys.argv[1], encoding="utf-8"))["jobs"]
job = jobs[0]
json.dump({"job": job}, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
print("      payload -> payload.json")
print("      job: %s @ %s" % (job.get("title"), job.get("company")))
print("      link: %s" % job.get("link"))
PY

SCORE=$(curl -s --max-time 120 -X POST "$AI_URL/score" \
  -H "Content-Type: application/json" \
  --data @"$WORKDIR/payload.json" || true)
echo "$SCORE" > "$WORKDIR/score.json"
echo "      response bytes: ${#SCORE}"

if python3 - "$WORKDIR/score.json" "$THRESHOLD" <<'PY'
import json, os, sys
raw = open(sys.argv[1], encoding="utf-8").read()
th = int(sys.argv[2])
try:
    body = json.loads(raw)
except Exception:
    print("FAIL  non-JSON response: %s" % raw[:300]); sys.exit(1)

if body.get("status") != "ok":
    print("FAIL  endpoint error: %s" % raw[:300]); sys.exit(1)

r = body.get("result") or {}
score = r.get("score")
problems = []

if not isinstance(score, int) or isinstance(score, bool) or not (0 <= score <= 100):
    problems.append("score not an int in 0-100: %r" % (score,))
if not isinstance(r.get("notify"), bool):
    problems.append("notify not a bool: %r" % (r.get("notify"),))
elif isinstance(score, int) and not isinstance(score, bool) and r["notify"] != (score >= th):
    problems.append("notify=%r inconsistent with score %s vs threshold %d"
                    % (r["notify"], score, th))
if r.get("verdict") not in ("strong_match", "maybe", "skip"):
    problems.append("verdict invalid: %r" % (r.get("verdict"),))
if not str(r.get("rationale") or "").strip():
    problems.append("rationale empty")
if not isinstance(r.get("matched_skills"), list):
    problems.append("matched_skills missing/not a list")
if not isinstance(r.get("missing_skills"), list):
    problems.append("missing_skills missing/not a list")

if problems:
    for p in problems:
        print("FAIL  " + p)
    sys.exit(1)

print("PASS  score=%s/100 verdict=%s notify=%s" % (score, r.get("verdict"), r.get("notify")))
print("PASS  provider=%s model=%s" % (r.get("provider"), r.get("model")))
print("PASS  notify == (score >= %d)" % th)
print("      matched: " + (", ".join(r.get("matched_skills") or []) or "-"))
print("      missing: " + (", ".join(r.get("missing_skills") or []) or "-"))
print("      rationale: " + str(r.get("rationale"))[:300])
PY
then SCORE_OK=1; ok "scoring round-trip verified"; else SCORE_OK=0; fail "scoring round-trip"; fi

if [[ "${SKIP_TELEGRAM:-0}" == "1" ]]; then
  echo; echo "SKIP_TELEGRAM=1 - stopping after scoring (FAILS=$FAILS)."
  [[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
fi

# --------------------------------------------------------------------------
step "Telegram MarkdownV2 alert"
BOT_TOKEN="$(env_val TELEGRAM_BOT_TOKEN)"
CHAT_ID="$(env_val TELEGRAM_CHAT_ID)"

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  fail "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID empty"
else
  ME=$(curl -s --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" || true)
  if echo "$ME" | grep -q '"ok": *true'; then
    BOTNAME=$(python3 -c 'import json,sys;d=json.load(sys.stdin)["result"];print("@"+str(d.get("username","?")))' <<<"$ME" 2>/dev/null || echo "?")
    ok "bot authenticated: $BOTNAME"
  else
    fail "getMe failed (bad token?): ${ME:0:200}"
  fi

  if [[ "$SCORE_OK" -eq 1 ]]; then
    if python3 - "$WORKDIR/score.json" "$WORKDIR/payload.json" "$WORKDIR/message.txt" <<'PY'
import json, re, sys

def esc(v):
    # MarkdownV2: every one of these must be escaped in *dynamic* text
    return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', str(v if v is not None else ""))

score = json.load(open(sys.argv[1], encoding="utf-8"))["result"]
job = json.load(open(sys.argv[2], encoding="utf-8"))["job"]
missing = ", ".join(esc(s) for s in (score.get("missing_skills") or [])) or "None flagged"

text = "\n\n".join([
    "\U0001f3af *Match Score:* %s/100" % esc(score.get("score")),
    "\U0001f4bc *Title:* %s" % esc(job.get("title")),
    "\U0001f3e2 *Company:* %s" % esc(job.get("company")),
    "\U0001f4cd *Location:* %s" % esc(job.get("location")),
    "\U0001f517 *Apply Link:* %s" % esc(job.get("link")),
    "\U0001f4a1 *Key Match Rationale:* %s" % esc(score.get("rationale")),
    "⚠️ *Missing Skills / Gaps:* %s" % missing,
])
open(sys.argv[3], "w", encoding="utf-8").write(text)
print("      message chars: %d" % len(text))
PY
    then
      BODY_JSON=$(python3 - "$CHAT_ID" "$WORKDIR/message.txt" <<'PY'
import json, sys
text = open(sys.argv[2], encoding="utf-8").read()
print(json.dumps({
    "chat_id": sys.argv[1],
    "text": text,
    "parse_mode": "MarkdownV2",
    "disable_web_page_preview": True,
}))
PY
)
      SENT=$(curl -s --max-time 30 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$BODY_JSON" || true)

      if echo "$SENT" | grep -q '"ok": *true'; then
        MID=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["result"].get("message_id",""))' <<<"$SENT" 2>/dev/null || echo "?")
        ok "alert delivered to chat $CHAT_ID (message_id=$MID)"
        note "check your Telegram app now"
      else
        fail "sendMessage rejected: ${SENT:0:300}"
        note "401 -> bad token | 400 'chat not found' -> bad chat id | 400 'can't parse entities' -> escaping"
      fi
    else
      fail "could not format the MarkdownV2 message"
    fi
  else
    fail "skipped: no valid score to format"
  fi
fi

# --------------------------------------------------------------------------
step "n8n readiness"
UI=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$N8N_URL/" || true)
if [[ "$UI" == "200" ]]; then ok "n8n UI reachable at $N8N_URL (HTTP 200)"; else fail "n8n UI HTTP $UI at $N8N_URL"; fi

WF="n8n/workflows/ai-job-hunter-pipeline.json"
if [[ -f "$WF" ]]; then
  if python3 - "$WF" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
nodes = wf.get("nodes") or []
names = {n.get("name") for n in nodes}
conns = wf.get("connections") or {}
missing = [c for c in conns if c not in names]
if not nodes:
    print("FAIL  workflow has no nodes"); sys.exit(1)
if missing:
    print("FAIL  dangling connection sources: %s" % missing); sys.exit(1)
print("      workflow: %d nodes, %d connections" % (len(nodes), len(conns)))
PY
  then ok "workflow file valid: $WF"
  else fail "workflow file invalid: $WF"
  fi
else
  fail "workflow file missing: $WF"
fi
note "import + activation in the n8n UI is manual (see GO_LIVE.md step 6)"

# --------------------------------------------------------------------------
echo
echo "== Result: $FAILS failure(s) =="
if [[ "$FAILS" -eq 0 ]]; then
  echo "E2E PASS - scoring verified$([[ "${SKIP_TELEGRAM:-0}" == "1" ]] || echo " and alert delivered")."
  exit 0
fi
echo "E2E FAIL - see FAIL lines above."
exit 1
