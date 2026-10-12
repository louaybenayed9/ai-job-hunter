#!/usr/bin/env bash
# ==========================================================================
# AI Job Hunter - pre-flight .env validation
# Usage:
#   bash scripts/check-env.sh                 # full go-live checks
#   bash scripts/check-env.sh --core-only     # skip Telegram checks
#   bash scripts/check-env.sh path/to/.env
# Exit code: 0 = ready to start Docker, 1 = fix the failures below first.
# ==========================================================================
set -uo pipefail

# Force UTF-8 for the python helpers below (cp1252 on Windows cannot encode
# many real-world values and would abort the check mid-run).
export PYTHONUTF8=1

# Run from the project root regardless of where this script is invoked from,
# so `bash scripts/check-env.sh` works from any directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ORIG_PWD="$PWD"

ENV_FILE=".env"
CORE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --core-only) CORE_ONLY=1 ;;
    *) ENV_FILE="$arg" ;;
  esac
done

# Resolve the env file: absolute paths and paths valid from the caller's
# directory are honoured as-is; otherwise resolve against the project root.
if [[ "$ENV_FILE" != /* && ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ORIG_PWD/$ENV_FILE" ]]; then
    ENV_FILE="$ORIG_PWD/$ENV_FILE"
  elif [[ -f "$PROJECT_ROOT/$ENV_FILE" ]]; then
    ENV_FILE="$PROJECT_ROOT/$ENV_FILE"
  fi
fi

cd "$PROJECT_ROOT" || { echo "FAIL  cannot cd to project root $PROJECT_ROOT"; exit 1; }

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL  .env not found at '$ENV_FILE'  ->  cp .env.example .env"
  exit 1
fi

FAILS=0
WARNS=0

# Strip CR, take everything after the first '='
get_val() {
  grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '\r'
}

has_val() { [[ -n "$(get_val "$1")" ]]; }

is_placeholder() {
  local v re
  v="$(get_val "$1")"
  re='[Cc]hange_?me|[Pp]laceholder|your_|YOUR_|<[^>]*>|^xxx+$|^TODO$'
  [[ "$v" =~ $re ]]
}

report() { # report <OK|FAIL|WARN> <message>
  printf '%-5s %s\n' "$1" "$2"
  [[ "$1" == "FAIL" ]] && FAILS=$((FAILS + 1))
  [[ "$1" == "WARN" ]] && WARNS=$((WARNS + 1))
  return 0
}

check_required() {
  local var="$1" hint="$2"
  if ! has_val "$var"; then
    report "FAIL" "$var is empty  ->  $hint"
  elif is_placeholder "$var"; then
    report "FAIL" "$var is still the placeholder value  ->  $hint"
  else
    report "OK" "$var is set"
  fi
}

echo "== AI Job Hunter pre-flight check ($ENV_FILE) =="

# 0. Mangled pastes: a Ctrl+V paste can inject control chars (0x16) into values
CTRL_HITS="$(python3 - "$ENV_FILE" <<'PY'
import re, sys
hits = []
for i, line in enumerate(open(sys.argv[1], encoding="utf-8", errors="replace"), 1):
    line = line.rstrip("\n").rstrip("\r")
    if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    if re.search(r"[\x00-\x1f\x7f]", value):
        hits.append(f"{key.strip()} (line {i})")
print("; ".join(hits))
PY
)"
if [[ -n "$CTRL_HITS" ]]; then
  report "FAIL" "control characters inside: $CTRL_HITS  -> re-enter those values (a paste injected them)"
fi

# 1. Secrets that must be filled before the stack is usable
check_required POSTGRES_PASSWORD "any non-empty password (read the DB logs to reuse it later)"
check_required N8N_ENCRYPTION_KEY "generate: openssl rand -hex 24"

# 2. LLM key: at least one of the two
if has_val OPENROUTER_API_KEY && ! is_placeholder OPENROUTER_API_KEY; then
  ORK="$(get_val OPENROUTER_API_KEY)"
  if [[ "$ORK" =~ ^sk-or-v1-[0-9a-f]{64}$ ]]; then
    report "OK" "OPENROUTER_API_KEY is set (provider default: openrouter)"
  else
    report "FAIL" "OPENROUTER_API_KEY malformed: got ${#ORK} chars, want sk-or-v1- + 64 hex (paste was truncated) -> re-run scripts/set-credentials.sh"
  fi
elif has_val GEMINI_API_KEY && ! is_placeholder GEMINI_API_KEY; then
  report "OK" "GEMINI_API_KEY is set (set LLM_PROVIDER=gemini in .env)"
else
  report "FAIL" "no LLM key -> set OPENROUTER_API_KEY (https://openrouter.ai/keys) or GEMINI_API_KEY + LLM_PROVIDER=gemini"
fi

# 3. Threshold sanity
THRESHOLD="$(get_val MATCH_SCORE_THRESHOLD)"
if [[ -z "$THRESHOLD" ]]; then
  report "FAIL" "MATCH_SCORE_THRESHOLD missing -> add MATCH_SCORE_THRESHOLD=75"
elif ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || (( THRESHOLD < 0 || THRESHOLD > 100 )); then
  report "FAIL" "MATCH_SCORE_THRESHOLD='$THRESHOLD' is not an integer 0-100"
elif [[ "$THRESHOLD" != "75" ]]; then
  report "WARN" "MATCH_SCORE_THRESHOLD=$THRESHOLD (documented default is 75)"
else
  report "OK" "MATCH_SCORE_THRESHOLD=75"
fi

# 4. n8n key length (informational)
ENC_KEY="$(get_val N8N_ENCRYPTION_KEY)"
if [[ -n "$ENC_KEY" && ${#ENC_KEY} -lt 32 ]]; then
  report "WARN" "N8N_ENCRYPTION_KEY is shorter than 32 chars (credentials encryption strength)"
fi

# 5. Telegram (required for the go-live notification test)
if [[ "$CORE_ONLY" -eq 1 ]]; then
  echo "--  Telegram checks skipped (--core-only)"
else
  TOK="$(get_val TELEGRAM_BOT_TOKEN)"
  if ! has_val TELEGRAM_BOT_TOKEN || is_placeholder TELEGRAM_BOT_TOKEN; then
    report "FAIL" "TELEGRAM_BOT_TOKEN is empty  ->  create with @BotFather, paste the token"
  elif ! [[ "$TOK" =~ ^[0-9]{4,}:[0-9A-Za-z_-]{25,}$ ]]; then
    report "FAIL" "TELEGRAM_BOT_TOKEN malformed: got ${#TOK} chars, want <bot id>:<secret> -> re-run scripts/set-credentials.sh"
  else
    report "OK" "TELEGRAM_BOT_TOKEN is set"
  fi
  if ! has_val TELEGRAM_CHAT_ID; then
    report "FAIL" "TELEGRAM_CHAT_ID is empty -> see README 'Telegram setup guide' section b"
  elif ! [[ "$(get_val TELEGRAM_CHAT_ID)" =~ ^-?[0-9]+$ ]]; then
    report "FAIL" "TELEGRAM_CHAT_ID='$(get_val TELEGRAM_CHAT_ID)' is not numeric"
  else
    report "OK" "TELEGRAM_CHAT_ID is set"
  fi
fi

# 6. Google Sheets (optional at go-live)
if ! has_val GOOGLE_SHEETS_SPREADSHEET_ID; then
  report "WARN" "GOOGLE_SHEETS_SPREADSHEET_ID empty -> the Sheets append node will be skipped/disabled"
fi

echo "== Result: $FAILS failure(s), $WARNS warning(s) =="
if [[ "$FAILS" -gt 0 ]]; then
  echo "NOT READY - fix the FAIL lines in $ENV_FILE, then re-run this script."
  exit 1
fi
echo "READY - you can start the stack: docker compose up -d --build"
exit 0
