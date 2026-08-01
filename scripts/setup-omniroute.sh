#!/bin/bash
# Configure OmniRoute providers via REST API (cookie auth).
# Persists to ~/.omniroute/ which is bind-mounted into container.
set -euo pipefail

API="http://localhost:4000"
COOKIES="/tmp/omniroute-cookies-$$"

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
YEL='\033[0;33m'
BLD='\033[1m'
RST='\033[0m'

header() { echo -e "\n${CYN}${BLD}=== $1 ===${RST}"; }
ok()     { echo -e "${GRN}  [+] $1${RST}"; }
skip()   { echo -e "${YEL}  [-] $1${RST}"; }
fail()   { echo -e "${RED}  [!] $1${RST}"; }

cleanup() { rm -f "$COOKIES"; }
trap cleanup EXIT

# Source keys
source "$(dirname "$0")/../.env" 2>/dev/null || true

# Check omniroute is running
if ! curl -s "$API/" >/dev/null 2>&1; then
    echo "OmniRoute not running at $API. Run: make up"
    exit 1
fi

echo -e "${CYN}${BLD}OmniRoute Provider Setup (API)${RST}"

# Login
PASS="${OMNIROUTE_INITIAL_PASSWORD:-$(pass show omniroute.ai/dashboard-password 2>/dev/null)}"
login_result=$(curl -s -X POST "$API/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$PASS\"}" \
    -c "$COOKIES" 2>/dev/null)

if ! echo "$login_result" | grep -q '"success":true'; then
    fail "Login failed. Check dashboard password."
    exit 1
fi
ok "Authenticated"

# API helper
api_get() { curl -s -b "$COOKIES" "$API$1" 2>/dev/null; }
api_post() { curl -s -b "$COOKIES" -X POST "$API$1" -H "Content-Type: application/json" -d "$2" 2>/dev/null; }

# Check existing providers
existing_providers() {
    api_get "/api/providers" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in d.get('connections', []):
    print(c.get('name',''))
" 2>/dev/null
}

add_provider() {
    local provider="$1" name="$2" key_var="$3" priority="$4" default_model="${5:-}" base_url="${6:-}"
    local key="${!key_var:-}"

    if [ -z "$key" ]; then
        skip "$name (no $key_var)"
        return
    fi

    if existing_providers | grep -q "^${name}$"; then
        ok "$name: already configured"
        return
    fi

    local body
    body=$(python3 -c "
import json
d = {
    'provider': '$provider',
    'name': '$name',
    'apiKey': '''$key''',
    'priority': $priority,
    'isActive': True,
}
if '$default_model':
    d['defaultModel'] = '$default_model'
if '$base_url':
    d['baseUrl'] = '$base_url'
print(json.dumps(d))
")

    result=$(api_post "/api/providers" "$body")
    if echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('connection') or d.get('id') or d.get('success') else 1)" 2>/dev/null; then
        ok "$name: added (priority=$priority)"
    else
        fail "$name: $(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown error'))" 2>/dev/null || echo "$result" | head -c 200)"
    fi
}

# =====================================================================
header "Paid Providers (priority 100)"
# =====================================================================
add_provider "openai"     "OpenAI"           OPENAI_API_KEY       100 "gpt-4o"
add_provider "anthropic"  "Anthropic"        ANTHROPIC_API_KEY    100 "claude-sonnet-4-6-20250514"
add_provider "gemini"     "Google AI Studio" GEMINI_API_KEY       100 "gemini-2.5-flash"
add_provider "mistral"    "Mistral"          MISTRAL_API_KEY      100 "mistral-large-latest"

# =====================================================================
header "Free Tier Providers (priority 50)"
# =====================================================================
add_provider "openrouter" "OpenRouter"       OPENROUTER_API_KEY    50 ""
add_provider "groq"       "Groq"             GROQ_API_KEY          50 "llama-3.3-70b-versatile"
add_provider "cerebras"   "Cerebras"         CEREBRAS_API_KEY      50 ""
add_provider "sambanova"  "SambaNova"        SAMBANOVA_API_KEY     50 ""

# =====================================================================
header "Ollama Local (add via dashboard)"
# =====================================================================
if curl -s http://localhost:11434/ >/dev/null 2>&1; then
    if existing_providers | grep -qi ollama; then
        ok "Ollama: already configured"
    else
        echo "  Add Ollama in dashboard: http://localhost:4000 > Providers"
        echo "  Base URL: http://ollama:11434"
    fi
    model_count=$(curl -s http://localhost:11434/api/tags 2>/dev/null \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo "0")
    ok "$model_count local models"
else
    skip "Ollama not running"
fi

# =====================================================================
header "Status"
# =====================================================================
echo ""
api_get "/api/providers" | python3 -c "
import sys, json
d = json.load(sys.stdin)
conns = d.get('connections', [])
if not conns:
    print('  No providers configured')
else:
    for c in sorted(conns, key=lambda x: -(x.get('priority') or x.get('globalPriority') or 0)):
        name = c.get('name', '?')
        prio = c.get('priority') or c.get('globalPriority') or '—'
        active = 'active' if c.get('isActive', c.get('is_active', True)) else 'inactive'
        print(f'  {name:<25} priority={str(prio):<5} {active}')
" 2>/dev/null || echo "  Could not query providers"

echo ""
curl -sf "$API/v1/models" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  {len(d[\"data\"])} models available')
" 2>/dev/null || echo "  Could not query models"

echo ""
echo -e "  Dashboard: ${BLD}http://localhost:4000${RST}"
echo ""
