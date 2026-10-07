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
#   last-sweep-local    the local date of the last pass that revisited every entry (done for
#                       today). Its own file because 0.2.10 writes the UTC date to last-sweep:
#                       on a Pacific evening that is already tomorrow's date, and read here it
#                       made the next morning's pass look done (QA, 2026-09-30)
#   last-sweep          the UTC date of the same, still written for sessions not yet reloaded
#                       from 0.2.10, which read it; never read by this version
#   sweep-visited-local.tsv
#                       local date TAB start time, for each entry already revisited today, so a
#                       pass that was cut off resumes at the next entry instead of the first. An
#                       optional third field records a correction still in progress: "tried",
#                       "second" and "tried-second" (see sweep_visited_load). Its own file for
#                       the same reason: 0.2.10 keeps sweep-visited.tsv by the UTC date
#   sweep.log           one line when a pass starts and one when it ends, with its counts and
#                       how it ended; a start with no end means the pass was killed at the
#                       hook's hard limit
#   last-sweep.lockd/   the pass's lock, a numbered directory per holder (see sweep_lock)
#   start-days          the local dates this computer had a session start, for counting
#                       working days (see sweep_waiting)
#   unrepaired.tsv      entries that left the list unrepaired, by start time (see
#                       sweep_report_add); the one file here meant for the person to read
#   sweep-since         used until 0.2.10 for the old overdue warning; removed when a pass
#                       completes
APROPOS_SWEEP_STAMP="${APROPOS_SWEEP_STAMP:-$HOME/.claude/apropos-time/last-sweep}"
APROPOS_SWEEP_DAY_FILE="${APROPOS_SWEEP_DAY_FILE:-${APROPOS_SWEEP_STAMP}-local}"
APROPOS_SWEEP_VISITED="${APROPOS_SWEEP_VISITED:-$HOME/.claude/apropos-time/sweep-visited-local.tsv}"
APROPOS_SWEEP_LOG="${APROPOS_SWEEP_LOG:-$HOME/.claude/apropos-time/sweep.log}"
APROPOS_SWEEP_SINCE="${APROPOS_SWEEP_SINCE:-${APROPOS_SWEEP_STAMP%/*}/sweep-since}"

# _sw_num <name> <default> - reads the setting <name> as a whole number. A value written with
# leading zeros (0900) is read as the decimal number it looks like: bash reads 0900 as an
# octal number with a digit octal does not have, and every sum using it failed. A value that
# is not a plain number of up to 12 digits takes the default. No subprocess.
_sw_num() {
  local _sn_v="${!1:-}"
  if [[ "$_sn_v" =~ ^[0-9]{1,12}$ ]]; then printf -v "$1" '%s' "$(( 10#$_sn_v ))"; else printf -v "$1" '%s' "$2"; fi
}

# Session start warns once the oldest flagged entry still waiting has waited this many working
# days (days with at least one session start) since the day it was flagged.
_sw_num APROPOS_SWEEP_ALERT_DAYS 2
# How many calendar days a flagged entry stays on the list (the recorder's sweep_prune). Read
# here too because session start prints it, and a value that is not a number must never read as
# 0 there or in the pass, where 0 would age out every entry at once.
_sw_num APROPOS_SWEEP_DAYS 7
# The log keeps its correction lines ("amend", one per correction call, often 100 or more a
# day) to the most recent APROPOS_SWEEP_LOG_KEEP, and every other line, the passes' start and
# end lines and session start's decisions, for APROPOS_SWEEP_LOG_DAYS days (see sweep_log_trim).
_sw_num APROPOS_SWEEP_LOG_KEEP 200
_sw_num APROPOS_SWEEP_LOG_DAYS 14

# _sw_today - prints today's local date. The pass's day, the day it marks done and the days
# counted as working days (start-days, below) all go by the local date, so they turn over
# together at local midnight. Until this release the pass went by the UTC date, which on the US west
# coast turns over in the afternoon. Callers that run often use _sw_local_day, which costs no
# subprocess, instead.
_sw_today() { _sw_local_day; printf '%s' "$SW_DAY"; }

# sweep_due - true unless a pass has already revisited every entry today. A stamp file
# rather than per-session state, because one person often runs several sessions at once.
# Reads this version's own file, the local date, never last-sweep (see the list above).
sweep_due() {
  [[ -s "$APROPOS_SWEEP_DAY_FILE" ]] || return 0
  local last=""
  { read -r last < "$APROPOS_SWEEP_DAY_FILE"; } 2>/dev/null
  _sw_local_day
  [[ "$last" == "$SW_DAY" ]] && return 1
  return 0
}

# sweep_mark - done for today: the local date in this version's file, and the UTC date in
# last-sweep, so a session not yet reloaded from 0.2.10 also sees the day's pass as done, by its
# own reading of the day.
sweep_mark() {
  mkdir -p "$(dirname "$APROPOS_SWEEP_DAY_FILE")" "$(dirname "$APROPOS_SWEEP_STAMP")" 2>/dev/null || true
  _sw_local_day
  printf '%s' "$SW_DAY" > "$APROPOS_SWEEP_DAY_FILE" 2>/dev/null || true
  date -u +%Y-%m-%d > "$APROPOS_SWEEP_STAMP" 2>/dev/null || true
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

# WORKING DAYS AND THE WAITING WARNING.
#
# start-days holds the local date of every day this computer had a session start, one per line,
# oldest first, the last 60 kept. A day with no start (a weekend, a holiday) is simply absent,
# so it never counts toward how long an entry has waited. Local dates, because a working day
# is the person's day, not UTC's.
APROPOS_START_DAYS="${APROPOS_START_DAYS:-${APROPOS_SWEEP_STAMP%/*}/start-days}"

# _sw_local_day [epoch] - sets SW_DAY to that moment's local date (now when omitted).
_sw_local_day() {
  SW_DAY=""
  printf -v SW_DAY '%(%Y-%m-%d)T' "${1:--1}" 2>/dev/null
  [[ "$SW_DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && return 0
  if [[ -n "${1:-}" ]]; then
    SW_DAY="$(date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null)"
  else
    SW_DAY="$(date +%Y-%m-%d)"
  fi
}

# sweep_start_day_record - today is a day with a session start. No subprocess unless the file
# has grown past 60 lines and is cut back.
sweep_start_day_record() {
  _sw_local_day
  local today="$SW_DAY" d last="" n=0 tmp
  mkdir -p "$(dirname "$APROPOS_START_DAYS")" 2>/dev/null || true
  if [[ -f "$APROPOS_START_DAYS" ]]; then
    while IFS= read -r d; do [[ -n "$d" ]] && { last="$d"; n=$(( n + 1 )); }; done < "$APROPOS_START_DAYS"
  fi
  [[ "$last" == "$today" ]] || { printf '%s\n' "$today" >> "$APROPOS_START_DAYS" 2>/dev/null; n=$(( n + 1 )); }
  if (( n > 60 )); then
    tmp="$(mktemp)" && tail -n 60 "$APROPOS_START_DAYS" > "$tmp" 2>/dev/null && mv "$tmp" "$APROPOS_START_DAYS"
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# sweep_waiting - true when the oldest flagged entry still waiting has waited
# APROPOS_SWEEP_ALERT_DAYS working days or more: that many days with a session start after the
# day it was flagged, today included. Whether a pass completed does not matter: an entry
# still on the list is unrepaired. Sets SW_WAIT_N (entries waiting), SW_WAIT_DAYS (working
# days the oldest has waited) and SW_WAIT_OLD (entries waiting that were flagged before today:
# entries flagged today have had no day's pass yet, so the warning never asks for those to be
# corrected by hand). An entry whose flag time is unreadable counts as flagged before today.
# SW_WAIT_OLD_ST is the earliest start time (UTC, as recorded) among those flagged before today,
# so the warning can say where in Apropos to find them when some were flagged today.
_sw_old_st() { [[ -z "$SW_WAIT_OLD_ST" || "$1" < "$SW_WAIT_OLD_ST" ]] && SW_WAIT_OLD_ST="$1"; return 0; }

# sweep_local_minute <start_utc> - sets SW_MIN to that start in local time, YYYY-MM-DD HH:MM, the
# form unrepaired.tsv uses; empty, returning 1, if it cannot be read. Works without printf's
# %(...)T (bash 3.2).
sweep_local_minute() {
  local e=""; SW_MIN=""
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
  e="$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null)"
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  printf -v SW_MIN '%(%Y-%m-%d %H:%M)T' "$e" 2>/dev/null
  [[ "$SW_MIN" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || SW_MIN="$(date -d "@$e" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$e" '+%Y-%m-%d %H:%M' 2>/dev/null)"
  [[ "$SW_MIN" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || { SW_MIN=""; return 1; }
}

sweep_waiting() {
  SW_WAIT_N=0; SW_WAIT_DAYS=0; SW_WAIT_OLD=0; SW_WAIT_OLD_ST=""
  [[ -s "$APROPOS_LEDGER_FILE" ]] || return 1
  local st s c e oldest="" d prev="" today ed
  _sw_local_day; today="$SW_DAY"
  while IFS=$'\t' read -r st s c e; do
    [[ -n "$st" ]] || continue
    SW_WAIT_N=$(( SW_WAIT_N + 1 ))
    [[ "$e" =~ ^[0-9]{1,12}$ ]] || { SW_WAIT_OLD=$(( SW_WAIT_OLD + 1 )); _sw_old_st "$st"; continue; }
    e=$(( 10#$e ))
    # _sw_local_day falls back to date where printf has no %(...)T (bash 3.2, as on macOS).
    _sw_local_day "$e"; ed="$SW_DAY"
    [[ "$ed" < "$today" ]] && { SW_WAIT_OLD=$(( SW_WAIT_OLD + 1 )); _sw_old_st "$st"; }
    [[ -z "$oldest" ]] || (( e < oldest )) && oldest="$e"
  done < "$APROPOS_LEDGER_FILE"
  (( SW_WAIT_N > 0 )) && [[ -n "$oldest" ]] || return 1
  _sw_local_day "$oldest"
  [[ -n "$SW_DAY" && -f "$APROPOS_START_DAYS" ]] || return 1
  while IFS= read -r d; do
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [[ "$d" > "$SW_DAY" && "$d" != "$prev" ]] && SW_WAIT_DAYS=$(( SW_WAIT_DAYS + 1 ))
    prev="$d"
  done < "$APROPOS_START_DAYS"
  (( SW_WAIT_DAYS >= APROPOS_SWEEP_ALERT_DAYS ))
}

# THE REPORT OF ENTRIES LEFT UNREPAIRED.
#
# An entry that leaves the list without being repaired, because it passed the age limit
# (APROPOS_SWEEP_DAYS) or because its session can never give it a description, may still
# carry its flag in Apropos, and nothing will fill it in. unrepaired.tsv lists each by its
# start time, so the person can find and correct it: the local date it was listed, the
# entry's start in UTC and in local time, and why. Never a description, session or folder.
# Appended to, never rewritten, except to keep it to its last 500 lines.
APROPOS_SWEEP_REPORT="${APROPOS_SWEEP_REPORT:-${APROPOS_SWEEP_STAMP%/*}/unrepaired.tsv}"

# sweep_report_add <reason> <start_utc>...
sweep_report_add() {
  local reason="$1" st e loc n tmp; shift
  (( $# > 0 )) || return 0
  mkdir -p "$(dirname "$APROPOS_SWEEP_REPORT")" 2>/dev/null || true
  [[ -s "$APROPOS_SWEEP_REPORT" ]] || printf '# listed (local date)\tentry start (UTC)\tentry start (local)\treason\n' > "$APROPOS_SWEEP_REPORT" 2>/dev/null
  _sw_local_day
  for st in "$@"; do
    [[ "$st" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || continue
    loc=""
    e="$(date -u -d "$st" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$st" +%s 2>/dev/null)"
    [[ "$e" =~ ^[0-9]+$ ]] && printf -v loc '%(%Y-%m-%d %H:%M)T' "$e" 2>/dev/null
    [[ -n "$loc" || ! "$e" =~ ^[0-9]+$ ]] || loc="$(date -d "@$e" "+%Y-%m-%d %H:%M" 2>/dev/null || date -r "$e" "+%Y-%m-%d %H:%M" 2>/dev/null)"
    [[ "$loc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || loc=""
    printf '%s\t%s\t%s\t%s\n' "$SW_DAY" "$st" "$loc" "$reason" >> "$APROPOS_SWEEP_REPORT" 2>/dev/null
  done
  n=$(wc -l < "$APROPOS_SWEEP_REPORT" 2>/dev/null | tr -d ' ')
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 1000 )); then
    tmp="$(mktemp)" && { head -n 1 "$APROPOS_SWEEP_REPORT"; tail -n 500 "$APROPOS_SWEEP_REPORT"; } > "$tmp" 2>/dev/null && mv "$tmp" "$APROPOS_SWEEP_REPORT"
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# sweep_report_recent - true when the report lists entries on this working day or the one
# before (the last two days in start-days); sets SW_REPORT_N to how many.
sweep_report_recent() {
  SW_REPORT_N=0
  [[ -s "$APROPOS_SWEEP_REPORT" ]] || return 1
  local d a="" b="" day rest
  if [[ -f "$APROPOS_START_DAYS" ]]; then
    while IFS= read -r d; do [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$d" != "$b" ]] && { a="$b"; b="$d"; }; done < "$APROPOS_START_DAYS"
  fi
  [[ -n "$b" ]] || { _sw_local_day; b="$SW_DAY"; }
  [[ -n "$a" ]] || a="$b"
  while IFS=$'\t' read -r day rest; do
    [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [[ "$day" > "$a" || "$day" == "$a" ]] && SW_REPORT_N=$(( SW_REPORT_N + 1 ))
  done < "$APROPOS_SWEEP_REPORT"
  (( SW_REPORT_N > 0 ))
}

# _sw_ms_now - sets SW_MS to the time in milliseconds, without a subprocess where bash can
# tell (5.0 and later); otherwise to the second.
_sw_ms_now() {
  local t="${EPOCHREALTIME:-}"
  if [[ "$t" =~ ^([0-9]+)[.,]([0-9]{6})$ ]]; then
    SW_MS=$(( ${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]} / 1000 ))
  else
    SW_MS=$(( $(date -u +%s) * 1000 ))
  fi
}

sweep_visited_reset() { rm -f "$APROPOS_SWEEP_VISITED" 2>/dev/null || true; }

# sweep_log <word> [key=value...], one line in the pass log: UTC time, the word, the counts.
# Callers pass counts and outcomes only; nothing else belongs here.
sweep_log() {
  local IFS=' ' _sl_d="${APROPOS_SWEEP_LOG%/*}"
  [[ "$_sl_d" == "$APROPOS_SWEEP_LOG" || -d "$_sl_d" ]] || mkdir -p "$_sl_d" 2>/dev/null || true
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$APROPOS_SWEEP_LOG" 2>/dev/null || true
}

# sweep_log_trim - keeps the log small without losing the passes' history. Correction lines
# ("amend", one per correction call) are kept to the most recent APROPOS_SWEEP_LOG_KEEP; every
# other line, the passes' start and end lines and session start's decisions, is kept for
# APROPOS_SWEEP_LOG_DAYS days, and nothing older than that is kept at all. Until this release
# the log kept its last 200 lines of any kind, which at 100 or more correction calls a day was
# under two days of passes. Order is kept. Run at the end of every pass, and by session start
# when the oldest line has passed the age limit (sweep_log_trim_due).
sweep_log_trim() {
  [[ -s "$APROPOS_SWEEP_LOG" ]] || return 0
  local cut tmp
  _sw_epoch_now
  cut="$(date -u -d "@$(( SW_NOW - APROPOS_SWEEP_LOG_DAYS * 86400 ))" +%Y-%m-%d 2>/dev/null || date -u -r "$(( SW_NOW - APROPOS_SWEEP_LOG_DAYS * 86400 ))" +%Y-%m-%d 2>/dev/null)"
  [[ "$cut" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  tmp="$(mktemp)" || return 0
  awk -F'\t' -v cut="$cut" -v keep="$APROPOS_SWEEP_LOG_KEEP" '
    function recent() { return $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ && substr($1, 1, 10) >= cut }
    NR == FNR { if (recent() && $2 ~ /^amend /) total++; next }
    !recent() { next }
    $2 ~ /^amend / { seen++; if (seen <= total - keep) next }
    { print }' "$APROPOS_SWEEP_LOG" "$APROPOS_SWEEP_LOG" > "$tmp" 2>/dev/null && mv "$tmp" "$APROPOS_SWEEP_LOG"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# sweep_log_trim_due - true when the log's first, oldest, line is older than the age limit, so
# session start trims a log that no pass has trimmed (on a computer where the pass never runs,
# session start's own lines would otherwise grow it for ever). Reads one line: no subprocess.
sweep_log_trim_due() {
  local first="" cut=""
  { IFS= read -r first < "$APROPOS_SWEEP_LOG"; } 2>/dev/null
  [[ -n "$first" ]] || return 1
  _sw_epoch_now
  # Through _sw_local_day, which falls back to date where printf has no %(...)T (bash 3.2).
  _sw_local_day $(( SW_NOW - (APROPOS_SWEEP_LOG_DAYS + 1) * 86400 )); cut="$SW_DAY"
  [[ "$cut" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  [[ "${first:0:10}" < "$cut" ]]
}

# sweep_lock / sweep_unlock / sweep_lock_held / sweep_held: one pass at a time on a machine.
# Every session start asks for the pass, and several sessions often start together.
#
# The 0.2.10 lock was one directory, taken over by removing a dead holder's directory and
# making a new one. Two sessions doing that at once could both succeed: the second removed
# the directory the first had just made. And a pass released whatever directory was there when
# it ended, even one another pass had taken over since. So the lock is now a numbered series
# of directories, and a live holder's directory is never removed by anyone else:
#
#   - To take the lock, a pass looks at every number. If any has a live holder, the lock is
#     busy. Otherwise it makes the next number above the highest, which nobody else can make at
#     the same moment, because making a directory is a single step that fails if it exists;
#     writes its own process id and the time into it; and looks again. If a higher number has
#     appeared meanwhile, or any other number now has a live holder, it removes its own and
#     backs off. So of any number of passes starting together, one holds it.
#   - Looking again at every number, not only at the highest, matters when a contender was held
#     up between its first look and making its number. Once every number has been released the
#     numbering starts again at 1, so a contender whose first look saw 7, long ago, makes 8
#     while the live holder has 1. It sees that holder and backs off. (The holder may see the
#     contender's 8 for that moment and stop its own pass as taken over. Nothing is lost: the
#     next session start carries on. Two passes at once is the outcome ruled out.)
#   - Once it holds the lock, a pass removes lower numbers whose holder has ended, and only
#     those.
#   - Release removes only the pass's own numbered directory, and only while it still names
#     that pass, so a pass that was taken over can never release the new holder's lock.
#   - A pass checks it still holds the lock before each round of corrections, and stops if its
#     directory no longer names it or a higher number has a live holder (sweep_lock_held).
#
# The 0.2.10 lock, last-sweep.lock, is held too, for as long as the pass runs. A session that
# has not reloaded since 0.2.10 knows only that lock, and would otherwise run its own pass beside
# this one. 0.2.10 takes that lock once its holder has ended or it is 90 seconds old, so the pass
# renews its time before each round of corrections, and releases it only while it still names
# this pass. A 0.2.10 lock held by a live 0.2.10 session counts as busy.
#
# A holder counts as live while its process is running and its lock is younger than
# APROPOS_SWEEP_LOCK_STALE_SECS (process numbers can be reused), or, before it has written its
# process id, for a minute. mkdir, as the queue lock does, because flock is absent from Git
# Bash.
_sw_num APROPOS_SWEEP_RUN_SECS 600
# Session start stops a pass this many seconds after its run limit where a coreutils timeout
# exists (session-init.sh), so no pass outlives the two together.
_sw_num APROPOS_SWEEP_KILL_AFTER_SECS 30
# So a lock is judged stale only once its holder has outlived both, with a minute to spare.
_sw_num APROPOS_SWEEP_LOCK_STALE_SECS $(( APROPOS_SWEEP_RUN_SECS + APROPOS_SWEEP_KILL_AFTER_SECS + 60 ))
# 0.2.10 judges its own lock stale at 90 seconds. It is judged here by the same 90 seconds, or by
# the stale age above when that is set shorter, so the setting means the same for both locks.
SW_LEGACY_STALE=$(( APROPOS_SWEEP_LOCK_STALE_SECS < 90 ? APROPOS_SWEEP_LOCK_STALE_SECS : 90 ))
SW_LOCKD="$APROPOS_SWEEP_STAMP.lockd"
SW_LEGACY="$APROPOS_SWEEP_STAMP.lock"
SW_LOCK_GEN=""

_sw_epoch_now() { printf -v SW_NOW '%(%s)T' -1 2>/dev/null; [[ "$SW_NOW" =~ ^[0-9]+$ ]] || SW_NOW="$(date -u +%s)"; }

# _sw_gen_max [mine] - looks at every numbered lock directory. Sets SW_GEN_MAX to the highest
# number, 0 when there is none; SW_GEN_LIVE to how many numbers other than [mine] have a live
# holder; and SW_GEN_LIVE_ABOVE to how many of those are above [mine]. A glob, not ls, so it
# costs no subprocess.
_sw_gen_max() {
  local d n mine="${1:-}"
  SW_GEN_MAX=0; SW_GEN_LIVE=0; SW_GEN_LIVE_ABOVE=0
  [[ "$mine" =~ ^[0-9]{1,9}$ ]] && mine=$(( 10#$mine )) || mine=""
  for d in "$SW_LOCKD"/*; do
    n="${d##*/}"
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
    n=$(( 10#$n ))
    (( n > SW_GEN_MAX )) && SW_GEN_MAX=$n
    [[ -n "$mine" ]] && (( n == mine )) && continue
    if _sw_lock_live "$d"; then
      SW_GEN_LIVE=$(( SW_GEN_LIVE + 1 ))
      [[ -n "$mine" ]] && (( n > mine )) && SW_GEN_LIVE_ABOVE=$(( SW_GEN_LIVE_ABOVE + 1 ))
    fi
  done
  return 0
}

# _sw_lock_live <dir> [stale secs] - true while that lock's holder still counts as holding it.
# A file that is missing is read as empty, quietly: the redirection is inside the braces, so its
# error goes where theirs does.
_sw_lock_live() {
  local d="$1" stale="${2:-$APROPOS_SWEEP_LOCK_STALE_SECS}" pid="" ts=""
  [[ -d "$d" ]] || return 1
  { read -r ts < "$d/ts"; } 2>/dev/null
  { read -r pid < "$d/pid"; } 2>/dev/null
  if [[ "$ts" =~ ^[0-9]{1,12}$ ]]; then ts=$(( 10#$ts )); else ts="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null)"; fi
  [[ "$ts" =~ ^[0-9]+$ ]] || return 0
  _sw_epoch_now
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill -0 "$pid" 2>/dev/null || return 1
    (( SW_NOW - ts <= stale ))
  else
    (( SW_NOW - ts <= 60 ))
  fi
}

# _sw_rmdir <dir> - removes a lock directory. Refuses an empty path, returning 1 rather than
# ending the script as ${1:?} did.
_sw_rmdir() { [[ -n "${1:-}" ]] || return 1; rm -rf -- "$1" 2>/dev/null; }

# _sw_legacy_mine - true while the 0.2.10 lock names this pass.
_sw_legacy_mine() {
  local pid=""
  { read -r pid < "$SW_LEGACY/pid"; } 2>/dev/null
  [[ "$pid" == "$$" ]]
}

# _sw_legacy_take - takes the 0.2.10 lock for this pass: free, or its holder has ended or it is
# more than 90 seconds old, as 0.2.10 itself judges it. False when a live holder has it.
_sw_legacy_take() {
  if ! mkdir "$SW_LEGACY" 2>/dev/null; then
    _sw_lock_live "$SW_LEGACY" "$SW_LEGACY_STALE" && return 1
    _sw_rmdir "$SW_LEGACY"
    mkdir "$SW_LEGACY" 2>/dev/null || return 1
  fi
  _sw_epoch_now
  printf '%s\n' "$SW_NOW" > "$SW_LEGACY/ts" 2>/dev/null
  printf '%s' "$$" > "$SW_LEGACY/pid" 2>/dev/null
  _sw_legacy_mine
}

# sweep_held - true when some live pass holds the lock. Session start asks this before
# launching a pass, so a start during a running pass launches nothing.
sweep_held() {
  _sw_lock_live "$SW_LEGACY" "$SW_LEGACY_STALE" && return 0
  _sw_gen_max
  (( SW_GEN_LIVE > 0 ))
}

sweep_lock() {
  SW_LOCK_GEN=""
  mkdir -p "$SW_LOCKD" 2>/dev/null || true
  _sw_lock_live "$SW_LEGACY" "$SW_LEGACY_STALE" && return 1
  _sw_gen_max
  (( SW_GEN_LIVE > 0 )) && return 1
  local mine=$(( SW_GEN_MAX + 1 )) d n
  mkdir "$SW_LOCKD/$mine" 2>/dev/null || return 1
  _sw_epoch_now
  printf '%s\n' "$SW_NOW" > "$SW_LOCKD/$mine/ts" 2>/dev/null
  printf '%s\n' "$$" > "$SW_LOCKD/$mine/pid" 2>/dev/null
  _sw_gen_max "$mine"
  if (( SW_GEN_MAX != mine || SW_GEN_LIVE > 0 )); then _sw_rmdir "$SW_LOCKD/$mine"; return 1; fi
  if ! _sw_legacy_take; then _sw_rmdir "$SW_LOCKD/$mine"; return 1; fi
  SW_LOCK_GEN="$mine"
  for d in "$SW_LOCKD"/*; do
    n="${d##*/}"
    [[ "$n" =~ ^[0-9]{1,9}$ ]] && (( 10#$n < mine )) && ! _sw_lock_live "$d" && _sw_rmdir "$d"
  done
  return 0
}

# sweep_lock_held - true while this pass still holds the lock it took: its directory still
# names it, no higher number has a live holder, and the 0.2.10 lock has not been taken by a live
# holder. Renews the 0.2.10 lock's time while it names this pass. Called before each round.
sweep_lock_held() {
  [[ -n "$SW_LOCK_GEN" ]] || return 1
  local pid=""
  { read -r pid < "$SW_LOCKD/$SW_LOCK_GEN/pid"; } 2>/dev/null
  [[ "$pid" == "$$" ]] || return 1
  _sw_gen_max "$SW_LOCK_GEN"
  (( SW_GEN_LIVE_ABOVE == 0 )) || return 1
  if _sw_legacy_mine; then
    _sw_epoch_now
    printf '%s\n' "$SW_NOW" > "$SW_LEGACY/ts" 2>/dev/null
  elif _sw_lock_live "$SW_LEGACY" "$SW_LEGACY_STALE"; then
    return 1
  fi
  return 0
}

# sweep_unlock - releases what still names this pass, and nothing else. $$ is the pass's own
# process number even inside a subshell, so a subshell calling this would release the pass's
# lock; only the pass itself calls it, when it ends and from its stop trap, never a correction.
sweep_unlock() {
  [[ -n "$SW_LOCK_GEN" ]] || return 0
  local pid=""
  { read -r pid < "$SW_LOCKD/$SW_LOCK_GEN/pid"; } 2>/dev/null
  [[ "$pid" == "$$" ]] && _sw_rmdir "$SW_LOCKD/$SW_LOCK_GEN"
  _sw_legacy_mine && _sw_rmdir "$SW_LEGACY"
  SW_LOCK_GEN=""
  return 0
}
