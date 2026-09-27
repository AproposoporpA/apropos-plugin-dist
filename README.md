# apropos

A Claude Code plugin that records your working time into Apropos as you work. It records one entry per activity (a task, a work type and a project), keeps the description readable for the people who receive the invoice, and queues entries on your machine when it cannot reach the office, so time is not lost.

This repository is the published copy of the plugin, for installing and updating. It holds only the files the plugin needs to run and to set itself up.

## Before you install

- You are on the RICO network with the R: drive mapped. Entries are written through the time recording scripts on the R: drive, so the plugin records nothing away from it; entries made off the network wait in a local queue and are delivered the next time you are connected.
- PowerShell 7 (`pwsh`) is installed. Windows PowerShell also works.
- `jq` is recommended. Setup needs it to remove an older time recording hook, as described under Install.
- Your Apropos account's username is your computer login (your Windows user name, or your Mac account name). The plugin finds your account by that login each day; it keeps no list of people, so a new team member records time as soon as their account carries their login.

## If you are not identified

If no active Apropos account carries your login, or the lookup cannot be reached before this computer has ever identified you, your time is not lost. Each turn is kept on your computer and says so, and every new session starts with an alert of this shape:

```
APROPOS ALERT: time is not recording in Apropos for the login <your login>, because <the reason>. ...
```

Ask whoever manages Apropos accounts to set the username on your account to your computer login. The kept turns start going in under your account from the next session start after that, and nothing else is needed. They go in one or two a turn so no prompt is held up, so a large backlog takes several turns to clear.

If the alert names no login, none could be read on this computer at all. Turns kept then cannot be matched to anyone later, so once the login is fixed, record that time by hand with `/apropos:time`.

## Install

Run these in Claude Code:

```
/plugin marketplace add AproposoporpA/apropos-plugin-dist
/plugin install apropos@apropos-plugin
/apropos:setup
```

Then fully quit and reopen Claude Code. `/apropos:setup` removes the older time recording instructions and hook from your Claude Code settings, backing them up first. It is safe to run again.

Removing the older instructions from `~/.claude/CLAUDE.md` does not need `jq`. Removing the older hook from `~/.claude/settings.json` does: without `jq`, setup leaves that file untouched and prints a warning, and you remove by hand the `UserPromptSubmit` hook that runs `time-track-per-turn.sh`. Otherwise both the old hook and the plugin record each turn.

## Update

```
/plugin update apropos
/reload-plugins
```

That is all an update needs.

## Moving an existing install to this copy

If you installed the plugin from its original source, move it here once. Your local time recording state lives outside the plugin folder and is kept.

Removing the marketplace in step 2 may uninstall the plugin, so nothing is recorded from step 2 until you reopen Claude Code in step 6. Do the move at a break: record `/apropos:break` first, so the minutes the move takes land on the break.

1. Make sure nothing is waiting to be delivered. In `~/.claude/apropos-time/`, `pending.tsv` must be missing or empty; if it has lines, stay on the network for a session or two until it empties. Check `pending.tsv.dead` as well: its lines are entries the plugin stopped retrying after repeated attempts. They are kept but never delivered, so have them entered in Apropos before you move.
2. Run `/plugin marketplace remove apropos-plugin`.
3. Run `/plugin marketplace add AproposoporpA/apropos-plugin-dist`.
4. Run `/plugin install apropos@apropos-plugin`.
5. Open `~/.claude/settings.json` and look for the key `extraKnownMarketplaces.apropos-plugin.source.repo`. If it is there, change it to the public copy, or Claude Code registers the original source again. If it is not there, leave the file alone.

   Before:

   ```json
   "extraKnownMarketplaces": {
     "apropos-plugin": {
       "source": { "source": "github", "repo": "AproposoporpA/apropos-plugin" }
     }
   }
   ```

   After:

   ```json
   "extraKnownMarketplaces": {
     "apropos-plugin": {
       "source": { "source": "github", "repo": "AproposoporpA/apropos-plugin-dist" }
     }
   }
   ```

6. Fully quit and reopen Claude Code. There is no need to run `/apropos:setup` again.
7. Check it is running from here. Both of these must hold, and if either does not, it is still running from the original source, so go back to step 2.

   - In `~/.claude/plugins/known_marketplaces.json`, the `apropos-plugin` entry's source repo is `AproposoporpA/apropos-plugin-dist`:

     ```
     jq -r '."apropos-plugin".source.repo' ~/.claude/plugins/known_marketplaces.json
     ```

   - In `~/.claude/plugins/installed_plugins.json`, the `gitCommitSha` of the `apropos@apropos-plugin` entry equals the public tag's commit, which the release announcement gives:

     ```
     jq -r '.plugins."apropos@apropos-plugin"[].gitCommitSha' ~/.claude/plugins/installed_plugins.json
     ```

## Commands

- `/apropos:time` records an entry by hand.
- `/apropos:break`, `/apropos:lunch` and `/apropos:out` record a break, lunch and the end of your day.
- `/apropos:setup` runs the one-time setup.

## Folder markers

A small file at the top of a folder tells the plugin where the time spent in that folder belongs. The plugin looks in the folder Claude Code is working in and in every folder above it, so every subfolder inherits a marker.

- `.apropos-task` holding a task number, for example `1234`. The nearest one wins.
- `.apropos-project` holding a project number, for work that belongs to a project rather than a task. The nearest one wins.
- `.apropos-notime` to record nothing, for example for scheduled runs. Only its presence counts, so it can be empty. It outranks everything: if one is in the working folder or in any folder above it, nothing is recorded, even when a nearer folder has an `.apropos-task` or `.apropos-project` file and even when the session names a task.

Apart from `.apropos-notime`, a task named in the session takes priority over a folder marker. When neither is given, the entry records against your catch-all task and the plugin tells you so.

## Security

No credential ships in this plugin, and it has no database access of its own. It only calls the time recording scripts on the R: drive, which hold the access and are reachable only on the RICO network. A downloaded copy of this plugin cannot write to Apropos.
