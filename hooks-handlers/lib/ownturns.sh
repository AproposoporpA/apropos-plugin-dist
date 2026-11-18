#!/usr/bin/env bash
# Recording only the turns the person starts (APROPOS_OWN_TURNS), and the one parser every
# per-person switch is read with.
#
# Sourced by time-track-per-turn.sh, and by tests/harness-own-turns-real.sh, which puts real
# sessions' turns to the same decision. Local only: no credentials and no database access.
#
# WHY. For a person whose time with agents is measured separately from the session transcripts,
# every turn the recorder writes that the person did not start is clutter on their own timecard:
# background task notices and helper hand-backs, messages from other sessions and their idle
# notices, the recorder's own send-back, usage-limit notices, and the continuation after a
# compaction. Measured in one such person's session: about 199 prompts typed against 258 started
# by something else.
#
# WHAT. With APROPOS_OWN_TURNS on, a Stop records nothing, and changes nothing the next turn uses,
# only when the turn's starting prompt record in the transcript BEGINS with one of a closed list of
# forms Claude Code writes itself (OT_FORMS, below), measured on every local transcript of one
# computer before this was written. Everything else records exactly as it does with the setting
# off: any other prompt, a form quoted later in a typed prompt, a form after leading spaces, a
# prompt the recorder cannot read (no jq, no transcript, a Stop that names no prompt, or the turn's
# prompt further back than the part of the transcript read).
#
# THE TURN'S STARTING PROMPT RECORD. Claude Code writes a prompt id on every user record of a turn,
# and passes the turn's prompt id to the Stop hook (prompt_id). The turn's starting record is the
# FIRST user record carrying text (a string, or blocks with a text block and no tool result) whose
# prompt id is the one the Stop names. Measured, and the reason it is the first and not the last:
# the recorder's own send-back ("Stop hook feedback:"), the usage-limit notes and the compaction
# summary are written INTO a turn under that turn's own prompt id (135, 88 and 50 times), after
# the prompt that started it. Taking the last would skip a person's own turn whenever one of those
# followed their prompt. Messages from other sessions are written as records marked isMeta, which
# is why meta records count here.
#
# A turn is skipped only when ALL of these hold:
#   - the setting is on, the event is Stop, jq is present, the Stop names a prompt id of plain
#     characters, and the transcript can be read;
#   - the turn's starting record is in the part of the transcript read: when the read is cut, a user
#     record of an earlier turn (another prompt id) comes before it in that part;
#   - its content is a string, or blocks whose FIRST block is text, and that text begins, at its very
#     first character, with one of the forms;
#   - Claude Code has not marked it as typed by the person (origin kind "human", or a prompt source of
#     "typed" or "queued"): a typed prompt that opens with a pasted form is the person's own;
#   - nothing after it in the read part starts another turn or is the person's: no user record with
#     text under another prompt id or none, no record marked as typed, and no message queued into the
#     turn unless it too begins with a form and is not marked as the person's;
#   - the copy of the session's notes kept under the live prompt stamp (or rekeyed to this turn's
#     prompt id by an earlier skipped Stop of this turn) was made for a prompt that began with one
#     of the forms (_ot_snap_ours, below). Normally that is this turn's own copy; see below for when
#     it is an earlier prompt's.
#
# SKIPPED means what the idle check-in skip means: no entry opened or amended, no send-back, no
# delivery or repair, no notice, and the next turn finds the description, worktype, task, project
# and open entries as the turn before left them. A machine-started turn can write the session's
# notes itself (sessions are told to write them every turn), so with the setting on each prompt's
# hook keeps a copy of the four note files as they stand when the prompt arrives (_ot_snap), and a
# skipped Stop puts them back (_ot_restore).
#
# A machine-started turn whose prompt hook did not run has no copy of its own, so there is no telling
# which notes are the turn's. It is recorded exactly as the release before records it, its notes left
# as they are (they may carry the person's sticky task): like anything else the recorder cannot read,
# it records as before. Skipping it while leaving its notes, as first built, handed them to the next
# prompt, whose recovery of a Stop that did not run then recorded the machine turn's notes there and
# then, at that prompt's time (QA round 1).
#
# The copy says whether the prompt it was kept for began with one of the forms, as the prompt hook
# was given it, and only such a copy is ever taken as a machine turn's own. The rule, exactly: a
# machine-started turn is skipped whenever the copy kept under the live prompt stamp was made for a
# prompt that began with one of the forms, and the session's notes are then put back as that copy
# holds them. When the turn's own prompt hook did not run, the live stamp is still an earlier
# prompt's, one whose Stop never ran because it was interrupted. Two known consequences follow, both
# unchanged since 00a396e. (1) A typed prompt that opens with a pasted form, interrupted, then a
# machine turn whose prompt hook did not run: that turn is skipped and the notes are put back as the
# typed prompt found them, so the interrupted typed turn gets no entry. (2) A notice whose prompt hook
# ran, interrupted after its session wrote notes, then a machine turn whose prompt hook did not run:
# that turn is skipped and the notes are put back as they stood before the notice. A typed turn that is
# interrupted leaves its copy on disk under its stamp, since its Stop never runs, and a machine turn
# after it whose prompt hook did not run then finds that copy. Taken as its own, as first built, it
# put back the notes as the typed turn found them, so the typed turn got no entry and the next turn
# was booked to the task before it (QA round 2). Refused, the machine turn records exactly as
# the release before records it: the interrupted turn's notes, from that turn's start. A copy that
# says nothing of its prompt (kept by an earlier build, damaged, or kept with no jq to read the
# prompt) is refused the same way.

# _setting_on <value> - true when a per-person switch is on: on, 1, true or yes (on, true and yes in
# any case). Anything else, or nothing, is off. The one parser for every such switch, so they are
# all read alike. Builtins only.
_setting_on() {
  case "${1:-}" in
    [Oo][Nn]|1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) return 0 ;;
  esac
  return 1
}

# Off unless switched on for the person.
_ot_on() { _setting_on "${APROPOS_OWN_TURNS:-}"; }

# The closed list. Each was found at the start of prompt records Claude Code wrote itself, never
# at the start of one marked typed, on every local transcript of the computer measured:
#   "<task-notification>"            background task notices and helper hand-backs (2678 turns)
#   "Another Claude session sent a message:"   a message from another session (676 turns)
#   "Stop hook feedback:"            a Stop hook's send-back (only inside turns, 137)
#   "[Usage limit reached", "[Earlier usage-limit notes"   usage-limit notes (only inside turns)
#   "Your claude.ai usage limit has reset"     the continuation after a usage limit (6 turns)
#   "This session is being continued from a previous conversation"   the compaction summary
#   "The rc-reconnect plugin sent a message:"  a plugin's automatic note (8 turns)
#   "<agent-message"                 a helper's message, queued into a turn (161, never a start)
#   "<cross-session-message"         a message from another session as the prompt hook is given it,
#                                    and as it is queued into a running turn: the element alone,
#                                    without the line the transcript writes before it (queued: seen
#                                    directly, origin kind "peer"; prompt hook: inferred, the copy of
#                                    the notes was kept as for a typed prompt in 39 of 39 such turns)
#   "[Cross-session idle notice]"    another session's notice that it is idle (4 turns, prompt
#                                    source "system", never typed)
# A message from another session is one form in two dresses, "Another Claude session sent a
# message:" and "<cross-session-message", and both are listed so that the turn's starting record,
# the messages queued into it and the prompt hook's copy of the notes are all read alike, whichever
# dress each is given.
OT_FORMS_JQ='["<task-notification>", "Another Claude session sent a message:", "Stop hook feedback:", "[Usage limit reached", "[Earlier usage-limit notes", "Your claude.ai usage limit has reset", "This session is being continued from a previous conversation", "The rc-reconnect plugin sent a message:", "<agent-message", "<cross-session-message", "[Cross-session idle notice]"]'

OT_JQ='
  def ot_forms: '"$OT_FORMS_JQ"';
  # The text a record leads with: a string, or the first block when it is text; else nothing.
  def ot_lead: if type == "string" then .
               elif type == "array" then (if (.[0] | type) == "object" and .[0].type == "text" then (.[0].text // "" | tostring) else "" end)
               else "" end;
  def ot_form: . as $t | any(ot_forms[]; . as $f | $t | startswith($f));
  def ot_pid: (.promptId // "" | tostring);
  def ot_typed: (((.origin | type) == "object") and ((.origin.kind // "" | tostring) == "human"))
                or ((.promptSource // "" | tostring) | IN("typed", "queued"));
  def ot_text_rec: type == "object" and .type == "user" and (.message | type) == "object"
                   and ((.message.content | type) == "string"
                        or ((.message.content | type) == "array"
                            and any(.message.content[]; type == "object" and .type == "text")
                            and (any(.message.content[]; type == "object" and .type == "tool_result") | not)));
  def ot_start: ot_text_rec and (ot_typed | not) and (.message.content | ot_lead | ot_form);
  def ot_queued: type == "object" and .type == "attachment" and (.attachment | type) == "object"
                 and .attachment.type == "queued_command";
  def ot_queued_own: (((.attachment.origin | type) == "object") and ((.attachment.origin.kind // "" | tostring) == "human"))
                     or ((.attachment.prompt | ot_lead | ot_form) | not);
'

# _ot_machine_turn - true when this Stop ends a turn started by one of the forms (see above).
# Sets OT_PID to the turn's prompt id when it does.
OT_PID=""
_ot_machine_turn() {
  OT_PID=""
  [[ "$EVENT" == Stop ]] || return 1
  _ot_on || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local pid="" tp="" slug size bytes cut=false v=""
  {
    IFS= read -r pid; IFS= read -r tp
  } < <(printf '%s' "$INPUT" | jq -r '(.prompt_id // "" | tostring), (.transcript_path // "" | tostring)' 2>/dev/null)
  # jq on Windows ends its lines with a carriage return.
  pid="${pid%$'\r'}"; tp="${tp%$'\r'}"
  # Claude Code's prompt ids are UUIDs. Anything else is not read.
  [[ "$pid" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || return 1
  [[ -n "${APROPOS_TRANSCRIPT:-}" ]] && tp="$APROPOS_TRANSCRIPT"
  if [[ -z "$tp" ]]; then
    # Where Claude Code keeps it: the working directory with every other character a dash.
    [[ -n "$CWD" && -n "$SID" ]] || return 1
    slug="${CWD//[^A-Za-z0-9]/-}"; tp="${HOME}/.claude/projects/${slug}/${SID}.jsonl"
  fi
  # A Windows path reads the same with forward slashes, in every shell this runs in.
  tp="${tp//\\//}"
  [[ -s "$tp" ]] || return 1
  # The same part of the transcript the idle check-in reads, and the same setting.
  bytes="${APROPOS_CHECKIN_TAIL_BYTES:-4194304}"
  [[ "$bytes" =~ ^[0-9]{1,10}$ ]] && (( 10#$bytes > 0 )) || bytes=4194304
  bytes=$(( 10#$bytes ))
  size="$(wc -c < "$tp" 2>/dev/null)"; size="${size//[[:space:]]/}"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  # Read from part way through a line, the first line is not a whole record: it is dropped.
  (( size > bytes )) && cut=true
  # First, cheaply: the first record that carries the prompt id, read line by line and parsed only
  # when the line holds the id, stopping there. A turn the person started ends here.
  v="$(tail -c "$bytes" "$tp" 2>/dev/null | jq -n -R -r --arg pid "$pid" "$OT_JQ"'
      (first(inputs | select(contains($pid)) | fromjson? | select(ot_text_rec and ot_pid == $pid)) // null)
      | if . == null then "none" elif ot_start then "machine" else "own" end' 2>/dev/null)"
  v="${v%$'\r'}"
  [[ "$v" == machine ]] || return 1
  # Then the whole part read, for what came before and after it.
  v="$(tail -c "$bytes" "$tp" 2>/dev/null | jq -R -s -r --arg pid "$pid" --argjson cut "$cut" "$OT_JQ"'
      (split("\n") | (if $cut then .[1:] else . end) | map(fromjson? // empty) | map(select(type == "object"))) as $r
      | ([range(0; $r | length) as $k | select(($r[$k] | ot_text_rec) and ($r[$k] | ot_pid) == $pid) | $k] | first) as $i
      | if $i == null then "keep"
        elif ($r[$i] | ot_start | not) then "keep"
        elif $cut and ([$r[:$i][] | select(.type == "user" and ot_pid != "" and ot_pid != $pid)] | length) == 0 then "keep"
        elif any($r[$i + 1:][]; ot_text_rec and (ot_pid != $pid or ot_typed)) then "keep"
        elif any($r[$i + 1:][]; ot_queued and ot_queued_own) then "keep"
        else "skip" end' 2>/dev/null)"
  v="${v%$'\r'}"
  [[ "$v" == skip ]] || return 1
  OT_PID="$pid"
  return 0
}

# The note files the copy is kept for, in TRACK_DIR, each "<name>-<session>.txt".
OT_NOTES="description worktype task project"

# _ot_prompt_kind - "m" when the prompt this prompt hook was given (INPUT's prompt) is a string that
# begins with one of the forms, else "t": any other prompt, or one that cannot be read (no jq, an
# input that is not JSON, no prompt). One jq run.
_ot_prompt_kind() {
  local k=""
  if command -v jq >/dev/null 2>&1; then
    k="$(printf '%s' "$INPUT" | jq -r "$OT_JQ"'
        if type == "object" and (.prompt | type) == "string" and (.prompt | ot_form) then "m" else "t" end' 2>/dev/null)"
    # jq on Windows ends its lines with a carriage return.
    k="${k%$'\r'}"
  fi
  if [[ "$k" == m ]]; then printf 'm'; else printf 't'; fi
}

# _ot_snap <stamp> - at a prompt, with the setting on: copy the session's four note files as they
# stand, and record whether the prompt began with a form (_ot_prompt_kind) and which notes exist,
# keyed by the stamp the prompt is about to write: "s:<stamp> <m or t> <four flags>". Builtins but
# for that one jq run; this runs on every prompt for a person with the setting on.
_ot_snap() {
  local t f v hdr="s:$1 $(_ot_prompt_kind)"
  for t in $OT_NOTES; do
    f="$TRACK_DIR/$t-$SID.txt"
    if [[ -f "$f" ]]; then
      v=""; IFS= read -r -d '' v < "$f" 2>/dev/null
      printf '%s' "$v" > "$TRACK_DIR/ownturns-$t-$SID.txt" 2>/dev/null || return 0
      hdr+=" 1"
    else
      hdr+=" 0"
    fi
  done
  # Written last: a copy that failed above leaves the earlier key, which matches no stamp to come.
  printf '%s\n' "$hdr" > "$TRACK_DIR/ownturns-$SID.txt" 2>/dev/null
  return 0
}

# _ot_snap_ours - true when the copy of the notes kept at a prompt is this turn's: it was kept for a
# prompt that began with a form ("m"), it holds exactly four flags of 0 or 1, and its key is the
# prompt stamp still on disk or, once a skipped Stop of this turn has put the notes back, this turn's
# prompt id (OT_PID, set by _ot_machine_turn), so a Stop after another hook's send-back in the same
# turn is skipped and puts them back again. False when there is no copy; when it is another turn's,
# which is when this turn's prompt hook did not run (a Stop that records removes the stamp, a skipped
# one rekeys the copy to its own prompt id); when it was kept for a typed prompt ("t": an interrupted
# typed turn leaves its copy under its stamp); and when it cannot be read as above. Sets OT_FLAGS to
# the copy's four flags (which notes existed). Builtins only.
OT_FLAGS=""
_ot_snap_ours() {
  local hf="$TRACK_DIR/ownturns-$SID.txt" sf="$TRACK_DIR/turnstart-$SID.txt" h="" st=""
  local key="" kind="" f1="" f2="" f3="" f4="" more=""
  OT_FLAGS=""
  [[ -s "$hf" ]] || return 1
  IFS= read -r h < "$hf" 2>/dev/null
  read -r key kind f1 f2 f3 f4 more <<< "$h"
  [[ "$kind" == m && -z "$more" && "$f1$f2$f3$f4" =~ ^[01]{4}$ ]] || return 1
  if [[ -s "$sf" ]]; then IFS= read -r st < "$sf" 2>/dev/null; st="${st//[[:space:]]/}"; fi
  [[ ( -n "$st" && "$key" == "s:$st" ) || ( -n "$OT_PID" && "$key" == "p:$OT_PID" ) ]] || return 1
  OT_FLAGS="$f1 $f2 $f3 $f4"
  return 0
}

# _ot_restore - at a skipped Stop: put the four note files back as the turn's prompt found them,
# when the copy is this turn's (_ot_snap_ours). Otherwise nothing is touched.
_ot_restore() {
  local hf="$TRACK_DIR/ownturns-$SID.txt" t f v cur
  local f1="" f2="" f3="" f4="" fl
  _ot_snap_ours || return 0
  read -r f1 f2 f3 f4 <<< "$OT_FLAGS"
  set -- "$f1" "$f2" "$f3" "$f4"
  for t in $OT_NOTES; do
    fl="$1"; shift
    f="$TRACK_DIR/$t-$SID.txt"
    if [[ "$fl" == 1 ]]; then
      v=""; IFS= read -r -d '' v < "$TRACK_DIR/ownturns-$t-$SID.txt" 2>/dev/null
      cur=""; [[ -f "$f" ]] && IFS= read -r -d '' cur < "$f" 2>/dev/null
      if [[ ! -f "$f" || "$cur" != "$v" ]]; then printf '%s' "$v" > "$f" 2>/dev/null; fi
    elif [[ "$fl" == 0 && -e "$f" ]]; then
      rm -f "$f" 2>/dev/null
    fi
  done
  printf 'p:%s m %s %s %s %s\n' "$OT_PID" "$f1" "$f2" "$f3" "$f4" > "$hf" 2>/dev/null
  return 0
}
