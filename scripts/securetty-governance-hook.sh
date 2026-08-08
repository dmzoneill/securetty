#!/bin/bash
# PreToolUse governance hook: route skill invocations through aap-sdlc orchestrator (issue #59)
# Reads Claude Code hook JSON from stdin; redirects non-aap-sdlc Skill calls.
set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || exit 0

# Only gate Skill invocations; let everything else pass
if [ "$tool_name" != "Skill" ]; then
  exit 0
fi

skill=$(printf '%s' "$input" | python3 -c "
import json, sys
ti = json.load(sys.stdin).get('tool_input', {})
print(ti.get('skill', ''))
" 2>/dev/null) || exit 0

# aap-sdlc is the orchestrator — let it through
if [ "$skill" = "aap-sdlc" ]; then
  exit 0
fi

# Block direct skill invocation — must route through aap-sdlc
cat <<EOF
{"decision":"block","reason":"Skill '${skill}' must be invoked through the aap-sdlc orchestrator. Run: /aap-sdlc ${skill}"}
EOF
