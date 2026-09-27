---
description: Set up the apropos time-tracking plugin for this user.
---
Run: `bash "${CLAUDE_PLUGIN_ROOT}/setup/setup.sh" --remove-legacy`
Then tell the user to restart Claude Code so the hooks + SessionStart injection load, and confirm `apropos` appears in `/plugin`.
