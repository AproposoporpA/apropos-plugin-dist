#!/usr/bin/env bash
# Flagged-entry ledger.
#
# The recorder knows an entry is flagged at the moment it writes it, and then forgets.
# Once the activity closes, nothing can find that entry again, so it stays flagged until
# a person cleans the day by hand. This records the pairing that makes a later repair
# possible: the entry's start time, and the session and working directory whose transcript holds
# what the turn actually did.
#
# Local to the machine, like the rest of the plugin's state, because the transcript it
# points at is local too.

APROPOS_LEDGER_FILE="${APROPOS_LEDGER_FILE:-$HOME/.claude/apropos-time/flagged.tsv}"

_fl_init() { mkdir -p "$(dirname "$APROPOS_LEDGER_FILE")" 2>/dev/null || true; [[ -f "$APROPOS_LEDGER_FILE" ]] || : > "$APROPOS_LEDGER_FILE"; }

# fl_record <start_utc> <session_id> <cwd> <epoch>
# Keyed on the entry's start time, not its id. The id does not exist yet when the flag is
# written: record_turn enqueues and returns, and the id is only parsed out later inside
# write_entry, which knows nothing about the session. The start time enqueued here becomes
# the entry's StartTime unchanged, so person plus start identifies the row.
#
# Recording the same entry twice keeps one row: a turn can flag the same open entry
# repeatedly, and a ledger that grew a row each time would make the sweep do the same
# work over and over.
fl_record() {
  _fl_init
  local key="$1"
  [[ -n "${key//[[:space:]]/}" ]] || return 1
  fl_clear "$key"
  printf '%s\t%s\t%s\t%s\n' "$key" "$2" "$3" "$4" >> "$APROPOS_LEDGER_FILE"
}

# fl_pending, every entry still awaiting repair, one per line, tab separated.
fl_pending() { _fl_init; cat "$APROPOS_LEDGER_FILE"; }

# fl_clear <start_utc>, drop an entry once it has been repaired or given up on.
fl_clear() {
  _fl_init
  local id="$1" tmp
  tmp="$(mktemp)" || return 1
  awk -F'\t' -v id="$id" '$1 != id' "$APROPOS_LEDGER_FILE" > "$tmp" 2>/dev/null
  mv "$tmp" "$APROPOS_LEDGER_FILE"
}

# fl_clear_many <start_utc>..., drop several entries in one rewrite. Every rewrite costs
# three subprocesses, and a subprocess costs a large fraction of a second on the Windows
# shell this ships to, so the daily pass retiring twenty entries one at a time would spend
# its whole start-up budget on bookkeeping.
fl_clear_many() {
  (( $# > 0 )) || return 0
  _fl_init
  local tmp
  tmp="$(mktemp)" || return 1
  printf '%s\n' "$@" | awk -F'\t' 'NR == FNR { drop[$0] = 1; next } !($1 in drop)' - "$APROPOS_LEDGER_FILE" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$APROPOS_LEDGER_FILE"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# THE DAILY PASS'S OWN BOOKKEEPING.
#
# The pass over the whole ledger runs at session start, inside a start-up budget, and in
# 0.2.9 it had three weaknesses: it marked itself done only at the very end, so a pass cut
# off by the time limit started again from the oldest entry next time and could be cut off
# at the same place forever; it kept no record of how it went, so a pass that never finished
# looked exactly like one that was never due; and nothing stopped several session starts
# running it together. These files fix that. All of them are local, small, and hold start
# times and counts only, never description text or anything that identifies a client.
#
#   last-sweep          the date of the last pass that revisited every entry (done for today)
#   sweep-visited.tsv   date TAB start time, for each entry already revisited today, so a pass
#                       that was cut off resumes at the next entry instead of the first. An
#                       optional third field records a correction still in progress: "tried",
#                       "second" and "tried-second" (see sweep_visited_load)
#   sweep.log           one line when a pass starts and one when it ends, with its counts and
#                       how it ended; a start with no end means the pass was killed at the
#                       hook's hard limit
#   last-sweep.lock     held while a pass runs
#   sweep-since         on a computer with no completed pass yet, the first day one was found
#                       overdue, so session start can tell how long it has been waiting
APROPOS_SWEEP_STAMP="${APROPOS_SWEEP_STAMP:-$HOME/.claude/apropos-time/last-sweep}"
APROPOS_SWEEP_VISITED="${APROPOS_SWEEP_VISITED:-$HOME/.claude/apropos-time/sweep-visited.tsv}"
APROPOS_SWEEP_LOG="${APROPOS_SWEEP_LOG:-$HOME/.claude/apropos-time/sweep.log}"
APROPOS_SWEEP_SINCE="${APROPOS_SWEEP_SINCE:-${APROPOS_SWEEP_STAMP%/*}/sweep-since}"
# Session start warns once the pass has gone this many days without completing.
APROPOS_SWEEP_ALERT_DAYS="${APROPOS_SWEEP_ALERT_DAYS:-2}"
[[ "$APROPOS_SWEEP_ALERT_DAYS" =~ ^[0-9]+$ ]] || APROPOS_SWEEP_ALERT_DAYS=2
# A pass is held inside a 30 second hook, so a lock older than this belongs to a pass that
# was killed and is taken over.
APROPOS_SWEEP_LOCK_STALE_SECS="${APROPOS_SWEEP_LOCK_STALE_SECS:-90}"
# The log keeps the most recent lines only.
APROPOS_SWEEP_LOG_KEEP="${APROPOS_SWEEP_LOG_KEEP:-200}"

_sw_today() { date -u +%Y-%m-%d; }

# sweep_due - true unless a pass has already revisited every entry today. A stamp file
# rather than per-session state, because one person often runs several sessions at once.
sweep_due() {
  [[ -s "$APROPOS_SWEEP_STAMP" ]] || return 0
  local last; last="$(cat "$APROPOS_SWEEP_STAMP" 2>/dev/null)"
  [[ "$last" == "$(_sw_today)" ]] && return 1
  return 0
}

# sweep_mark - done for today.
sweep_mark() {
  mkdir -p "$(dirname "$APROPOS_SWEEP_STAMP")" 2>/dev/null || true
  _sw_today > "$APROPOS_SWEEP_STAMP" 2>/dev/null || true
  rm -f "$APROPOS_SWEEP_SINCE" 2>/dev/null || true
}

# sweep_visited_load - reads today's resume list into three newline-framed lists:
#   SW_VISITED  start times already dealt with today, skipped by this pass
#   SW_TRIED    start times whose correction was being sent when an earlier pass was cut off;
#               this pass sends every untried row first and retries these once, last
#   SW_SECOND   start times whose first flag guess was refused just before time ran out, so
#               this pass sends them the second guess only
# "tried-second" puts a start time on both SW_TRIED and SW_SECOND: its second guess alone was
# being sent when a pass was cut off, so its retry is the second guess alone too, rather than
# both guesses again, the first of which is already known to be refused.
# The last line for a start time wins, since an entry is recorded again each time it moves on.
# A list left from an earlier day is emptied, since every day's pass revisits everything again.
# Sets globals rather than printing, so the caller needs no subshell.
sweep_visited_load() {
  SW_VISITED=$'\n'; SW_SECOND=$'\n'; SW_TRIED=$'\n'
  mkdir -p "$(dirname "$APROPOS_SWEEP_VISITED")" 2>/dev/null || true
  [[ -s "$APROPOS_SWEEP_VISITED" ]] || return 0
  local today d k tag stale=0 keep="" nl=$'\n'
  today="${SW_TODAY:-$(_sw_today)}"
  while IFS=$'\t' read -r d k tag; do
    if [[ "$d" != "$today" ]]; then stale=1; continue; fi
    [[ -n "$k" ]] || continue
    if [[ -n "$tag" ]]; then keep+="$d"$'\t'"$k"$'\t'"$tag"$'\n'; else keep+="$d"$'\t'"$k"$'\n'; fi
    SW_VISITED="${SW_VISITED//"$nl$k$nl"/$nl}"
    SW_SECOND="${SW_SECOND//"$nl$k$nl"/$nl}"
    SW_TRIED="${SW_TRIED//"$nl$k$nl"/$nl}"
    case "$tag" in
      second)       SW_SECOND+="$k$nl" ;;
      tried)        SW_TRIED+="$k$nl" ;;
      tried-second) SW_TRIED+="$k$nl"; SW_SECOND+="$k$nl" ;;
      *)            SW_VISITED+="$k$nl" ;;
    esac
  done < "$APROPOS_SWEEP_VISITED"
  if (( stale )); then printf '%s' "$keep" > "$APROPOS_SWEEP_VISITED" 2>/dev/null; fi
  return 0
}

# sweep_visit <start_utc> [tried|second|tried-second], record that an entry has been revisited today. A
# single append, so a pass killed straight after loses nothing.
#
# Written BEFORE a correction is sent, as well as after: "tried" first, so a pass killed in the
# middle of a slow correction moves on to the untried entries at the next start, instead of
# spending that start on the same entry again, and comes back to it once, last. That retry is
# recorded as done before it is sent, so an entry is tried at most twice a day and a slow one
# cannot hold the day's pass open. Nothing is written twice: the amend script writes only
# while the entry still holds the flag, so a retry of a correction that had in fact landed is
# refused, and the entry leaves the list. An entry whose correction never landed is tried
# again by the next day's pass, and by its own session's turns.
# No subprocess here: this runs once per row. sweep_visited_load, called once at the start
# of every pass, has already made the folder.
sweep_visit() {
  if [[ -n "${2:-}" ]]; then
    printf '%s\t%s\t%s\n' "${SW_TODAY:-$(_sw_today)}" "$1" "$2" >> "$APROPOS_SWEEP_VISITED" 2>/dev/null || true
  else
    printf '%s\t%s\n' "${SW_TODAY:-$(_sw_today)}" "$1" >> "$APROPOS_SWEEP_VISITED" 2>/dev/null || true
  fi
}

# _sw_day_epoch <YYYY-MM-DD> -> that day's midnight UTC as epoch seconds (GNU date, then BSD).
_sw_day_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null
}

# sweep_overdue - true when the pass has gone APROPOS_SWEEP_ALERT_DAYS days or more without
# completing, counting today; sets SW_OVERDUE_DAYS. A pass that last completed yesterday is
# merely due today, and is not overdue. A computer that has never completed one is counted
# from the first day it was asked (sweep-since), so its first day is never reported.
sweep_overdue() {
  SW_OVERDUE_DAYS=0
  local today last a b extra=0
  today="$(_sw_today)"
  last="$(cat "$APROPOS_SWEEP_STAMP" 2>/dev/null)"
  if [[ ! "$last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    last="$(cat "$APROPOS_SWEEP_SINCE" 2>/dev/null)"
    if [[ ! "$last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      mkdir -p "$(dirname "$APROPOS_SWEEP_SINCE")" 2>/dev/null || true
      printf '%s' "$today" > "$APROPOS_SWEEP_SINCE" 2>/dev/null || true
      return 1
    fi
    # The first day asked is itself a day without a completed pass.
    extra=1
  fi
  [[ "$last" == "$today" ]] && (( ! extra )) && return 1
  a="$(_sw_day_epoch "$last")"; b="$(_sw_day_epoch "$today")"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
  SW_OVERDUE_DAYS=$(( (b - a) / 86400 + extra ))
  (( SW_OVERDUE_DAYS >= APROPOS_SWEEP_ALERT_DAYS ))
}

sweep_visited_reset() { rm -f "$APROPOS_SWEEP_VISITED" 2>/dev/null || true; }

# sweep_log <word> [key=value...], one line in the pass log: UTC time, the word, the counts.
# Callers pass counts and outcomes only; nothing else belongs here.
sweep_log() {
  mkdir -p "$(dirname "$APROPOS_SWEEP_LOG")" 2>/dev/null || true
  local IFS=' '
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$APROPOS_SWEEP_LOG" 2>/dev/null || true
}

# sweep_log_trim, keep the log to its last APROPOS_SWEEP_LOG_KEEP lines. Run at the end of a
# pass rather than on every line, and only when the log has grown to twice that.
sweep_log_trim() {
  [[ -f "$APROPOS_SWEEP_LOG" ]] || return 0
  local n tmp
  n=$(wc -l < "$APROPOS_SWEEP_LOG" 2>/dev/null | tr -d ' ')
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  (( n > APROPOS_SWEEP_LOG_KEEP * 2 )) || return 0
  tmp="$(mktemp)" || return 0
  tail -n "$APROPOS_SWEEP_LOG_KEEP" "$APROPOS_SWEEP_LOG" > "$tmp" 2>/dev/null && mv "$tmp" "$APROPOS_SWEEP_LOG"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# sweep_lock / sweep_unlock, one pass at a time on a machine. Every session start asks for
# the pass, and several sessions often start together; before this they all ran it at once,
# competing for the same seconds and the same entries. mkdir, as the queue lock does, because
# flock is absent from Git Bash.
#
# The lock names the process holding it (pid). A pass killed outright at the hook's hard limit
# cannot unlock, and on a busy machine that happens whenever the pass takes longer than the
# grace to log and unlock; the lock is then taken over as soon as its holder is no longer
# running, rather than turning every start away as busy until it is stale. Where the holder
# cannot be read (a lock left by an earlier version), or its number is in use by some other
# process, only staleness frees it, as before.
sweep_lock() {
  local lock="$APROPOS_SWEEP_STAMP.lock" ts now pid
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then _sweep_lock_own "$lock"; return 0; fi
  pid="$(cat "$lock/pid" 2>/dev/null)"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || kill -0 "$pid" 2>/dev/null; then
    ts="$(cat "$lock/ts" 2>/dev/null)"
    [[ "$ts" =~ ^[0-9]+$ ]] || ts="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null)"
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    now="$(date -u +%s)"
    (( now - ts > APROPOS_SWEEP_LOCK_STALE_SECS )) || return 1
  fi
  rm -rf "$lock" 2>/dev/null
  if mkdir "$lock" 2>/dev/null; then _sweep_lock_own "$lock"; return 0; fi
  return 1
}
# $$ is the hook's own process, the one the hard limit kills, even when called from a subshell.
_sweep_lock_own() { date -u +%s > "$1/ts" 2>/dev/null; printf '%s' "$$" > "$1/pid" 2>/dev/null; }
sweep_unlock() { rm -rf "$APROPOS_SWEEP_STAMP.lock" 2>/dev/null || true; }
