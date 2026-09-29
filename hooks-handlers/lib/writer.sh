#!/usr/bin/env bash
# Shared writer callback for q_flush. Delivers ONE queued entry to Apropos via
# the internal R: Record-Time.ps1 (or the $APROPOS_WRITER mock in tests).
# Args: person desc worktype task project startUtc. Returns 0 on success.
#
# EVERY VARIABLE A FUNCTION HERE ASSIGNS IS DECLARED LOCAL, loop variables included. These run
# inside q_flush, and bash scoping is dynamic: an undeclared name is the caller's. oe_record's
# read loop once wrote k, i, e and b straight into the flush, whose loop index was i, and the
# flush then removed the wrong line from the queue. Held turns were dropped undelivered and
# other entries written two or three times. tests/test-real-write-path.sh snapshots every
# variable around a real write and fails on any change.

# Resolve a PowerShell executable WITHOUT relying on PATH. Claude Code runs hooks
# with a minimal PATH that often lacks pwsh (PowerShell 7); if we depend on PATH
# every write fails silently and entries pile up in the queue. Try PATH first,
# then Windows PowerShell (always in System32), then common full paths.
apropos_ps_exe() {
  local c
  for c in pwsh powershell.exe pwsh.exe; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  for c in \
    "/c/Program Files/PowerShell/7/pwsh.exe" \
    "$SYSTEMROOT/System32/WindowsPowerShell/v1.0/powershell.exe" \
    "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Where the currently-open entry for each activity is remembered, shared by every
# session on this machine. Lines are: activityKey <TAB> entryId <TAB> openedEpoch
APROPOS_OPEN_FILE="${APROPOS_OPEN_FILE:-${HOME}/.claude/apropos-time/open-entries.tsv}"

# How long one entry may keep absorbing turns before a fresh one is started. Without a
# cap a long stretch on one task would end up described only by whatever the last turn
# happened to be.
APROPOS_MERGE_MAX_SECS="${APROPOS_MERGE_MAX_SECS:-1800}"

# The open-entry file is read-modify-written by every session on this machine, so it
# needs the same mutual exclusion the queue has. Without it two sessions flushing at the
# same moment each read the file, each rewrite it, and the second silently drops the
# first's line. Observed 2026-08-14 on a real timesheet: an entry was the same activity as
# the one before it and written 8 minutes later, well inside the window, but a third insert
# landed 2 seconds earlier and that activity's line went missing, so it inserted instead of
# amending and both rows carry the same description.
#
# Reuses q_lock from lib/queue.sh, which is always sourced before this file. mkdir is the
# primitive because flock is absent from Git Bash on Windows. If the lock is unavailable
# the callers degrade rather than corrupt: see each one below.
_oe_lock() {
  command -v q_lock >/dev/null 2>&1 || return 1
  local i=0
  while (( i < 50 )); do
    q_lock "$APROPOS_OPEN_FILE" && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}
_oe_unlock() { command -v q_unlock >/dev/null 2>&1 && q_unlock "$APROPOS_OPEN_FILE"; }

# oe_lookup <activityKey> -> prints "id epoch" when an entry is open for that activity
# and still inside the window; otherwise prints nothing and returns 1.
oe_lookup() {
  local key="$1" line id epoch now locked=0 k i e b
  [[ -s "$APROPOS_OPEN_FILE" ]] || return 1
  _oe_lock && locked=1     # read-only, so proceed unlocked rather than lose the merge
  now="$(date -u +%s)"
  # Compare the first field exactly, in bash, with no regex at all. Two earlier attempts
  # were wrong: an unanchored grep -F let key "3|777|26" match a "13|777|26" line,
  # and anchoring it with an escaped key was worse, because activity keys contain "|"
  # and in a basic regex "\|" is alternation, so "^3\|777\|26" matched any line
  # containing 777. Field comparison sidesteps both.
  id=""; epoch=""; local d=""
  # Keep scanning past a claim marker rather than stopping at the first key match. A
  # claim is a non-numeric id, and if one ever sits alongside the real entry for
  # the same activity, stopping early would hide the real one and the turn would insert a
  # duplicate: the very thing the claim exists to prevent.
  while IFS=$'\t' read -r k i e b; do
    [[ "$k" == "$key" ]] || continue
    if [[ "$i" =~ ^[0-9]+$ ]]; then id="$i"; epoch="$e"; d="$b"; break; fi
  done < "$APROPOS_OPEN_FILE"
  (( locked )) && _oe_unlock
  [[ -n "$id" ]] || return 1
  [[ "$id" =~ ^[0-9]+$ && "$epoch" =~ ^[0-9]+$ ]] || return 1
  (( now - epoch > APROPOS_MERGE_MAX_SECS )) && return 1
  # Third field is the description this recorder last wrote for the entry, base64 so it
  # cannot break the tab layout. The caller passes it back with the amend so a row that
  # somebody has corrected since is not silently overwritten.
  printf '%s %s %s' "$id" "$epoch" "$d"
}

# How long a claim on a brand-new activity stays credible, and how long a second session
# waits for that claim to resolve into a real entry id.
APROPOS_CLAIM_MAX_SECS="${APROPOS_CLAIM_MAX_SECS:-120}"
# Wall clock, not an iteration count. QA measured the real writer round trip on the
# machine this ships to at 12 to 20 seconds, while 40 iterations of 0.25s was a nominal
# 10 second budget: shorter than the thing it waits for, so the second session timed out
# and inserted the duplicate anyway, just 10 seconds later. An iteration count also lies
# about its own budget, because each poll costs a subprocess. 25s leaves headroom under
# the 30s hook timeout.
APROPOS_CLAIM_WAIT_SECS="${APROPOS_CLAIM_WAIT_SECS:-25}"

# oe_claim <activityKey> -> 0 if this process now owns the right to OPEN that activity.
#
# oe_lookup is read-only and the entry is not recorded as open until the insert returns,
# which takes seconds against the real writer. Two sessions starting the same brand-new
# activity inside that window both missed and both inserted, giving one row per session:
# the exact thing one entry per activity exists to prevent, and a duplicate nobody can delete
# afterwards. Claiming the key first closes the window.
# Set when this process successfully claims an activity, so oe_record can tell whether
# its own claim has since been superseded. A turn claims at most one activity.
OE_CLAIM_KEY=""
OE_CLAIM_TS=""

oe_claim() {
  local key="$1" now k i e b found=0 tmp
  _oe_lock || return 1
  now="$(date -u +%s)"
  mkdir -p "$(dirname "$APROPOS_OPEN_FILE")" 2>/dev/null || true
  if [[ -s "$APROPOS_OPEN_FILE" ]]; then
    while IFS=$'\t' read -r k i e b; do
      [[ "$k" == "$key" ]] || continue
      [[ "$e" =~ ^[0-9]+$ ]] || continue
      if [[ "$i" =~ ^[0-9]+$ ]]; then
        (( now - e <= APROPOS_MERGE_MAX_SECS )) && found=1
      else
        # Somebody else's claim, still fresh. A stale one is fair game, so a session that
        # died mid-insert cannot block the activity forever.
        (( now - e <= APROPOS_CLAIM_MAX_SECS )) && found=1
      fi
    done < "$APROPOS_OPEN_FILE"
  fi
  if (( found )); then _oe_unlock; return 1; fi
  tmp="$APROPOS_OPEN_FILE.tmp.$$"
  {
    if [[ -s "$APROPOS_OPEN_FILE" ]]; then
      while IFS=$'\t' read -r k i e b; do
        [[ "$k" == "$key" ]] && continue
        [[ "$e" =~ ^[0-9]+$ ]] || continue
        (( now - e > APROPOS_MERGE_MAX_SECS )) && continue
        printf '%s\t%s\t%s\t%s\n' "$k" "$i" "$e" "$b"
      done < "$APROPOS_OPEN_FILE"
    fi
    printf '%s\tpending:%s\t%s\t\n' "$key" "$$" "$now"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$APROPOS_OPEN_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  _oe_unlock
  OE_CLAIM_KEY="$key"; OE_CLAIM_TS="$now"
  return 0
}

# oe_await <activityKey> -> prints "id epoch descb64" once another session's claim turns
# into a real entry. Returns 1 if it does not resolve, and the caller then records its own
# entry rather than losing the turn.
oe_await() {
  local key="$1" out deadline
  deadline=$(( $(date -u +%s) + APROPOS_CLAIM_WAIT_SECS ))
  while (( $(date -u +%s) < deadline )); do
    if out="$(oe_lookup "$key")"; then printf '%s' "$out"; return 0; fi
    sleep 0.25
  done
  return 1
}

# oe_record <activityKey> <entryId>  — remember this entry as the open one for the
# activity, and drop any line that has aged out so the file cannot grow without bound.
oe_record() {
  local key="$1" id="$2" descb64="${3:-}" now tmp k i e b
  [[ "$id" =~ ^[0-9]+$ ]] || return 0
  # This one is a read-modify-write and MUST be exclusive. Failing to get the lock means
  # not recording the entry as open, so the next turn inserts instead of amending. That
  # is an untidy timesheet, which is a great deal better than clobbering another
  # session's line and losing its entry from the map entirely.
  _oe_lock || return 0
  now="$(date -u +%s)"
  # Fencing. If this process claimed this activity and a REAL entry for it is already
  # recorded newer than that claim, another session superseded us while our insert was
  # still in flight. Overwriting would point the map at our row and strand theirs, so
  # leave it alone: an extra row is recoverable, a mis-pointed map is not.
  if [[ -n "$OE_CLAIM_KEY" && "$key" == "$OE_CLAIM_KEY" && -s "$APROPOS_OPEN_FILE" ]]; then
    local sk si se sb
    while IFS=$'\t' read -r sk si se sb; do
      [[ "$sk" == "$key" ]] || continue
      [[ "$si" =~ ^[0-9]+$ ]] || continue
      [[ "$se" =~ ^[0-9]+$ ]] || continue
      if (( se > OE_CLAIM_TS )); then _oe_unlock; return 0; fi
    done < "$APROPOS_OPEN_FILE"
  fi
  mkdir -p "$(dirname "$APROPOS_OPEN_FILE")" 2>/dev/null || true
  tmp="$APROPOS_OPEN_FILE.tmp.$$"
  {
    if [[ -s "$APROPOS_OPEN_FILE" ]]; then
      while IFS=$'\t' read -r k i e b; do
        [[ "$k" == "$key" ]] && continue
        [[ "$e" =~ ^[0-9]+$ ]] || continue
        (( now - e > APROPOS_MERGE_MAX_SECS )) && continue
        printf '%s\t%s\t%s\t%s\n' "$k" "$i" "$e" "$b"
      done < "$APROPOS_OPEN_FILE"
    fi
    printf '%s\t%s\t%s\t%s\n' "$key" "$id" "$now" "$descb64"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$APROPOS_OPEN_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  _oe_unlock
}

# oe_update_desc <activityKey> <entryId> <descb64> - after an ACCEPTED amend, make the record's
# last-written field the description just written, so the next amend is checked against the
# recorder's own latest write. Only the insert used to set it, so from the second amend on the
# expectation was the first description, the writer refused it as though a person had
# corrected the row, and the turn opened a second entry for the same work.
#
# Touches only the line that still points at this entry: if another session has since opened
# a new entry for the activity, its line is left alone. The open time is kept, because the
# merge cap runs from when the entry opened. Same lock and encoding as oe_record. Without the
# lock nothing is written, so the next amend is refused and recorded as its own entry: an
# extra row, never an overwritten correction.
oe_update_desc() {
  local key="$1" id="$2" descb64="$3" tmp k i e b found=0 wrote=0
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  [[ -s "$APROPOS_OPEN_FILE" ]] || return 1
  _oe_lock || return 1
  tmp="$APROPOS_OPEN_FILE.tmp.$$"
  {
    while IFS=$'\t' read -r k i e b; do
      if [[ "$k" == "$key" && "$i" == "$id" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$k" "$i" "$e" "$descb64"; found=1
      else
        printf '%s\t%s\t%s\t%s\n' "$k" "$i" "$e" "$b"
      fi
    done < "$APROPOS_OPEN_FILE"
  } > "$tmp" 2>/dev/null && wrote=1
  (( found && wrote )) && mv "$tmp" "$APROPOS_OPEN_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  _oe_unlock
  (( found && wrote ))
}

# amend_entry <entryId> <person> <desc> — rewrite an open entry's description instead of
# inserting a second row beside it. Returns non-zero so the caller can fall back to a
# normal insert; losing the amend must never lose the time.
amend_entry() {
  if [[ -n "${APROPOS_AMENDER:-}" ]]; then "$APROPOS_AMENDER" "$@"; return $?; fi
  local id="$1" person="$2" desc="$3" expect="${4:-}"
  local script="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}/Update-TimeDescription.ps1"
  [[ -f "$script" ]] || return 1
  local ps; ps="$(apropos_ps_exe)" || return 1
  # -ExpectDescription makes the writer refuse the amend when the row no longer holds
  # what this recorder last wrote, which means somebody corrected it. Returning non-zero
  # sends the caller down the insert path, so the continuing work is still recorded.
  # Omitted when there is nothing to compare, so an older writer still works.
  if [[ -n "$expect" ]]; then
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" \
      -TimeEntryID "$id" -Description "$desc" -PersonID "$person" -ExpectDescription "$expect" >/dev/null 2>&1
  else
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" \
      -TimeEntryID "$id" -Description "$desc" -PersonID "$person" >/dev/null 2>&1
  fi
}

# amend_by_start <start_utc> <person> <desc> <expect> - the ledger's counterpart to
# amend_entry. The repair pass never has an entry id to work with: the ledger is keyed
# on the entry's start time because the id does not exist yet at the moment a flag is
# written (see lib/ledger.sh), so Update-TimeDescription.ps1 resolves the row itself
# from (PersonID, StartTime) via -StartTimeUTC instead. Same ExpectDescription guard,
# same mock hook, same shape, as amend_entry.
#
# Returns 3 when the script found no entry at all. The script exits 1 both for that
# and for an unreachable database or an ambiguous match; only its own message tells them
# apart, so the message is read here. The daily pass removes a row whose entry is gone, and
# must never remove one merely because the database could not be reached.
amend_by_start() {
  if [[ -n "${APROPOS_AMENDER:-}" ]]; then "$APROPOS_AMENDER" "$@"; return $?; fi
  local start="$1" person="$2" desc="$3" expect="${4:-}"
  local script="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}/Update-TimeDescription.ps1"
  [[ -f "$script" ]] || return 1
  local ps; ps="$(apropos_ps_exe)" || return 1
  local out rc
  if [[ -n "$expect" ]]; then
    out="$("$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" \
      -StartTimeUTC "$start" -Description "$desc" -PersonID "$person" -ExpectDescription "$expect" 2>/dev/null)"; rc=$?
  else
    out="$("$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" \
      -StartTimeUTC "$start" -Description "$desc" -PersonID "$person" 2>/dev/null)"; rc=$?
  fi
  if [[ "$rc" == "1" ]] && printf '%s\n' "$out" | grep -q '^No entry '; then return 3; fi
  return "$rc"
}

# lookup_person <login> - ask Apropos which person carries this login. Read-only. Prints
# APROPOS_PERSON_ID=<id> and returns 0 when exactly one active account has it. Returns 2 no
# such account, 3 inactive only, 4 more than one; lib/person.sh treats those as a person
# who cannot be identified. Anything else, including a missing script, no PowerShell, or
# running past the time limit, means the lookup could not be completed.
#
# $APROPOS_LOOKUP replaces the real lookup with a script, as $APROPOS_WRITER does for the
# insert, so tests never reach the shared drive or the database.
#
# Bounded by APROPOS_LOOKUP_TIMEOUT seconds where a coreutils timeout exists. An unreachable
# database was measured at 21 seconds before the connection gave up, whatever the connect
# timeout said, which would leave almost nothing of a 30 second hook for the turn itself.
APROPOS_LOOKUP_TIMEOUT="${APROPOS_LOOKUP_TIMEOUT:-12}"

# apropos_timeout_exe -> the path of a coreutils timeout, or nothing.
#
# Never Windows' own timeout.exe. That is a different program ("timeout /t 5" waits for a
# key press) that rejects "timeout 12 <command>" at once. When a hook's PATH puts System32
# ahead of Git's tools, a bare "timeout" is that program, and every lookup failed as
# unreachable. So Git Bash's own copy is asked for by path first, then PATH is walked with
# Windows folders skipped. APROPOS_COREUTILS_DIRS is a test hook for the first step.
apropos_timeout_exe() {
  local d c low
  for d in ${APROPOS_COREUTILS_DIRS-/usr/bin /bin}; do
    [[ -x "$d/timeout" ]] && { printf '%s' "$d/timeout"; return 0; }
  done
  local IFS=:
  for d in $PATH; do
    [[ -n "$d" ]] || continue
    low="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
    case "$low" in
      */windows|*/windows/*|*/system32|*/system32/*) continue ;;
    esac
    for c in timeout gtimeout; do
      [[ -x "$d/$c" && ! -d "$d/$c" ]] && { printf '%s' "$d/$c"; return 0; }
    done
  done
  return 1
}

lookup_person() {
  local login="$1"
  if [[ -n "${APROPOS_LOOKUP:-}" ]]; then "$APROPOS_LOOKUP" "$login"; return $?; fi
  local script="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}/Resolve-Person.ps1"
  [[ -f "$script" ]] || return 5
  local ps; ps="$(apropos_ps_exe)" || return 5
  # -Username:<login> as one argument, so a login beginning with "-" is taken as the value
  # and never read as another parameter.
  local to; to="$(apropos_timeout_exe)"
  if [[ -n "$to" ]]; then
    "$to" "$APROPOS_LOOKUP_TIMEOUT" "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" -Username:"$login" 2>/dev/null
  else
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" -Username:"$login" 2>/dev/null
  fi
}

# What a flush callback returns for an entry that must stay queued without counting as a
# failed delivery: its person is not identified yet. Defined in lib/queue.sh, which is
# sourced first; the default here only covers a caller that sourced this file alone.
: "${Q_RC_DEFER:=75}"

write_entry() {
  # An entry queued before its person was identified carries "unresolved:<login>" instead of
  # an id. Resolve it now; until that succeeds the entry stays queued, and is never written
  # under a guessed or empty person.
  if [[ "${1:-}" == unresolved:* ]]; then
    command -v person_resolve >/dev/null 2>&1 || return "$Q_RC_DEFER"
    person_resolve "${1#unresolved:}" || return "$Q_RC_DEFER"
    set -- "$PERSON_ID" "${@:2}"
  fi
  if [[ -n "${APROPOS_WRITER:-}" ]]; then "$APROPOS_WRITER" "$@"; return $?; fi
  local person="$1" desc="$2" wt="$3" task="$4" proj="$5" start="$6"
  local entry="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}/Record-Time.ps1"
  [[ -f "$entry" ]] || return 1
  local ps; ps="$(apropos_ps_exe)" || return 1
  local args=(-PersonID "$person" -Description "$desc" -WorkTypeID "$wt" -StartTimeUTC "$start")
  if [[ -n "$task" && "$task" != "0" ]]; then args+=(-TaskID "$task")
  elif [[ -n "$proj" && "$proj" != "0" ]]; then args+=(-ProjectID "$proj"); fi
  local out rc
  out="$("$ps" -NoProfile -ExecutionPolicy Bypass -File "$entry" "${args[@]}" 2>/dev/null)"
  rc=$?
  (( rc != 0 )) && return $rc
  # Remember the row just written, so the next turn on this activity amends it. Only
  # entries with a task qualify: the amend path cannot touch a row with no task without
  # clearing its attribution.
  if [[ -n "$task" && "$task" != "0" ]]; then
    local newId
    newId="$(printf '%s' "$out" | grep -o 'APROPOS_ENTRY_ID=[0-9]*' | head -1 | cut -d= -f2)"
    [[ -n "$newId" ]] && oe_record "$wt|$task|$proj" "$newId" "$(printf '%s' "$desc" | base64 | tr -d '\n')"
  fi
  return 0
}
