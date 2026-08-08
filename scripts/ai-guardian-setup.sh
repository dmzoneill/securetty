#!/bin/bash
# Configure ai-guardian inside securetty container
# Called from entrypoint.sh on first run
set -euo pipefail

CONFIG_DIR="$HOME/.config/ai-guardian"
CONFIG_FILE="$CONFIG_DIR/ai-guardian.json"

mkdir -p "$CONFIG_DIR"

ai-guardian setup --ide claude --create-config --permissive --force 2>/dev/null || {
    echo "ai-guardian setup failed, skipping" >&2
    exit 0
}

[ -f "$CONFIG_FILE" ] || exit 0

python3.12 -c "
import json, sys

config_file = '$CONFIG_FILE'
with open(config_file) as f:
    config = json.load(f)

# Block: dangerous regardless of container isolation
for key in ['secret_scanning', 'config_file_scanning', 'supply_chain']:
    if key in config:
        config[key]['action'] = 'block'
    else:
        config[key] = {'action': 'block'}

# Add betterleaks engine for defense-in-depth
if 'secret_scanning' in config:
    engines = config['secret_scanning'].get('engines', [])
    if 'betterleaks' not in engines:
        engines.append('betterleaks')
    config['secret_scanning']['engines'] = engines

# Warn: container provides enforcement boundary, ai-guardian adds visibility
for key in ['prompt_injection', 'context_poisoning', 'code_scanning', 'scan_pii']:
    if key in config:
        config[key]['action'] = 'warn'
    else:
        config[key] = {'action': 'warn'}

# Log-only: container handles these
for key in ['ssrf_protection', 'secret_redaction', 'directory_rules']:
    if key in config:
        config[key]['action'] = 'log-only'
    else:
        config[key] = {'action': 'log-only'}

# Image scanning: block images containing secrets or PII
if 'image_scanning' not in config:
    config['image_scanning'] = {}
config['image_scanning']['action'] = 'block'

# Transcript scanning
if 'transcript_scanning' not in config:
    config['transcript_scanning'] = {}
config['transcript_scanning']['enabled'] = True

# Directory rules: deny sensitive paths
config['directory_rules']['rules'] = [
    {'path': '~/.ssh', 'action': 'deny'},
    {'path': '~/.aws/credentials', 'action': 'deny'},
    {'path': '~/.kube/config', 'action': 'deny'},
    {'path': '/certs/*.key', 'action': 'deny'},
]

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print('ai-guardian configured for securetty')
" 2>/dev/null || echo "ai-guardian config overlay failed" >&2
