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
# daily pass is held to the same margin. Whatever this leaves is delivered by the next turns.
SI_DELIVERY="${APROPOS_SESSION_DELIVERY_SECS:-20}"
[[ "$SI_BUDGET" =~ ^[0-9]+$ ]] || SI_BUDGET=25
[[ "$SI_DELIVERY" =~ ^[0-9]+$ ]] || SI_DELIVERY=20
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
  find "$CATCHALL_DIR" -maxdepth 1 -name 'catchall-*.tsv' -mtime +7 -delete 2>/dev/null || true
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

# 4. The slow work, silent and bounded: deliver what earlier sessions left queued, then the
# once-a-day repair pass.
#
# APROPOS_FLUSH_DEADLINE stops q_flush starting a delivery once too little of the budget is
# left for it to finish. The coreutils timeout (never Windows' timeout.exe; see
# apropos_timeout_exe) is the hard limit behind that, for a delivery that runs long. A flush
# cut off there loses nothing: every line stays in the queue until it is done with. Where no
# such timeout exists the deadline is the only bound.
#
# The repair pass runs the per-turn hook as a real subprocess with its event piped in as JSON,
# rather than sourcing it, because that file reads its event from stdin and ends by exiting,
# which would exit this hook too if sourced. sweep_due inside it keeps this to once per
# machine per day even though every concurrent session's start asks for it. It is skipped
# when too little of the budget is left to be worth starting; the next session runs it.
SI_TO=""
(( HAVE_LIBS )) && SI_TO="$(apropos_timeout_exe 2>/dev/null)"
si_bounded() {   # si_bounded <seconds> <command...>
  local s="$1"; shift
  (( s >= 1 )) || return 0
  if [[ -n "$SI_TO" ]]; then "$SI_TO" "$s" "$@"; else "$@"; fi
}
left="$(si_left)"
if (( HAVE_LIBS )) && (( left > SI_DELIVERY )); then
  export APROPOS_FLUSH_DEADLINE=$(( $(date -u +%s) + left - SI_DELIVERY ))
  si_bounded "$left" bash -c 'source "$1/hooks-handlers/lib/queue.sh"; source "$1/hooks-handlers/lib/writer.sh"; source "$1/hooks-handlers/lib/person.sh"; q_flush "$2" write_entry' _ "$P" "$QUEUE" >/dev/null 2>&1 </dev/null || true
fi
left="$(si_left)"
if [[ -n "$P" && -f "$P/hooks-handlers/time-track-per-turn.sh" ]] && (( left > SI_DELIVERY )); then
  export APROPOS_FLUSH_DEADLINE=$(( $(date -u +%s) + left - SI_DELIVERY ))
  printf '{"hook_event_name":"Sweep"}' | si_bounded "$left" bash "$P/hooks-handlers/time-track-per-turn.sh" >/dev/null 2>&1 || true
fi
unset APROPOS_FLUSH_DEADLINE

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
