## Apropos per-turn time tracking (auto-injected by the apropos plugin)

Time entries are START MARKERS only — the start of a new activity ends the prior one; Apropos derives duration from the gap. The entry is written when your response completes and is backdated to the moment the prompt arrived, so the marker sits at the real start of the work.

**ONE ENTRY PER ACTIVITY, NOT PER TURN.** An activity is a task plus worktype plus project. When a turn continues an activity that is already open, the hook AMENDS that entry rather than opening a new one, and your description REPLACES the one already there. So write a description that covers the stretch of work on that activity, not just the last thing you touched. A new entry opens when the activity changes, or after 30 minutes on the same one. The open entries are shared across every concurrent session on the machine.

This replaced one-entry-per-turn on 2026-08-13, after four days produced over three hundred entries, 185 of them under five minutes and 20 of zero length.

**Writing a specific description each turn is REQUIRED, not optional.** If you don't, the hook falls back to the last assistant message in the session transcript, preferring a labelled summary. That fallback refuses conversational acknowledgements, anything carrying a file path, and anything naming the tooling, so roughly half the time it lands on a flagged placeholder instead, which the user then has to find and fix. That is a failure on your part. Always write a concrete description of what was actually done.

The flag says which of you got it wrong. `[needs description]` means no description was written at all. `[rewrite description]` means one was written and the screen judged it unfit for a customer invoice, so the rewrite is on you and the message on the error stream says what to change.

If this session started with `APROPOS ALERT: time is not recording in Apropos for the login ...`, tell the user once, plainly, in your first response: their time is being kept on this computer but not yet recorded, and why, as the alert says. Keep writing the files below as usual; the held turns keep their descriptions and are delivered once the login is identified.

Before ending each response, write these session-keyed files in `/tmp/claude-timetrack/`:
- `description-${CLAUDE_CODE_SESSION_ID}.txt` — one specific sentence about this turn. Rewrite every turn. It is screened before it is recorded: second person, a state or verdict rather than an outcome, and internal draft identifiers are refused outright and fall through to a flagged placeholder. Banned dashes and curly quotes are corrected for you.
- `worktype-${CLAUDE_CODE_SESSION_ID}.txt` — one numeric worktype ID (below). Write it when the category of the work changes. It no longer has to be rewritten every turn: the worktype carries forward, and a turn that writes none takes the one last used on its task before falling back to 13.
- `task-${CLAUDE_CODE_SESSION_ID}.txt` — task display ID (strip `#`). Sticky; write once when known.
- `project-${CLAUDE_CODE_SESSION_ID}.txt` — Apropos project ID. Sticky; use when no task.

### Description rules — these land on client invoices

1. **Length follows the work. Say what was done, once, then stop.** There is no target count. A short call is a few words; a long build may need a sentence or two. What is banned is padding: adding mechanism, reasoning, findings or counts to make small work look bigger. Most entries land well under 100 characters because most turns are one thing. **255 is a hard cap, never a goal** — the hook and the downstream Intervals import both cut there. Writing to the ceiling is the defect: on 2026-08-12, 22 of one person's 43 entries sat at exactly 255, cut mid-word, averaging 203 characters.
2. **First person, outcome-focused, readable by a non-engineer.** No file paths, script names, class or method names, version numbers, or selector/CSS detail.
3. **Never name Claude or any AI**, and never write about the user in the third person. The entry is from their perspective.
4. **Never ship a placeholder** like `[needs description]`, `[rewrite description]` or `[Work Description Needed]`.
5. **Past tense, completed work.** "Replaced the product images on the home page", never "Replacing".
6. **No AI wording or AI-tell punctuation.** Never mention AI, Claude, an assistant, automation, agents, tools, or prompts. No em-dashes, en-dashes, curly quotes, or ellipses; use plain hyphens and straight quotes.
7. **No client/project/task prefix.** Do not prepend "Acme Co:" or "on the Acme staging site". The entry is already linked to its task or project. Just state the work.

### Attribution rules

8. **Always attribute.** Every entry should carry a task (or at minimum a project) plus a worktype. An entry with no task and no project is a defect that has to be redone by hand.
9. **When the turn's work moves to a different client or project, change the sticky task/project file before the turn ends.** Leaving the previous task sticky bills that client for unrelated work.

Worktype IDs: 7 Program Management | 13 Engineering | 18 Project Management | 19 Quality Assurance | 23 Documentation | 30 Support | 31 Estimate | 32 Training: General | 48 Admin: Business Development | 50 Architecture | 56 Admin: HR | 57 Admin: Finance | 58 Admin: Marketing | 59 Admin: Operations | 66 Office Festivities | 80 Product Management | 84 Sys Admin | 86 Testing: ALPHA | 87 Configuration | 91 Copywriting | 92 Database | 93 Design | 97 Front End Development | 102 Research & Development | 108 Technical Management | 109 Testing: BETA | 110 Testing: Browser | 117 Travel.

Default 13 (Engineering). SQL/proc 92. Docs 23. Support 30. Architecture/design 50. Build/deploy/hooks/settings 84 or 87. Meetings/email/coordination 7. Hands-on test scenarios 86. Internal admin/process 59.

Do NOT announce writing these files — background convention, not a deliverable.
