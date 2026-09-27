#!/usr/bin/env bash
# apropos /setup (idempotent). With --remove-legacy it retires the pre-plugin
# setup so there is no double-recording or duplicate convention:
#   1. Removes any legacy per-turn time-tracking block from CLAUDE.md
#      (the plugin now injects the convention via SessionStart).
#   2. Removes the legacy manual UserPromptSubmit hook (the R: time-track-per-turn.sh
#      one) from settings.json (the plugin now owns that hook).
# Each edit backs up the file first.
set -euo pipefail
MD="${HOME}/.claude/CLAUDE.md"
SETTINGS="${HOME}/.claude/settings.json"
DO_LEGACY=0; [[ "${1:-}" == "--remove-legacy" ]] && DO_LEGACY=1

# 1. CLAUDE.md convention block(s) — any dash style / trailing text / repeats.
HDR_RE='^##[[:space:]]*Time tracking.*per-turn Apropos convention'
if [[ $DO_LEGACY -eq 1 && -f "$MD" ]] && grep -qE "$HDR_RE" "$MD"; then
  cp "$MD" "${MD}.bak-$(date +%Y%m%d-%H%M%S)"
  awk -v re="$HDR_RE" '
    /^#/ { if ($0 ~ re) { skip=1; next } else { skip=0 } }
    skip { next }
    { print }
  ' "$MD" > "${MD}.tmp" && mv "${MD}.tmp" "$MD"
  echo "Removed legacy per-turn block(s) from CLAUDE.md (backup saved)."
fi

# 2. Legacy manual UserPromptSubmit hook in settings.json (needs jq).
if [[ $DO_LEGACY -eq 1 && -f "$SETTINGS" ]] && grep -q 'time-track-per-turn\.sh' "$SETTINGS"; then
  if command -v jq >/dev/null 2>&1; then
    cp "$SETTINGS" "${SETTINGS}.bak-$(date +%Y%m%d-%H%M%S)"
    jq '
      if (.hooks.UserPromptSubmit? // null) != null then
        .hooks.UserPromptSubmit |= (map(.hooks |= map(select((.command // "") | test("time-track-per-turn\\.sh") | not)))
          | map(select((.hooks | length) > 0)))
        | (if (.hooks.UserPromptSubmit | length) == 0 then .hooks |= del(.UserPromptSubmit) else . end)
        | (if (.hooks | length) == 0 then del(.hooks) else . end)
      else . end
    ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "Removed legacy UserPromptSubmit hook from settings.json (backup saved)."
  else
    echo "WARN: legacy hook found in settings.json but jq is missing — remove the UserPromptSubmit hook that runs time-track-per-turn.sh manually."
  fi
fi

command -v jq >/dev/null 2>&1 || echo "WARN: jq not found — recommended for session/project detection in the hook."
echo "SETUP OK"
