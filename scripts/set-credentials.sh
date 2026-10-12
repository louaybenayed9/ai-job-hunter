#!/usr/bin/env bash
# ==========================================================================
# AI Job Hunter - credential injection for .env
#
# Fills the go-live secrets in place:
#   POSTGRES_PASSWORD, N8N_ENCRYPTION_KEY,
#   OPENROUTER_API_KEY (or GEMINI_API_KEY), TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
#
# Usage:
#   bash scripts/set-credentials.sh                 # interactive, skips what is set
#   bash scripts/set-credentials.sh --generate      # also generate the 2 local secrets
#   bash scripts/set-credentials.sh --set NAME=VAL [--set NAME=VAL ...]
#   bash scripts/set-credentials.sh --show          # report status, change nothing
#
# Existing values are never printed. Exits with the check-env.sh result.
# ==========================================================================
set -uo pipefail

# Force UTF-8 for the python helpers below (cp1252 on Windows cannot encode
# many real-world values and would abort the write mid-run).
export PYTHONUTF8=1

# Run from the project root regardless of where this script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ORIG_PWD="$PWD"

ENV_FILE=".env"
GENERATE=0
SHOW_ONLY=0
ASSIGNMENTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --generate) GENERATE=1 ;;
    --show)     SHOW_ONLY=1 ;;
    --set)      shift; ASSIGNMENTS+=("${1:-}") ;;
    --file)     shift; ENV_FILE="${1:-.env}" ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)"; exit 2 ;;
  esac
  shift
done

# Resolve .env: honour an absolute path or one valid from the caller's cwd,
# otherwise fall back to the project root (so `bash scripts/set-credentials.sh`
# works from any directory).
if [[ "$ENV_FILE" != /* && ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ORIG_PWD/$ENV_FILE" ]]; then
    ENV_FILE="$ORIG_PWD/$ENV_FILE"
  elif [[ -f "$PROJECT_ROOT/$ENV_FILE" ]]; then
    ENV_FILE="$PROJECT_ROOT/$ENV_FILE"
  fi
fi

cd "$PROJECT_ROOT" || { echo "FAIL  cannot cd to project root $PROJECT_ROOT"; exit 1; }

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL  $ENV_FILE not found -> cp .env.example $ENV_FILE"
  exit 1
fi

# --- .env helpers -------------------------------------------------------
get_val() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '\r'; }

is_unset() { # empty OR still a placeholder
  local v re
  v="$(get_val "$1")"
  [[ -z "$v" ]] && return 0
  re='[Cc]hange_?me|[Pp]laceholder|your_|YOUR_|<[^>]*>|^xxx+$|^TODO$'
  [[ "$v" =~ $re ]]
}

set_val() { # set_val NAME VALUE
  python3 - "$ENV_FILE" "$1" "$2" <<'PY'
import re, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
# A console paste (Ctrl+V) can inject control chars such as 0x16 or pad the
# value with spaces; never let those reach .env.
value = re.sub(r"[\x00-\x1f\x7f]", "", value).strip()
text = open(path, encoding="utf-8").read()
line = f"{key}={value}"
if re.search(rf"(?m)^{re.escape(key)}=.*$", text):
    text = re.sub(rf"(?m)^{re.escape(key)}=.*$", line, text, count=1)
else:
    text = text.rstrip("\n") + "\n" + line + "\n"
open(path, "w", encoding="utf-8", newline="\n").write(text)
PY
}

mask() { # first 4 chars only
  local v="$1"
  if [[ -z "$v" ]]; then echo "(empty)"; else
    local n=${#v}
    if (( n <= 6 )); then echo "${v:0:1}***"; else echo "${v:0:4}…($n chars)"; fi
  fi
}

# Drop control characters and surrounding whitespace a paste may have added.
sanitize() {
  local v="$1"
  v="$(printf '%s' "$v" | tr -d '\000-\037\177')"
  v="${v#"${v%%[![:space:]]*}"}"   # trim leading whitespace
  v="${v%"${v##*[![:space:]]}"}"   # trim trailing whitespace
  printf '%s' "$v"
}

# validate NAME VALUE -> 0 when usable; otherwise print why and return 1.
validate() {
  local name="$1" v="$2" err=""
  case "$name" in
    OPENROUTER_API_KEY)
      [[ "$v" =~ ^sk-or-v1-[0-9a-f]{64}$ ]] ||
        err="expected sk-or-v1- + 64 hex chars, got ${#v} chars (paste looks truncated)" ;;
    GEMINI_API_KEY)
      [[ "$v" =~ ^AIza[0-9A-Za-z_-]{30,}$ ]] ||
        err="expected an AIza... key from https://aistudio.google.com/apikey, got ${#v} chars" ;;
    TELEGRAM_BOT_TOKEN)
      [[ "$v" =~ ^[0-9]{4,}:[0-9A-Za-z_-]{25,}$ ]] ||
        err="expected <bot id>:<secret> from @BotFather, got ${#v} chars" ;;
    TELEGRAM_CHAT_ID)
      [[ "$v" =~ ^-?[0-9]+$ ]] ||
        err="expected a numeric chat id, got ${#v} chars" ;;
  esac
  [[ -z "$err" ]] || { echo "  -> $err"; return 1; }
  return 0
}

# Present but malformed still needs re-entry (a mangled paste must not SKIP).
needs_entry() {
  if is_unset "$1"; then return 0; fi
  validate "$1" "$(get_val "$1")" >/dev/null 2>&1 && return 1
  return 0
}

ask() { # ask NAME "hint" ["secret"]
  local name="$1" hint="$2" secret="${3:-}" value=""
  if ! needs_entry "$name"; then
    printf 'SKIP   %-24s already set (%s)\n' "$name" "$(mask "$(get_val "$name")")"
    return 0
  fi
  if [[ "$SHOW_ONLY" -eq 1 ]]; then
    printf 'MISS   %-24s %s\n' "$name" "$hint"
    NEEDS=1
    return 0
  fi
  if [[ ! -t 0 ]]; then
    printf 'MISS   %-24s %s  (stdin is not a TTY - use --set %s=VALUE)\n' "$name" "$hint" "$name"
    NEEDS=1
    return 0
  fi
  while true; do
    if [[ "$secret" == "secret" ]]; then
      read -r -s -p "$name ($hint): " value; echo
    else
      read -r -p "$name ($hint): " value; echo
    fi
    value="$(sanitize "$value")"
    if [[ -z "$value" ]]; then
      echo "  -> empty, try again (Ctrl+C to abort)"
      continue
    fi
    validate "$name" "$value" || { echo "  -> try again (Ctrl+C to abort)"; continue; }
    break
  done
  set_val "$name" "$value"
  printf 'SET    %-24s %s\n' "$name" "$(mask "$value")"
}

echo "== AI Job Hunter credential injection ($ENV_FILE) =="

# Which names were supplied on the command line (never prompt for those)
assigned() {
  local a
  for a in "${ASSIGNMENTS[@]:-}"; do
    [[ "${a%%=*}" == "$1" ]] && return 0
  done
  return 1
}

# 1. Explicit --set NAME=VALUE assignments (applied first) -------------------
for a in "${ASSIGNMENTS[@]:-}"; do
  [[ -z "$a" ]] && continue
  name="${a%%=*}"; value="${a#*=}"
  if [[ -z "$value" || "$name" == "$a" ]]; then
    echo "FAIL  --set expects NAME=VALUE (got: $a)"; exit 2
  fi
  value="$(sanitize "$value")"
  if ! validate "$name" "$value"; then
    echo "FAIL  $name rejected (see above)"; exit 2
  fi
  set_val "$name" "$value"
  printf 'SET    %-24s %s\n' "$name" "$(mask "$value")"
done

# 2. Machine-generated secrets ------------------------------------------------
if [[ "$GENERATE" -eq 1 && "$SHOW_ONLY" -eq 0 ]]; then
  if is_unset POSTGRES_PASSWORD && ! assigned POSTGRES_PASSWORD; then
    PG=$(openssl rand -hex 16); set_val POSTGRES_PASSWORD "$PG"
    printf 'SET    %-24s generated locally (%s)\n' "POSTGRES_PASSWORD" "$(mask "$PG")"
  fi
  if is_unset N8N_ENCRYPTION_KEY && ! assigned N8N_ENCRYPTION_KEY; then
    EK=$(openssl rand -hex 24); set_val N8N_ENCRYPTION_KEY "$EK"
    printf 'SET    %-24s generated locally (%s)\n' "N8N_ENCRYPTION_KEY" "$(mask "$EK")"
  fi
fi

prompt_missing() { # prompt_missing NAME "hint"
  local name="$1" hint="$2"
  assigned "$name" && return 0   # already written & reported by the --set loop
  if needs_entry "$name"; then
    if [[ "$SHOW_ONLY" -eq 1 ]]; then
      printf 'MISS   %-24s %s\n' "$name" "$hint"; NEEDS=1
    elif [[ "$GENERATE" -eq 1 && ( "$name" == "POSTGRES_PASSWORD" || "$name" == "N8N_ENCRYPTION_KEY" ) ]]; then
      : # --generate already handled these
    elif ! assigned "$name"; then
      if [[ "$name" == "TELEGRAM_CHAT_ID" ]]; then
        ask "$name" "$hint"
      else
        ask "$name" "$hint" secret
      fi
    fi
  else
    printf 'SKIP   %-24s already set (%s)\n' "$name" "$(mask "$(get_val "$name")")"
  fi
}

prompt_missing POSTGRES_PASSWORD "any strong password (or --generate)"
prompt_missing N8N_ENCRYPTION_KEY "openssl rand -hex 24 (or --generate)"

# 3. LLM key (one of two) ------------------------------------------------------
if needs_entry OPENROUTER_API_KEY && needs_entry GEMINI_API_KEY; then
  if [[ "$SHOW_ONLY" -eq 1 ]]; then
    printf 'MISS   %-24s %s\n' "OPENROUTER_API_KEY" "https://openrouter.ai/keys (or GEMINI_API_KEY + LLM_PROVIDER=gemini)"
    NEEDS=1
  elif [[ ! -t 0 ]]; then
    printf 'MISS   %-24s %s  (stdin is not a TTY - use --set OPENROUTER_API_KEY=VALUE)\n' "OPENROUTER_API_KEY" "https://openrouter.ai/keys"
    NEEDS=1
  elif ! assigned OPENROUTER_API_KEY && ! assigned GEMINI_API_KEY; then
    echo
    echo "Choose an LLM provider:"
    echo "  1) OpenRouter  (https://openrouter.ai/keys)"
    echo "  2) Gemini      (https://aistudio.google.com/apikey)"
    read -r -p "Provider [1/2]: " choice
    echo
    case "$choice" in
      2) ask GEMINI_API_KEY "Gemini API key" secret
         set_val LLM_PROVIDER gemini
         echo "SET    LLM_PROVIDER               = gemini" ;;
      *) ask OPENROUTER_API_KEY "OpenRouter API key" secret ;;
    esac
  fi
else
  assigned OPENROUTER_API_KEY || assigned GEMINI_API_KEY || {
    LLM_NAME="OPENROUTER_API_KEY"; needs_entry OPENROUTER_API_KEY && LLM_NAME="GEMINI_API_KEY"
    printf 'SKIP   %-24s already set\n' "$LLM_NAME"
  }
fi

# 4. Telegram -----------------------------------------------------------------
prompt_missing TELEGRAM_BOT_TOKEN "from @BotFather (token contains a colon)"
prompt_missing TELEGRAM_CHAT_ID "numeric id from @userinfobot or getUpdates"

echo
if [[ "$SHOW_ONLY" -eq 1 ]]; then
  [[ "${NEEDS:-0}" -eq 1 ]] && { echo "RESULT: credentials missing (see MISS lines)."; exit 1; }
  echo "RESULT: all credentials present in $ENV_FILE."
  exit 0
fi

echo "-- re-running pre-flight --"
bash "$SCRIPT_DIR/check-env.sh" "$ENV_FILE"
