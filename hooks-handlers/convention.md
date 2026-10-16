## Apropos per-turn time tracking (auto-injected by the apropos plugin)

Time entries are START MARKERS only — the start of a new activity ends the prior one; Apropos derives duration from the gap. The entry is written when your response completes and is backdated to the moment the prompt arrived, so the marker sits at the real start of the work.

**ONE ENTRY PER ACTIVITY, NOT PER TURN.** An activity is a task plus worktype plus project. When a turn continues an activity that is already open, the hook AMENDS that entry rather than opening a new one, and your description REPLACES the one already there. So write a description that covers the stretch of work on that activity, not just the last thing you touched. A new entry opens when the activity changes, or after 30 minutes on the same one. The open entries are shared across every concurrent session on the machine.

This replaced one-entry-per-turn on 2026-08-13, after four days produced over three hundred entries, 185 of them under five minutes and 20 of zero length.

**Writing a specific description each turn is REQUIRED, not optional.** If you don't, the hook falls back to the last assistant message in the session transcript, preferring a labelled summary. That fallback refuses conversational acknowledgements, anything carrying a file path, and anything naming the tooling, so roughly half the time it lands on a flagged placeholder instead, which the user then has to find and fix. That is a failure on your part. Always write a concrete description of what was actually done.

The flag says which of you got it wrong. `[needs description]` means no description was written at all. `[rewrite description]` means one was written and the screen judged it unfit for a customer invoice, so the rewrite is on you and the message on the error stream says what to change.

If this session started with `APROPOS ALERT: time is not recording in Apropos for the login ...`, tell the user once, plainly, in your first response: their time is being kept on this computer but not yet recorded, and why, as the alert says. Keep writing the files below as usual; the held turns keep their descriptions and are delivered once the login is identified.

If this session started with `APROPOS ALERT: ... flagged time entr...` or `APROPOS: ... left unrepaired by the daily pass`, tell the user once, plainly, in your first response: how many entries, the flag texts to search for in Apropos, and what the line says to do. Never quote or guess at what those entries were.

Before ending each response, write these session-keyed files in `/tmp/claude-timetrack/`:
- `description-${CLAUDE_CODE_SESSION_ID}.txt` — one specific sentence about this turn. Rewrite every turn. It is screened before it is recorded: second person, a state or verdict rather than an outcome, and internal draft identifiers are refused outright and fall through to a flagged placeholder. Banned dashes and curly quotes are corrected for you.
- `worktype-${CLAUDE_CODE_SESSION_ID}.txt` — one numeric worktype ID (below). Write it when the category of the work changes. It no longer has to be rewritten every turn: the worktype carries forward, and a turn that writes none takes the one last used on its task before falling back to 13.
- `task-${CLAUDE_CODE_SESSION_ID}.txt` — the display ID of the task this work is for (strip `#`). Sticky: write it in the same turn the task becomes known, and rewrite it in the turn the work moves to another task (rules 9 to 13).
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

8. **Always attribute.** Every entry should carry a task (or at minimum a project) plus a worktype. An entry with no task and no project goes to the person's catch-all task, and every one of those has to be found and moved by hand before billing.
9. **Identify the task from the work itself, and write it that turn.** The task is known when the person names it for this work, when you read or change it (look it up, set its status or fields, post to it, estimate it), when you are dispatched to work on it, or when the branch or commit you make carries its number. Write the task file before that turn ends. Do not wait to be told again, and do not leave it for a later turn.
10. **A task that is only mentioned is not the task.** A number said in passing, a related task you read only for reference, or a follow-up you file for later does not move the time. When in doubt between two tasks, keep the one the work is for.
11. **When the work moves to a different task, client or project, rewrite the task (or project) file in that turn.** Leaving the previous task sticky bills that client for unrelated work.
12. **When the work is plainly for a client and no task is known, ask once** which task it belongs to, in one short line at the end of your reply, then write it. Internal work with no task of its own may stay on the catch-all.
13. **If no task or project is written and no folder marker applies, the turn goes to the catch-all**, and the person is shown it in the day's list of catch-all entries. The recorder does not work out a task from what the turn did: only the task file, the project file or a folder marker attributes a turn, so a turn on a task you did not write is not booked to that task. A turn may start with a note, for you, that no task is set. When it does, write the task file if the work belongs to a task, and do not mention the note.

Worktype IDs: 7 Program Management | 13 Engineering | 18 Project Management | 19 Quality Assurance | 23 Documentation | 30 Support | 31 Estimate | 32 Training: General | 48 Admin: Business Development | 50 Architecture | 56 Admin: HR | 57 Admin: Finance | 58 Admin: Marketing | 59 Admin: Operations | 66 Office Festivities | 80 Product Management | 84 Sys Admin | 86 Testing: ALPHA | 87 Configuration | 91 Copywriting | 92 Database | 93 Design | 97 Front End Development | 102 Research & Development | 108 Technical Management | 109 Testing: BETA | 110 Testing: Browser | 117 Travel.

Default 13 (Engineering). SQL/proc 92. Docs 23. Support 30. Architecture/design 50. Build/deploy/hooks/settings 84 or 87. Meetings/email/coordination 7. Hands-on test scenarios 86. Internal admin/process 59.

Do NOT announce writing these files — background convention, not a deliverable.
