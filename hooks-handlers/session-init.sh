#!/usr/bin/env bash
# apropos plugin — SessionStart hook. Injects the per-turn convention. Exit 0.
#
# ORDER AND TIME. Claude Code cancels this hook at its 30 second timeout and discards
# everything it printed. QA measured 35.2 s on a machine with 20 held turns, the person lookup
# unreachable and the daily sweep due, because the lookup, the flush and the sweep all ran
# before anything was printed: the convention and the alert, the two things this hook exists
# to show, were lost exactly when they mattered most. So the convention is printed first, the
# alerts straight after the one lookup they depend on, and the slow work comes last, against
# a budget and a hard limit that end it well inside the timeout. Anything it does not reach
# stays queued for the next turn.
SI_T0=$SECONDS
# Everything, the slow work included, is finished by this many seconds into the hook.
SI_BUDGET="${APROPOS_SESSION_BUDGET_SECS:-25}"
# No delivery is started within this many seconds of the end of the budget, so one already
# under way can normally finish rather than be cut off by the hard limit. 20 because one real
# write was measured at 12 to 20 seconds; the first value, 8, let a write start with too little
# time left, and a write cut off after its insert had committed is sent again next time. The
# daily pass's closing flush is held to the same margin. Whatever this leaves is delivered by
# the next turns.
SI_DELIVERY="${APROPOS_SESSION_DELIVERY_SECS:-20}"
# The daily repair pass does not run inside this budget. Until 0.2.10 it did, and with a slow
# correction (20 seconds) a start repaired almost nothing, so flagged entries aged out
# unrepaired. It now runs in the background, launched here, under its own time limit,
# APROPOS_SWEEP_RUN_SECS (lib/ledger.sh), its own hard limit and its own lock.
# The hard limit asks the slow work to stop, then kills it this many seconds later if it has
# not, so a child that ignores the request cannot hold the hook past Claude Code's 30 second
# timeout: the budget's 25 plus this 2 still leaves the alerts time to print. 1 was considered
# and not taken: work that does stop when asked was measured taking 0.5 to 2.5 seconds, on a
# busy machine, to finish writing and release its lock, and 1 would usually kill it partway.
SI_KILL_GRACE="${APROPOS_SESSION_KILL_GRACE_SECS:-2}"
# Read as decimal numbers, so a value written with a leading zero (025) is not taken for octal.
if [[ "$SI_KILL_GRACE" =~ ^[0-9]{1,6}$ ]]; then SI_KILL_GRACE=$(( 10#$SI_KILL_GRACE )); else SI_KILL_GRACE=2; fi
if [[ "$SI_BUDGET" =~ ^[0-9]{1,6}$ ]]; then SI_BUDGET=$(( 10#$SI_BUDGET )); else SI_BUDGET=25; fi
if [[ "$SI_DELIVERY" =~ ^[0-9]{1,6}$ ]]; then SI_DELIVERY=$(( 10#$SI_DELIVERY )); else SI_DELIVERY=20; fi
si_left() { printf '%s' $(( SI_BUDGET - (SECONDS - SI_T0) )); }

P="${CLAUDE_PLUGIN_ROOT:-}"; P="${P//\\//}"
if [[ -z "$P" || ! -f "$P/hooks-handlers/convention.md" ]]; then
  P="$(find "${HOME}/.claude/plugins" -path "*apropos*/hooks-handlers/convention.md" 2>/dev/null | head -1 | sed 's|/hooks-handlers/convention.md$||')"
fi

QUEUE="${HOME}/.claude/apropos-time/pending.tsv"

# 1. The convention, before anything that can take time.
[[ -n "$P" && -f "$P/hooks-handlers/convention.md" ]] && cat "$P/hooks-handlers/convention.md"

# 2. Who is recording. Looked up here with --force, so a person whose Apropos account has
# just been put right is picked up at the start of their next session, and their kept turns
# are delivered straight away. Bounded by the lookup's own time limit (lib/writer.sh). The
# libraries only define functions.
HAVE_LIBS=0
PERSON_ALERT_LOGIN=""; PERSON_ALERT_CAUSE=""; PERSON_ALERT_ADVICE=""
if [[ -n "$P" && -f "$P/hooks-handlers/lib/queue.sh" && -f "$P/hooks-handlers/lib/writer.sh" && -f "$P/hooks-handlers/lib/person.sh" ]]; then
  HAVE_LIBS=1
  source "$P/hooks-handlers/lib/queue.sh"
  source "$P/hooks-handlers/lib/writer.sh"
  source "$P/hooks-handlers/lib/person.sh"
  if [[ -f "$P/hooks-handlers/lib/ledger.sh" ]]; then
    source "$P/hooks-handlers/lib/ledger.sh"
    # Today counts as a working day: the repair warning below counts only days with a start.
    sweep_start_day_record
  fi
  PERSON_ALERT_LOGIN="$(apropos_login)"
  if ! person_resolve --force "$PERSON_ALERT_LOGIN" >/dev/null 2>&1; then
    PERSON_ALERT_CAUSE="$PERSON_CAUSE"; PERSON_ALERT_ADVICE="$PERSON_ADVICE"
  fi
fi

# 3. The alerts that need nothing slow.
#
# The day's audit for the catch-all. The recorder warns on the turn it happens, but that is
# one notice on one turn: it scrolls, the session ends, nobody looks. Reporting the running
# tally at every session start makes it a backstop instead of a single notice, so client work
# cannot reach the end of a day booked to an internal account without somebody having been
# told, repeatedly.
#
# Yesterday's tallies are pruned here rather than by a scheduled job, because this hook is
# the only thing guaranteed to run. Kept for a week so a Monday can still see Friday.
CATCHALL_DIR="${HOME}/.claude/apropos-time"
CATCHALL_TODAY="$CATCHALL_DIR/catchall-$(date -u +%Y-%m-%d).tsv"
if [[ -d "$CATCHALL_DIR" ]]; then
  # The recorder's tally of withheld flags is kept for the same week.
  find "$CATCHALL_DIR" -maxdepth 1 \( -name 'catchall-*.tsv' -o -name 'withheld-flags-*.tsv' \) -mtime +7 -delete 2>/dev/null || true
fi
if [[ -s "$CATCHALL_TODAY" ]]; then
  n=$(grep -c . "$CATCHALL_TODAY" 2>/dev/null || echo 0)
  if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
    echo ""
    echo "APROPOS: $n time entr(y/ies) today went to your catch-all task because no task was stated and no .apropos-task marker was found. Client work booked as internal overhead under-bills the customer and misreports the day, so correct these before the day closes. The folders they came from:"
    awk -F'	' '{print $2}' "$CATCHALL_TODAY" 2>/dev/null | sort -u | sed 's/^/  - /'
    echo "  Put a .apropos-task file holding the task number at the top of a folder and everything under it attributes itself."
  fi
fi

# A person who cannot be identified is told at every session start, by login and cause, and
# told that nothing is lost.
if [[ -n "$PERSON_ALERT_CAUSE" ]]; then
  held=0
  [[ -f "$QUEUE" ]] && held=$(grep -c '^unresolved:' "$QUEUE" 2>/dev/null)
  [[ "$held" =~ ^[0-9]+$ ]] || held=0
  echo ""
  if [[ -n "$PERSON_ALERT_LOGIN" ]]; then
    echo "APROPOS ALERT: time is not recording in Apropos for the login ${PERSON_ALERT_LOGIN}, because ${PERSON_ALERT_CAUSE}. Every turn is still kept on this computer ($held so far) and will be recorded once you are identified. ${PERSON_ALERT_ADVICE}"
  else
    # A turn kept with no login can never be identified later, so nothing is promised.
    echo "APROPOS ALERT: time is not recording in Apropos, because ${PERSON_ALERT_CAUSE}. Turns are kept on this computer ($held so far), but without a login they cannot be sent to Apropos later, so record this time yourself with /apropos:time once the login is fixed. ${PERSON_ALERT_ADVICE}"
  fi
fi

# 4. The slow work, silent and bounded: deliver what earlier sessions left queued, then launch
# the once-a-day repair pass in the background.
#
# APROPOS_FLUSH_DEADLINE stops q_flush starting a delivery once too little of the budget is
# left for it to finish. The coreutils timeout (never Windows' timeout.exe; see
# apropos_timeout_exe) is the hard limit behind that, for a delivery that runs long. A flush
# cut off there loses nothing: every line stays in the queue until it is done with. Where no
# such timeout exists the deadline is the only bound.
#
# The repair pass runs the per-turn hook as a real subprocess with its event piped in as JSON,
# rather than sourcing it, because that file reads its event from stdin and ends by exiting,
# which would exit this hook too if sourced. It is launched in the background with every
# stream pointed away from this hook, so this hook ends at once and Claude Code does not wait
# for it. It is given its own deadline, APROPOS_SWEEP_RUN_SECS from now, and where a coreutils
# timeout exists a hard limit APROPOS_SWEEP_KILL_AFTER_SECS (default 30) after that. It is
# launched only while a pass is due today, the person is identified, and no live pass holds the
# lock (sweep_held), so a start during a running pass launches nothing; sweep_due and the lock
# inside it keep it to one pass a day at a time even when several sessions start together. A
# pass ended early, by its limit or by the program being closed, is carried on by the next
# start's. Each start logs what it decided, and why when it launched nothing, as one "session"
# line in the pass log: counts and reasons only.
SI_TO=""
(( HAVE_LIBS )) && SI_TO="$(apropos_timeout_exe 2>/dev/null)"
si_bounded() {   # si_bounded <seconds> <command...>
  local s="$1"; shift
  (( s >= 1 )) || return 0
  if [[ -n "$SI_TO" ]]; then "$SI_TO" -k "$SI_KILL_GRACE" "$s" "$@"; else "$@"; fi
}
left="$(si_left)"
if (( HAVE_LIBS )) && (( left > SI_DELIVERY )); then
  export APROPOS_FLUSH_DEADLINE=$(( $(date -u +%s) + left - SI_DELIVERY ))
  si_bounded "$left" bash -c 'source "$1/hooks-handlers/lib/queue.sh"; source "$1/hooks-handlers/lib/writer.sh"; source "$1/hooks-handlers/lib/person.sh"; q_flush "$2" write_entry' _ "$P" "$QUEUE" >/dev/null 2>&1 </dev/null || true
fi
unset APROPOS_FLUSH_DEADLINE APROPOS_SWEEP_DEADLINE
if (( HAVE_LIBS )) && declare -F sweep_due >/dev/null && [[ -f "$P/hooks-handlers/time-track-per-turn.sh" ]]; then
  si_launched=0
  if ! sweep_due; then
    sweep_log "session launch=no reason=not-due"
  elif [[ -n "$PERSON_ALERT_CAUSE" ]]; then
    sweep_log "session launch=no reason=no-person"
  elif sweep_held; then
    sweep_log "session launch=no reason=busy"
  else
    si_launched=1
    sweep_log "session launch=yes"
    # Both read as numbers by lib/ledger.sh.
    si_run="$APROPOS_SWEEP_RUN_SECS"; si_after="$APROPOS_SWEEP_KILL_AFTER_SECS"
    (
      export APROPOS_SWEEP_DEADLINE=$(( $(date -u +%s) + si_run ))
      if [[ -n "$SI_TO" ]]; then
        printf '{"hook_event_name":"Sweep"}' | "$SI_TO" -k "$SI_KILL_GRACE" $(( si_run + si_after )) bash "$P/hooks-handlers/time-track-per-turn.sh"
      else
        printf '{"hook_event_name":"Sweep"}' | bash "$P/hooks-handlers/time-track-per-turn.sh"
      fi
    ) </dev/null >/dev/null 2>&1 &
    # Test hook: where the launched pass's process numbers are written, so a test can wait for it.
    [[ -n "${APROPOS_SWEEP_LAUNCH_LOG:-}" ]] && printf '%s\n' "$!" >> "$APROPOS_SWEEP_LAUNCH_LOG" 2>/dev/null
    disown 2>/dev/null || true
  fi
  # A log no pass has trimmed, on a computer where the pass does not run, is trimmed here, but
  # only by a start that launched no pass. The trim rewrites the file without the pass's lock,
  # so straight after a launch it could lose a line the pass had just written; a launched pass
  # trims the log itself when it ends.
  (( si_launched )) || { sweep_log_trim_due && sweep_log_trim; }
fi

# Flagged entries left waiting are reported by how long the oldest has waited, counted in
# working days: days with at least one session start, after the day it was flagged, today
# included (sweep_waiting in lib/ledger.sh). Until 0.2.10 this keyed on whether the daily pass
# had completed, so a pass that completed while repairing nothing kept it silent however long
# the entries waited, and a weekend counted toward the two days. A person who cannot be
# identified is already told why nothing records, and the pass cannot run for them anyway.
# Who to send the log to. The shipped copy names no one, so the default is a role; a team names
# its own contact with APROPOS_SUPPORT_CONTACT. Line breaks and other control characters in it
# are read as spaces, so the alert stays one line.
si_contact="${APROPOS_SUPPORT_CONTACT:-}"
si_contact="${si_contact//[[:cntrl:]]/ }"
si_contact="${si_contact#"${si_contact%%[![:space:]]*}"}"; si_contact="${si_contact%"${si_contact##*[![:space:]]}"}"
[[ -n "$si_contact" ]] || si_contact="the person who looks after time recording"
# Where the files are, in the form for macOS and Git Bash and the form Windows Explorer takes.
si_at_u="~/.claude/apropos-time"; si_at_w='%USERPROFILE%\.claude\apropos-time'
if (( HAVE_LIBS )) && [[ -z "$PERSON_ALERT_CAUSE" ]] && declare -F sweep_waiting >/dev/null; then
  if sweep_waiting; then
    # The flag texts are named so the entries can be found in Apropos. Entries flagged today have
    # had no day's pass yet, so only those flagged before today are to be corrected by hand
    # (SW_WAIT_OLD). This line counts working days only; the age limit, which is calendar days
    # (the recorder's APROPOS_SWEEP_DAYS, read as a number by lib/ledger.sh), has a line of its
    # own, so the two kinds of day are never mixed in one sentence.
    (( SW_WAIT_DAYS == 1 )) && si_wd="1 working day" || si_wd="${SW_WAIT_DAYS} working days"
    if (( SW_WAIT_N == 1 )); then
      si_w="1 flagged time entry is still waiting to be filled in, for ${si_wd}. In Apropos it begins"; si_it="it"
    else
      si_w="${SW_WAIT_N} flagged time entries are still waiting to be filled in, the oldest for ${si_wd}. In Apropos they begin"; si_it="them"
    fi
    # Entries flagged before today are found by their start time when some were flagged today: the
    # search for the flag texts lists both kinds (SW_WAIT_OLD_ST, the earliest of the older ones).
    si_when=""
    if (( SW_WAIT_OLD > 0 && SW_WAIT_OLD < SW_WAIT_N )) && sweep_local_minute "$SW_WAIT_OLD_ST"; then
      (( SW_WAIT_OLD == 1 )) && si_when=" (it begins at ${SW_MIN} in the search results)" || si_when=" (the earliest begins at ${SW_MIN} in the search results)"
    fi
    if (( SW_WAIT_OLD >= SW_WAIT_N )); then
      si_fix="correct ${si_it} in Apropos by hand and send"
    elif (( SW_WAIT_OLD == 1 )); then
      si_fix="correct the one flagged before today${si_when} in Apropos by hand and send"
    elif (( SW_WAIT_OLD > 1 )); then
      si_fix="correct the ${SW_WAIT_OLD} flagged before today${si_when} in Apropos by hand and send"
    else
      si_fix="send"
    fi
    echo ""
    echo "APROPOS ALERT: ${si_w} with [needs description] or [rewrite description], so search for those words to find ${si_it}. If this alert is still here on the next working day, ${si_fix} ${si_at_u}/sweep.log (on Windows ${si_at_w}\sweep.log) to ${si_contact}."
    echo "APROPOS: a flagged time entry is filled in automatically only until it is ${APROPOS_SWEEP_DAYS} calendar days old; after that its start time is listed in ${si_at_u}/unrepaired.tsv (on Windows ${si_at_w}\unrepaired.tsv)."
  fi
fi

# Flagged entries the pass has given up on, because they passed the age limit, their session
# can never give them a description, or they are no longer in Apropos at their start time, are
# listed in a report on this computer by start time (sweep_report_add). The person is told how
# many were listed on this working day or the one before, so each is mentioned for a day or two
# and then not again.
if (( HAVE_LIBS )) && [[ -z "$PERSON_ALERT_CAUSE" ]] && declare -F sweep_report_recent >/dev/null; then
  if sweep_report_recent; then
    si_why="older than ${APROPOS_SWEEP_DAYS} calendar days, had no description to be found, or was no longer in Apropos at its recorded start time"
    if (( SW_REPORT_N == 1 )); then
      si_r="1 flagged time entry was left unrepaired by the daily pass, because it was ${si_why}. In Apropos it begins with [needs description] or [rewrite description] unless corrected since. Its start time is listed in ${si_at_u}/unrepaired.tsv (on Windows ${si_at_w}\unrepaired.tsv); correct it in Apropos by hand if it is still flagged."
    else
      si_r="${SW_REPORT_N} flagged time entries were left unrepaired by the daily pass, because each was ${si_why}. In Apropos they begin with [needs description] or [rewrite description] unless corrected since. Their start times are listed in ${si_at_u}/unrepaired.tsv (on Windows ${si_at_w}\unrepaired.tsv); correct any still flagged in Apropos by hand."
    fi
    echo ""
    echo "APROPOS: ${si_r}"
  fi
fi

# 5. Entries the write path itself has not delivered, counted after the flush so an entry
# that was merely waiting for this session is not reported as a failure. Entries held only
# because the person is not identified are reported by the alert above, with their real cause.
if [[ -f "$QUEUE" ]]; then
  if [[ -n "$PERSON_ALERT_CAUSE" ]]; then
    pending=$(grep -v '^unresolved:' "$QUEUE" 2>/dev/null | grep -c .)
  else
    pending=$(grep -c . "$QUEUE" 2>/dev/null)
  fi
  if [[ "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]]; then
    echo ""
    echo "APROPOS ALERT: $pending time entr(y/ies) are queued locally and NOT yet in Apropos (~/.claude/apropos-time/pending.tsv). The write path may be failing - investigate before more time is lost."
  fi
fi
exit 0
