#!/bin/bash
# Post-commit hook: DCO-compliant trailers with agent provenance (issues #44, #46)
# Strips AI Co-Authored-By / Signed-off-by lines, adds Assisted-by + provenance trailers.

git rev-parse --git-dir &>/dev/null || exit 0

msg=$(git log -1 --format=%B 2>/dev/null) || exit 0

ai_pattern='([Cc]laude|[Cc]opilot|[Aa]nthrop|[Aa][Ii][ -]|noreply@anthropic|bot@)'

# Check for AI-related Co-Authored-By or Signed-off-by lines
if ! echo "$msg" | grep -qiE "^(Co-[Aa]uthored-[Bb]y|Signed-off-by):.*$ai_pattern"; then
  exit 0
fi

# Strip AI Co-Authored-By and Signed-off-by lines, trim trailing blank lines
cleaned=$(echo "$msg" \
  | grep -viE "^(Co-[Aa]uthored-[Bb]y|Signed-off-by):.*$ai_pattern" \
  | sed -e :a -e '/^\n*$/{$d;N;ba;}')

model="${CLAUDE_MODEL:-unknown}"

# Add trailers only if not already present
if ! echo "$cleaned" | grep -q '^Assisted-by:'; then
  cleaned="$cleaned"$'\n'"Assisted-by: Claude Code ($model)"
fi
if [ -n "$CLAUDE_SESSION_ID" ] && ! echo "$cleaned" | grep -q '^Agent-Session:'; then
  cleaned="$cleaned"$'\n'"Agent-Session: $CLAUDE_SESSION_ID"
fi
if [ -n "$CLAUDE_MODEL" ] && ! echo "$cleaned" | grep -q '^Agent-Model:'; then
  cleaned="$cleaned"$'\n'"Agent-Model: $CLAUDE_MODEL"
fi

git commit --amend --no-verify -m "$cleaned" &>/dev/null
echo '{"result": "Stripped AI trailers, added DCO-compliant Assisted-by + provenance."}'
