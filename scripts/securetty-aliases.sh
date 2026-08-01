#!/bin/bash
# Source this from ~/.bashrc.d/scripts.d/ after migration.
# Each AI agent command creates a NEW ephemeral container from securetty image.
# Container is removed after exit (--rm). Each session is isolated.

SECURETTY_IMAGE="${SECURETTY_IMAGE:-securetty_dev}"
SECURETTY_DIR="${SECURETTY_DIR:-$HOME/src/securetty}"

_securetty_run() {
    local agent="$1"
    shift

    # Ensure all agent config dirs exist on host
    mkdir -p ~/.claude ~/.codex ~/.gemini ~/.cursor ~/.kiro ~/.cline \
        ~/.config/opencode ~/.local/share/opencode ~/.openhands \
        ~/.config/goose ~/.grok ~/.forge ~/.amp ~/.config/kilo ~/.aider \
        ~/.config/gcloud 2>/dev/null

    # Generate fresh .env from host environment + config files
    bash "$SECURETTY_DIR/scripts/generate-env.sh" "$SECURETTY_DIR/.env" 2>/dev/null

    # Source generated .env so podman run picks up the values
    set -a
    source "$SECURETTY_DIR/.env" 2>/dev/null || true
    set +a

    # Start restricted SSH agent (only dmzoneill-2024 key) if not running
    if [ ! -S "/run/user/$(id -u)/securetty-ssh-agent.sock" ]; then
        bash "$SECURETTY_DIR/scripts/ssh-agent-restricted.sh" start 2>/dev/null
    fi

    # Ensure omniroute + headroom services are running
    if [ "$(podman inspect securetty-omniroute --format '{{.State.Running}}' 2>/dev/null)" != "true" ] || \
       [ "$(podman inspect securetty-headroom --format '{{.State.Running}}' 2>/dev/null)" != "true" ]; then
        echo "Starting services..."
        (cd "$SECURETTY_DIR" && podman-compose up -d egress-proxy omniroute headroom 2>/dev/null) || true
        sleep 1
    fi

    # Start URL relay if not running
    if [ ! -S "/run/user/$(id -u)/securetty-open.sock" ]; then
        bash "$SECURETTY_DIR/scripts/open-relay-host.sh" start &
        disown
        sleep 0.3
    fi

    podman run --rm -it \
        ${_SECURETTY_EXTRA_ENV[@]+"${_SECURETTY_EXTRA_ENV[@]}"} \
        --name "securetty-${agent}-$$" \
        --hostname "securetty-${agent}" \
        --userns=keep-id \
        --cap-drop ALL \
        --cap-add SYS_NICE \
        --security-opt no-new-privileges:true \
        --security-opt label=disable \
        --read-only \
        --device /dev/dri \
        \
        -v "/home/daoneill/src:/home/daoneill/src" \
        -v "/home/daoneill/.gitconfig:/home/daoneill/.gitconfig:ro" \
        -v "/home/daoneill/.gnupg/pubring.kbx:/home/daoneill/.gnupg/pubring.kbx:ro" \
        -v "/home/daoneill/.gnupg/trustdb.gpg:/home/daoneill/.gnupg/trustdb.gpg:ro" \
        -v "/run/user/$(id -u)/securetty-ssh-agent.sock:/run/ssh-agent.sock:ro" \
        -v "/home/daoneill/.ssh/config:/home/daoneill/.ssh/config:ro" \
        -v "/home/daoneill/.ssh/known_hosts:/home/daoneill/.ssh/known_hosts:ro" \
        \
        -v "/home/daoneill/.config/gcloud:/home/daoneill/.config/gcloud:ro" \
        \
        -v "/home/daoneill/.claude.json:/home/daoneill/.claude.json" \
        -v "/home/daoneill/.claude:/home/daoneill/.claude" \
        \
        -v "/home/daoneill/.codex:/home/daoneill/.codex" \
        -v "/home/daoneill/.gemini:/home/daoneill/.gemini" \
        -v "/home/daoneill/.cursor:/home/daoneill/.cursor" \
        -v "/home/daoneill/.kiro:/home/daoneill/.kiro" \
        -v "/home/daoneill/.cline:/home/daoneill/.cline" \
        -v "/home/daoneill/.config/opencode:/home/daoneill/.config/opencode" \
        -v "/home/daoneill/.local/share/opencode:/home/daoneill/.local/share/opencode" \
        -v "/home/daoneill/.openhands:/home/daoneill/.openhands" \
        -v "/home/daoneill/.config/goose:/home/daoneill/.config/goose" \
        -v "/home/daoneill/.grok:/home/daoneill/.grok" \
        -v "/home/daoneill/.forge:/home/daoneill/.forge" \
        -v "/home/daoneill/.amp:/home/daoneill/.amp" \
        -v "/home/daoneill/.config/kilo:/home/daoneill/.config/kilo" \
        -v "/home/daoneill/.aider:/home/daoneill/.aider" \
        \
        -v "${GPG_AGENT_EXTRA_SOCK:-/dev/null}:/run/gpg-agent.sock:ro" \
        -v "/run/user/$(id -u)/securetty-open.sock:/run/securetty-open.sock" \
        -v "/run/user/$(id -u):/run/user/1000" \
        \
        --tmpfs /tmp:size=512M \
        --tmpfs /home/daoneill/.npm:size=256M \
        --tmpfs /home/daoneill/.cache:size=1G \
        -v "/home/daoneill/.local/bin:/home/daoneill/.local/bin:ro" \
        \
        -w "${_SECURETTY_WORKDIR:-$(pwd)}" \
        -e HOME=/home/daoneill \
        -e USER=daoneill \
        -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
        -e GPG_AGENT_INFO=/run/gpg-agent.sock \
        -e XDG_RUNTIME_DIR=/run/user/1000 \
        -e NODE_ENV=development \
        -e npm_config_ignore_scripts=true \
        -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
        -e "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
        -e "GOOGLE_API_KEY=${GOOGLE_API_KEY:-}" \
        -e "GEMINI_API_KEY=${GEMINI_API_KEY:-}" \
        -e "XAI_API_KEY=${XAI_API_KEY:-}" \
        -e "GITHUB_TOKEN=${GITHUB_TOKEN:-}" \
        -e "SOURCEGRAPH_ACCESS_TOKEN=${SOURCEGRAPH_ACCESS_TOKEN:-}" \
        -e "OMNIROUTE_BASE_URL=http://securetty-omniroute:4000" \
        -e "HEADROOM_URL=http://securetty-headroom:8787" \
        -e "HTTP_PROXY=http://securetty-egress-proxy:3128" \
        -e "HTTPS_PROXY=http://securetty-egress-proxy:3128" \
        -e "http_proxy=http://securetty-egress-proxy:3128" \
        -e "https_proxy=http://securetty-egress-proxy:3128" \
        -e "NO_PROXY=localhost,127.0.0.1,securetty-omniroute,securetty-headroom,securetty-cloudcli,securetty-ollama,securetty-egress-proxy" \
        \
        --network securetty_internal \
        \
        "$SECURETTY_IMAGE" \
        "$agent" "$@"
}

# Work mode: Vertex for Claude/Gemini, skip-permissions for all
# Adds Vertex env vars, removes omniroute routing
_securetty_run_work() {
    local agent="$1"
    shift
    _SECURETTY_EXTRA_ENV=(
        -e "CLAUDE_CODE_USE_VERTEX=1"
        -e "ANTHROPIC_VERTEX_PROJECT_ID=${ANTHROPIC_VERTEX_PROJECT_ID:-}"
        -e "GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT:-}"
        -e "GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION:-}"
        -e "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
        -e "ANTHROPIC_BASE_URL="
        -e "GOOGLE_APPLICATION_CREDENTIALS=/home/daoneill/.config/gcloud/application_default_credentials.json"
    )
    _securetty_run "$agent" "$@"
}

# Personal mode: all agents route through omniroute
# Claude: ANTHROPIC_BASE_URL → omniroute, key = omniroute API key
# Codex:  OPENAI_BASE_URL → omniroute, key = omniroute API key
# Gemini: uses omniroute as OpenAI-compatible endpoint
# All others: OPENAI_BASE_URL → omniroute
_securetty_run_personal() {
    local agent="$1"
    shift
    local omni_key="${OMNIROUTE_API_KEY:-}"
    _SECURETTY_EXTRA_ENV=(
        # Unset Vertex — use omniroute instead
        -e "CLAUDE_CODE_USE_VERTEX="
        # Claude routes through omniroute
        -e "ANTHROPIC_BASE_URL=http://securetty-omniroute:4000"
        -e "ANTHROPIC_API_KEY=${omni_key}"
        # Codex/OpenAI-compatible agents route through omniroute
        -e "OPENAI_BASE_URL=http://securetty-omniroute:4000/v1"
        -e "OPENAI_API_KEY=${omni_key}"
        # Gemini — unset direct key, use omniroute
        -e "GEMINI_API_KEY="
        -e "GOOGLE_API_KEY=${omni_key}"
        # Generic provider base URL (aider, opencode, etc)
        -e "OPENAI_API_BASE=http://securetty-omniroute:4000/v1"
    )
    _securetty_run "$agent" "$@"
}

# Helper: extract dir arg from any position, set _SECURETTY_WORKDIR
_extract_workdir() {
    _SECURETTY_WORKDIR="$(pwd)"
    local args=()
    for arg in "$@"; do
        if [ -d "$arg" ] && [ "$_SECURETTY_WORKDIR" = "$(pwd)" ]; then
            _SECURETTY_WORKDIR="$(realpath "$arg")"
        else
            args+=("$arg")
        fi
    done
    _SECURETTY_ARGS=("${args[@]}")
}

# =================================================================
# Claude Code
#   Default: personal (omniroute)
#   -work: Vertex
#   Always: --dangerously-skip-permissions
# =================================================================
claude()      { _extract_workdir "$@"; _securetty_run_personal claude --dangerously-skip-permissions "${_SECURETTY_ARGS[@]}"; }
claude-work() { _extract_workdir "$@"; _securetty_run_work claude --dangerously-skip-permissions "${_SECURETTY_ARGS[@]}"; }
alias c='claude'
alias cw='claude-work'
alias c-r='claude -r'
alias c-c='claude -c'

# =================================================================
# Codex CLI
#   Default: personal (omniroute)
#   -work: Vertex (for Anthropic models via omniroute)
#   Always: --dangerously-bypass-approvals-and-sandbox
# =================================================================
codex()      { _securetty_run_personal codex --dangerously-bypass-approvals-and-sandbox "$@"; }
codex-work() { _securetty_run_work codex --dangerously-bypass-approvals-and-sandbox "$@"; }

# =================================================================
# Gemini CLI
#   Default: personal (omniroute / AI Studio key)
#   -work: Vertex (uses GOOGLE_CLOUD_PROJECT)
#   Always: --yolo (skip approvals)
# =================================================================
gemini()      { _securetty_run_personal gemini "$@"; }
gemini-work() { _securetty_run_work gemini "$@"; }

# =================================================================
# All other agents — personal mode, skip-permissions
# =================================================================
cursor()   { _securetty_run_personal cursor --yolo "$@"; }
cline()    { _securetty_run_personal cline --yolo "$@"; }
opencode() { _securetty_run_personal opencode "$@"; }
amp()      { _securetty_run_personal amp "$@"; }
kilo()     { _securetty_run_personal kilo "$@"; }
aider()    { _securetty_run_personal aider --yes "$@"; }
openhands(){ _securetty_run_personal openhands "$@"; }
goose()    { _securetty_run_personal goose "$@"; }
grok()     { _securetty_run_personal grok "$@"; }
forge()    { _securetty_run_personal forge "$@"; }
kiro-cli() { _securetty_run_personal kiro-cli "$@"; }
alias kiro='kiro-cli'
pi-ai()    { _securetty_run_personal pi-ai "$@"; }
kimi()     { _securetty_run_personal kimi "$@"; }

# Work variants for all agents
cursor-work()    { _securetty_run_work cursor --yolo "$@"; }
cline-work()     { _securetty_run_work cline --yolo "$@"; }
opencode-work()  { _securetty_run_work opencode "$@"; }
amp-work()       { _securetty_run_work amp "$@"; }
kilo-work()      { _securetty_run_work kilo "$@"; }
aider-work()     { _securetty_run_work aider --yes "$@"; }
openhands-work() { _securetty_run_work openhands "$@"; }
goose-work()     { _securetty_run_work goose "$@"; }
grok-work()      { _securetty_run_work grok "$@"; }
forge-work()     { _securetty_run_work forge "$@"; }
kiro-work()      { _securetty_run_work kiro-cli "$@"; }
pi-ai-work()     { _securetty_run_work pi-ai "$@"; }
kimi-work()      { _securetty_run_work kimi "$@"; }

# Short aliases
alias cw='claude-work'
alias cx='codex'
alias cxw='codex-work'
alias gm='gemini'
alias gmw='gemini-work'
alias cr='cursor'
alias crw='cursor-work'
alias cl='cline'
alias clw='cline-work'
alias oc='opencode'
alias ocw='opencode-work'
alias ai='aider'
alias aiw='aider-work'
alias oh='openhands'
alias ohw='openhands-work'
alias gs='goose'
alias gsw='goose-work'
alias gr='grok'
alias grw='grok-work'
alias fg='forge'
alias fgw='forge-work'
alias ki='kiro-cli'
alias kiw='kiro-work'
alias pi='pi-ai'
alias piw='pi-ai-work'
alias km='kimi'
alias kmw='kimi-work'

# Services
headroom() { _securetty_run headroom "$@"; }
alias c-h='headroom proxy --port 8787'
omniroute(){ _securetty_run omniroute "$@"; }

# Shell
securetty-shell() { _securetty_run /bin/bash; }
alias ss='securetty-shell'
