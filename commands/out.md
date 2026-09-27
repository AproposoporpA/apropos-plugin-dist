---
description: Record end of day (Shift End, EventTypeID 8) for the logged-in user.
---
First resolve the logged-in user's Apropos person id by running `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/person-id.sh"`. It prints `APROPOS_PERSON_ID=<id>`; use that number as `<id>` below. If it exits non-zero, show the user its message and stop. Never guess or reuse an id.
Then run immediately (no confirmation):
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID <id> -Description "Out" -EventTypeID 8`
