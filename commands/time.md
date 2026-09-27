---
description: Record an ad-hoc Apropos time entry for the logged-in user.
---
Record time for the **logged-in user**. First resolve the logged-in user's Apropos person id by running `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/person-id.sh"`. It prints `APROPOS_PERSON_ID=<id>`; use that number as `<id>` below. If it exits non-zero, show the user its message and stop. Never guess or reuse an id.
Then run:
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID <id> -Description "$ARGUMENTS"`
If a task was named (a `#` and its number), add `-TaskID <number>`; if a project was named add `-ProjectID <id>`. If `$ARGUMENTS` is empty, summarize the current work as the description. Report success or the error.
