#!/usr/bin/env bash
# Durable local time-entry queue. TSV lines:
#   person <TAB> descB64 <TAB> worktype <TAB> task <TAB> project <TAB> startUtc [<TAB> attempts]
# Description is base64-encoded so it may contain tabs/newlines/quotes safely.
# The 7th field (attempts) is optional; lines written by older versions are read as 0.
#
# The person field is a numeric Apropos person id, as every version has written it, or
# "unresolved:<login>" for a turn recorded before the person could be identified.
# The delivery callback resolves the second form first; see write_entry in lib/writer.sh.
#
# TWO DEFECTS FIXED 2026-08-10, both observed live on a team machine.
#
# 1. NO MUTUAL EXCLUSION. q_flush read the queue, delivered every line, then rewrote
#    the file from its own snapshot. With several Claude Code sessions open, two flushes
#    would run at once and deliver every queued entry once each, and a flush that
#    retained entries could write its stale snapshot over a newer file, restoring
#    entries that had already been delivered so they were delivered again. Measured
#    2026-08-08 to 08-10: 239 rows in Apropos from only 7 real moments, all at zero
#    duration ("onboarding-status" 106 rows from 3 timestamps, "Temp" 102 from 3,
#    "subscriber-health" 31 from 1). Proof it was re-delivery and not re-recording: the
#    queue still held 31 entries and all 8 of the non-placeholder ones were already in
#    the database. Reproduced with two concurrent q_flush calls, which delivered every
#    entry exactly twice.
#
# 2. HEAD-OF-LINE BLOCKING. A single undeliverable entry set stopped=1, which retained
#    that entry AND every entry behind it, forever, with no attempt limit. One bad row
#    silently froze all later time recording. This is what produced the two archived
#    backlogs on this machine, 383 entries on 2026-07-28 and 212 on 2026-08-05, the
#    second marked DO-NOT-FLUSH because it could no longer be trusted.
#
# The lock is a directory, not flock: flock is not present in Git Bash on Windows, and
# mkdir is atomic on every filesystem we run on.

Q_LOCK_STALE_SECS="${Q_LOCK_STALE_SECS:-120}"
Q_MAX_ATTEMPTS="${Q_MAX_ATTEMPTS:-5}"

_q_now() { date -u +%s; }

# Acquire the queue mutex. Returns 0 on success, 1 if another process holds it.
# A lock older than Q_LOCK_STALE_SECS is treated as abandoned and broken, so a process
# killed mid-flush cannot wedge time recording permanently.
q_lock() {
  local qf="$1" lock="$1.lock" age start
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then _q_now > "$lock/ts" 2>/dev/null; return 0; fi
  start="$(cat "$lock/ts" 2>/dev/null)"
  if ! [[ "$start" =~ ^[0-9]+$ ]]; then
    # No usable timestamp yet. Taking the lock is two steps, mkdir then the stamp, so a
    # holder that has just succeeded at mkdir has an unstamped lock for a moment. Treating
    # that as abandoned let a second writer rm -rf the directory and take the lock while
    # the holder still held it; both then read-modify-wrote the open-entry map and one
    # clobbered the other. Measured 2026-08-27: 4 runs in 10 lost between 1 and 6 of 12
    # concurrent activities, which is how one activity comes to hold two entries.
    #
    # So fall back to the directory's own creation time rather than assuming abandonment.
    # If that cannot be read either, refuse the lock: waiting is recoverable, and the
    # caller degrades to not recording, while stealing corrupts another session's line.
    start="$(stat -c %Y "$lock" 2>/dev/null)"
  fi
  if [[ "$start" =~ ^[0-9]+$ ]]; then
    age=$(( $(_q_now) - start ))
    if (( age > Q_LOCK_STALE_SECS )); then
      rm -rf "$lock" 2>/dev/null || true
      if mkdir "$lock" 2>/dev/null; then _q_now > "$lock/ts" 2>/dev/null; return 0; fi
    fi
  fi
  return 1
}

q_unlock() { rm -rf "$1.lock" 2>/dev/null || true; }

q_enqueue() {
  local qf="$1" person="$2" desc="$3" wt="$4" task="$5" proj="$6" start="$7"
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  local b64; b64=$(printf '%s' "$desc" | base64 | tr -d '\n')
  # A single short line appended with >> is atomic enough on the filesystems we use, but
  # take the lock when it is free so an append can never interleave with a flush rewrite.
  if q_lock "$qf"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$qf"
    q_unlock "$qf"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$qf"
  fi
}

# q_flush <queuefile> <callback>
# Delivers each entry via the callback. Entries that fail are retried on later flushes
# until Q_MAX_ATTEMPTS, then moved to <queuefile>.dead so they stop blocking the queue.
# A failure no longer stops the run: every entry gets its own attempt each flush.
# Quarantine entries whose start time is older than Q_STALE_DAYS. A queue that has
# been stuck for weeks is not a backlog worth delivering: those entries are almost
# certainly in the database already, from earlier passes of the pre-fix flush, and
# re-delivering them just adds more copies. One team machine kept replaying the same
# ten 2026-07-13 and 07-15 entries every session for three weeks, which is what
# grew one entry to 122 copies. Nobody should have to know to go move a file, so
# the plugin retires the stale ones itself, into <queuefile>.stale for inspection.
#
# An entry whose person is still unresolved is exempt, however old. The reason for the
# quarantine is that an old entry has probably been delivered already; one with no person
# can never have been delivered, so retiring it would simply lose the time.
Q_STALE_DAYS="${Q_STALE_DAYS:-3}"
# Read like the other settings: a plain number of days, as decimal (08 is 8, not a broken octal
# number that failed every sum using it), and at least 1, since 0 would retire every line that
# is not yet a day old. Anything else is the default, 3.
if [[ "$Q_STALE_DAYS" =~ ^[0-9]{1,6}$ ]] && (( 10#$Q_STALE_DAYS >= 1 )); then Q_STALE_DAYS=$(( 10#$Q_STALE_DAYS )); else Q_STALE_DAYS=3; fi

#
# ONE PASS, NOT A PROCESS PER LINE. This runs before the flush's first delivery and outside its
# deadline. It used to run cut and date for every line; at 100 to 200 ms a process on a busy
# Windows machine, 13 lines took 8 to 10 s (2026-09-30), longer than the delivery window session
# start leaves itself, so session start delivered nothing, and a backlog of about 50 lines would
# outlast the hook's 30 s limit in every flush. Now one awk pass compares each start time, in the
# form the recorder writes (YYYY-MM-DD HH:MM:SS, UTC, or the same with T and Z), with the
# cut-off written in that form, which orders the same way as comparing the epoch seconds. Only a
# start time in some other form is still read by date, one line at a time, as before.
#
# NOTHING IS MOVED UNLESS THE PASS RAN TO THE END. The kept lines are moved over the queue, so a
# pass that died partway, after retiring a line, would have moved only the lines it reached and
# lost the rest (QA, 2026-09-30, from reading the first version of this pass). So awk writes its
# tagged lines to a working file and ends with a count of them; the queue is rewritten only when
# awk exited cleanly, its count is there and matches the lines read back, and every kept and
# retired line was written. Otherwise the queue, and the .stale file, are left exactly as they
# were, and the next flush checks again. Retired lines are added to .stale only once the rest has
# succeeded, just before the move.
q_quarantine_stale() {
  local qf="$1" cutoff cut_str keep stale line tag start ts moved=0 n=0 want="" ok=1 tags newstale
  [[ -f "$qf" ]] || return 0
  cutoff=$(( $(_q_now) - Q_STALE_DAYS * 86400 ))
  cut_str="$(date -u -d "@$cutoff" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$cutoff" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  keep="$qf.keep"; stale="$qf.stale"; tags="$qf.tags.$$"; newstale="$qf.stalenew.$$"
  # Each line comes back tagged: K keep, S stale, or ? followed by its start time, to be read by
  # date. A line whose person is not identified yet is always kept (see above). The last line is
  # E and the number of tagged lines before it.
  if ! awk -F'\t' -v c="$cut_str" '
    $0 == "" { next }
    /^unresolved:/ { print "K\t" $0; t++; next }
    {
      s = $6; n = s; sub(/Z$/, "", n)
      if (substr(n, 11, 1) == "T") n = substr(n, 1, 10) " " substr(n, 12)
      if (c != "" && n ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/)
        print ((n < c) ? "S" : "K") "\t" $0
      else
        print "?\t" s "\t" $0
      t++
    }
    END { print "E\t" (t + 0) }' "$qf" > "$tags" 2>/dev/null; then
    rm -f "$tags" 2>/dev/null; return 0
  fi
  : > "$keep" 2>/dev/null || ok=0
  : > "$newstale" 2>/dev/null || ok=0
  while (( ok )) && IFS= read -r line; do
    tag="${line%%$'\t'*}"; line="${line#*$'\t'}"
    if [[ "$tag" == E ]]; then want="$line"; continue; fi
    [[ -z "$want" ]] || { ok=0; break; }   # nothing may follow the count
    n=$((n+1))
    if [[ "$tag" == "?" ]]; then
      start="${line%%$'\t'*}"; line="${line#*$'\t'}"
      ts="$(date -u -d "$start" +%s 2>/dev/null)"
      if [[ "$ts" =~ ^-?[0-9]+$ ]] && (( ts < cutoff )); then tag=S; else tag=K; fi
    elif [[ "$tag" != S && "$tag" != K ]]; then
      ok=0; break
    fi
    if [[ "$tag" == S ]]; then
      printf '%s\n' "$line" >> "$newstale" 2>/dev/null || ok=0; moved=$((moved+1))
    else
      printf '%s\n' "$line" >> "$keep" 2>/dev/null || ok=0
    fi
  done < "$tags"
  rm -f "$tags" 2>/dev/null
  [[ "$want" == "$n" ]] || ok=0
  if (( ok && moved > 0 )); then
    if cat "$newstale" >> "$stale" 2>/dev/null; then mv "$keep" "$qf" 2>/dev/null || ok=0; else ok=0; fi
  fi
  rm -f "$keep" "$newstale" 2>/dev/null
  (( ok )) || return 0
  [[ -f "$qf" && ! -s "$qf" ]] && rm -f "$qf"
  return 0
}

# What a flush callback returns for an entry that must stay queued without counting as a
# failed delivery: its person is not identified yet. write_entry in lib/writer.sh returns it.
Q_RC_DEFER=75

# _q_merge_retry <queuefile> [<deadline epoch>]: fold a side file left by an earlier flush back
# into the queue. Returns 0 once it is fully merged (or there is none), 1 if the deadline came
# first or a step failed; the caller then delivers nothing this time.
#
# Until 0.2.9 a flush moved every line it could not deliver into <queuefile>.retry and put
# them back only when its loop finished. A flush killed by the hook timeout left them there,
# and the next flush began by deleting that file. QA reproduced it with 30 turns held for a
# person not yet identified: killed at 8 s, only 12 of the 30 were ever delivered. The flush
# no longer writes a side file, but one left by an earlier version, or by a flush killed
# during the update, is still somebody's time. So it is merged back ahead of the queue, where
# its lines came from. A line in both files is kept once: the old flush wrote the side file
# before trimming the queue, so a kill between the two left the same entry in each. "The same"
# means the first six fields; the seventh only counts attempts.
#
# FAST, BOUNDED AND RESUMABLE. The first version of this merge compared every side-file line
# with every queue line in bash, forking cut twice per comparison, before any deadline check.
# QA measured 10 lines by 10 at 45 s and 10 by 20 at 79 s: past the 30 s hook limit, so on that
# machine every flush was killed mid-merge and nothing was ever delivered again. Now:
#   - each step is one awk pass that holds the queue's entries in a hash: linear, one fork;
#   - the side file is taken Q_MERGE_CHUNK lines at a time from its end, and the deadline is
#     checked before each step;
#   - each step moves the new queue into place, then the shortened side file. A kill between
#     the two leaves that step's lines in both files, and the next step finds them already in
#     the queue and skips them. A kill anywhere else leaves both files as they were before or
#     after the step. Either way the next flush carries on from where this one stopped.
# The temporary files carry this process's id, so a step left running by a killed flush can
# never write into the files the next flush is building.
Q_MERGE_CHUNK="${Q_MERGE_CHUNK:-200}"
_q_merge_retry() {
  local qf="$1" deadline="${2:-}" retry="$1.retry" chunk="$Q_MERGE_CHUNK" mq rq
  [[ -f "$retry" ]] || return 0
  [[ "$chunk" =~ ^[1-9][0-9]*$ ]] || chunk=200
  mq="$qf.merge.$$"; rq="$retry.tmp.$$"
  rm -f "$qf".merge.* "$retry".tmp.* 2>/dev/null
  while [[ -s "$retry" ]]; do
    if [[ -n "$deadline" ]] && (( $(_q_now) >= deadline )); then return 1; fi
    [[ -f "$qf" ]] || : > "$qf" || return 1
    awk -v n="$chunk" -v mq="$mq" -v rq="$rq" '
      function key(l,   a, c, k, j) {
        c = split(l, a, "\t"); if (c > 6) c = 6
        k = a[1]; for (j = 2; j <= c; j++) k = k "\t" a[j]
        return k
      }
      FILENAME == ARGV[1] { if ($0 != "") { q[++nq] = $0; seen[key($0)] = 1 }; next }
      { if ($0 != "") r[++nr] = $0 }
      END {
        from = nr - n + 1; if (from < 1) from = 1
        printf "" > mq; printf "" > rq
        for (j = from; j <= nr; j++) { k = key(r[j]); if (!(k in seen)) { seen[k] = 1; print r[j] > mq } }
        for (j = 1; j <= nq; j++) print q[j] > mq
        for (j = 1; j < from; j++) print r[j] > rq
        close(mq); close(rq)
      }' "$qf" "$retry" || { rm -f "$mq" "$rq"; return 1; }
    mv -f "$mq" "$qf" || { rm -f "$mq" "$rq"; return 1; }
    mv -f "$rq" "$retry" || { rm -f "$rq"; return 1; }
    [[ -n "${Q_TEST_MERGE_PAUSE:-}" ]] && sleep "$Q_TEST_MERGE_PAUSE"   # tests only: widen each step so a kill can land inside the merge
  done
  rm -f "$retry" 2>/dev/null
  [[ -f "$qf" && ! -s "$qf" ]] && rm -f "$qf"
  return 0
}

# q_flush <queuefile> <callback>
#
# APROPOS_FLUSH_DEADLINE, optional, is an epoch second after which no further delivery is
# started. Session start and the per-turn recorder set it so a flush cannot run a hook past its
# time limit. Lines not reached stay queued for the next flush.
#
# EVERY NAME THIS FUNCTION HOLDS STATE IN BEGINS _qf_. The callback runs inside it, bash scoping
# is dynamic, and a callback that assigns an undeclared name writes the caller's. Up to QA round 2
# of the person lookup the loop index was a plain local i, oe_record's read loop wrote i as well,
# and the flush removed the wrong line: held turns were dropped undelivered and other entries
# written two or three times. lib/writer.sh now declares its loop variables, and these names are
# ones no callback has reason to use, so neither fix alone is load-bearing.
q_flush() {
  local _qf_qf="$1" _qf_cb="$2"
  [[ -f "$_qf_qf" || -f "$_qf_qf.retry" ]] || return 0
  # Only one flush at a time. If another holds the lock, do nothing; the next turn
  # flushes. Skipping is always safe because the queue is durable.
  q_lock "$_qf_qf" || return 0
  local _qf_deadline="${APROPOS_FLUSH_DEADLINE:-}"
  [[ "$_qf_deadline" =~ ^[0-9]+$ ]] || _qf_deadline=""
  # Nothing is delivered while a side file from an earlier version is still being merged: a
  # line can sit in both files, and delivering the queue's copy first would let the side
  # file's copy come back afterwards as a second delivery. A merge the deadline stops keeps
  # its progress; the next flush carries on from there.
  if ! _q_merge_retry "$_qf_qf" "$_qf_deadline"; then q_unlock "$_qf_qf"; return 0; fi
  q_quarantine_stale "$_qf_qf"
  [[ -f "$_qf_qf" ]] || { q_unlock "$_qf_qf"; return 0; }
  local _qf_dead="$_qf_qf.dead" _qf_line _qf_person _qf_b64 _qf_wt _qf_task _qf_proj _qf_start _qf_attempts _qf_desc _qf_rc

  # The queue is read once into memory, and every line stays in the file until the flush is
  # done with it: delivered, parked, or counted as a failed attempt. A line that has to wait,
  # such as one whose person is not identified yet, is never moved or rewritten at all, so a
  # kill at any moment cannot lose it.
  #
  # COMMIT AFTER EACH ENTRY, never once at the end (defect fixed 2026-07-31, re-fixed after
  # a batch rewrite came back). A flush that rewrote the queue only after its loop left the
  # file untouched when the hook hit its timeout mid-loop, and every entry already delivered
  # in that pass was inserted again on the next pass. That is what inserted one of one
  # person's 2026-07-15 entries 42 times and four of another's 37 times each. Here each
  # delivery is committed to the file as soon as it returns, so a kill can only repeat the
  # one entry in flight at that moment, never a committed one.
  local -a _qf_Q=()
  local _qf_n=0 _qf_written=0
  while IFS= read -r _qf_line || [[ -n "$_qf_line" ]]; do
    _qf_written=$((_qf_written+1))
    [[ -z "$_qf_line" ]] && continue
    _qf_Q[_qf_n]="$_qf_line"; _qf_n=$((_qf_n+1))
  done < "$_qf_qf"

  # People the callback has already said it cannot identify during this flush. Their other
  # lines are passed over without asking again: one lookup per login per flush, not one per
  # line, and no subprocess at all for a line passed over. A space-separated list rather
  # than an associative array, for the bash 3.2 a Mac runs hooks with.
  local _qf_deferred=" "

  local _qf_i=0 _qf_late=0
  while :; do
  while (( _qf_i < ${#_qf_Q[@]} )); do
    _qf_line="${_qf_Q[_qf_i]}"
    _qf_person="${_qf_line%%$'\t'*}"
    if [[ "$_qf_deferred" == *" $_qf_person "* ]]; then _qf_i=$((_qf_i+1)); continue; fi
    if [[ -n "$_qf_deadline" ]] && (( $(_q_now) >= _qf_deadline )); then _qf_late=1; break; fi
    IFS=$'\t' read -r _qf_person _qf_b64 _qf_wt _qf_task _qf_proj _qf_start _qf_attempts <<< "$_qf_line"
    [[ "$_qf_attempts" =~ ^[0-9]+$ ]] || _qf_attempts=0
    _qf_desc="$(printf '%s' "$_qf_b64" | base64 -d 2>/dev/null)"
    "$_qf_cb" "$_qf_person" "$_qf_desc" "$_qf_wt" "$_qf_task" "$_qf_proj" "$_qf_start"; _qf_rc=$?
    if (( _qf_rc == 0 )); then
      _qf_Q=("${_qf_Q[@]:0:_qf_i}" "${_qf_Q[@]:_qf_i+1}")
      _q_flush_commit
    elif (( _qf_rc == Q_RC_DEFER )); then
      # Deferred, not failed: the callback could not identify the person yet. Left exactly as
      # it was, attempts unchanged, so it can never be parked in .dead for want of an account
      # that simply has not been set up yet.
      _qf_deferred="$_qf_deferred$_qf_person "
      _qf_i=$((_qf_i+1))
    else
      _qf_attempts=$((_qf_attempts+1))
      if (( _qf_attempts >= Q_MAX_ATTEMPTS )); then
        # Park FIRST, then drop from the live queue, so a kill between the two can only
        # leave a failed (undelivered) entry in both places, never lose it.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_qf_person" "$_qf_b64" "$_qf_wt" "$_qf_task" "$_qf_proj" "$_qf_start" "$_qf_attempts" >> "$_qf_dead"
        _qf_Q=("${_qf_Q[@]:0:_qf_i}" "${_qf_Q[@]:_qf_i+1}")
      else
        _qf_Q[_qf_i]="$_qf_person"$'\t'"$_qf_b64"$'\t'"$_qf_wt"$'\t'"$_qf_task"$'\t'"$_qf_proj"$'\t'"$_qf_start"$'\t'"$_qf_attempts"
        _qf_i=$((_qf_i+1))
      fi
      _q_flush_commit
    fi
  done
  # Lines appended after the last commit are delivered too, as the flush always has.
  (( _qf_late )) && break
  _q_flush_take_appended || break
  done
  [[ -f "$_qf_qf" && ! -s "$_qf_qf" ]] && rm -f "$_qf_qf"
  q_unlock "$_qf_qf"
  return 0
}

# The two helpers below work on q_flush's own state (_qf_Q, _qf_qf, _qf_written), which they
# see through bash's dynamic scoping. Called only from inside q_flush.
#
# _q_flush_take_appended: add to the end of the queue anything another session appended to the
# file since this flush last read or wrote it (q_enqueue appends without the lock when it is
# busy), so it is kept by the next commit and delivered in this same flush. Returns 1 if there
# was none.
_q_flush_take_appended() {
  local _qf_k=0 _qf_l _qf_got=1
  while IFS= read -r _qf_l || [[ -n "$_qf_l" ]]; do
    _qf_k=$((_qf_k+1)); (( _qf_k <= _qf_written )) && continue
    [[ -n "$_qf_l" ]] && { _qf_Q[${#_qf_Q[@]}]="$_qf_l"; _qf_got=0; }
  done < "$_qf_qf"
  (( _qf_k > _qf_written )) && _qf_written=$_qf_k
  return $_qf_got
}
# _q_flush_commit: write the queue as it now stands, written to a temporary file and moved into
# place, so the file is always whole.
_q_flush_commit() {
  _q_flush_take_appended
  local _qf_tmp="$_qf_qf.tmp" _qf_l _qf_m=0
  { for _qf_l in "${_qf_Q[@]}"; do printf '%s\n' "$_qf_l"; _qf_m=$((_qf_m+1)); done; } > "$_qf_tmp" 2>/dev/null \
    && mv "$_qf_tmp" "$_qf_qf" 2>/dev/null && _qf_written=$_qf_m
}
