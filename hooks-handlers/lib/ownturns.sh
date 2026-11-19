#!/usr/bin/env bash
# Recording only the turns a person starts, in sessions they are present for (APROPOS_OWN_TURNS),
# and the one parser every per-person switch is read with.
#
# Sourced by time-track-per-turn.sh, and by the standalone harnesses tests/harness-own-turns-real.sh
# and tests/harness-attended-real.sh, which put real sessions' turns to the same decision. Local only:
# no credentials and no database access.
#
# WHY. A person's timecard should hold only the work they did themselves. Everything else is
# measured from the session transcripts separately, as agent time. Before this rule was the default,
# overnight runs, scheduled jobs, `claude -p` runs and loops all landed on the card of whoever owned
# the computer (one person's card held 163 hours at night or on weekends over twelve days), and so did
# background task notices, helpers reporting back, messages from other sessions, the recorder's own
# send-back, usage-limit notices and the continuation after a compaction.
#
# THE RULE (closed, measured on real transcripts before it was built, 2026-11-13; amended 2026-11-18).
# With the setting on, which is the default, a turn goes on the person's card only when all four hold:
#   1. CLAUDE_CODE_ENTRYPOINT is exactly cli or claude-vscode;
#   2. CLAUDE_CODE_SESSION_ATTENDED is exactly 1, or is not set at all (a Claude Code older than about
#      2.1.303 does not set it, and its turns are then judged by rules 1, 3 and 4 only);
#   3. the event is the main session's prompt hook or Stop, with no top-level agent_id in its input;
#   4. the turn's starting prompt record shows the person started it (turnOrigin human, origin kind
#      human, a prompt source of typed, or a prompt source of queued when its prompt is not one of the
#      forms below), or a later record of the same turn, or a message queued into it, is marked so.
# Everything else records nothing, and is left to agent time: other entry points (claude -p, the SDK,
# scheduled runs), an attended flag of 0 or anything but 1 (background and child sessions), helper
# agents, /loop and cron turns (turnOrigin scheduled), notices, messages from other sessions and
# system turns, and machine-written records such as the notice after a compaction.
#
# Two exceptions keep the release before's behaviour rather than change it. (a) The attended flag not
# set, above. (b) A turn whose starting record cannot be read records as the release before records
# it: no jq, no transcript, a Stop that names no prompt, the start further back than the part of the
# transcript read, and a starting record that carries no origin label and no Claude Code version (so
# its origin cannot be told). For such a record the release before's own rule is applied unchanged: it
# is skipped only when it begins with one of the forms below and nothing of the person's follows.
# Measured: every user record Claude Code wrote from 2.1.268 to 2.1.322 on the computers read carries
# a version, and every one the person typed carries an origin label; the unlabelled ones are the
# compaction summary.
#
# APROPOS_OWN_TURNS=off (or 0, false, no, disabled) is the escape hatch: it turns the whole rule off,
# and every turn records as in the releases before it.
#
# THE TURN'S STARTING PROMPT RECORD. Claude Code writes a prompt id on every user record of a turn,
# and passes the turn's prompt id to the Stop hook (prompt_id). The turn's starting record is the
# FIRST user record carrying text (a string, or blocks with a text block and no tool result) whose
# prompt id is the one the Stop names. The first and not the last: the recorder's own send-back, the
# usage-limit notes and the compaction summary are written INTO a turn under its own prompt id, after
# the prompt that started it. Taking the last would skip a person's own turn whenever one of those
# followed their prompt. A note Claude Code writes before a typed prompt, under the same prompt id
# (the reminder that a session was renamed), makes that note the starting record, and the typed record
# after it is what marks the turn as the person's.
#
# SKIPPED means what the idle check-in skip means: no entry opened or amended, no send-back, no
# delivery or repair, no notice, and the next turn finds the description, worktype, task, project and
# open entries as the turn before left them. A machine-started turn can write the session's notes
# itself (sessions are told to write them every turn), so each prompt's hook keeps a copy of the four
# note files as they stand when the prompt arrives (_ot_snap), and a skipped Stop puts them back
# (_ot_restore). A turn whose notes cannot be put back with certainty (the copy is not its own, below)
# is recorded exactly as the release before records it.
#
# WHICH COPY IS THE TURN'S OWN (_ot_snap_ours). The copy is keyed by the prompt stamp its hook wrote,
# and says whether its prompt began with one of the forms ("m") or not ("t"), and keeps the prompt and
# prompt id its hook was given. It is the turn's own when:
#   - its key is this turn's prompt id, written by an earlier skipped Stop of the same turn; or
#   - its key is the live prompt stamp, and it was kept for a form, or for this turn's prompt id, or
#     for the same text as the turn's starting record or a message queued into the turn; or
#   - no prompt stamp is live, which means no prompt hook has run since the last Stop, and the copy is
#     the one that Stop left (key z:, or p: from a skipped Stop): the notes as the turn found them.
# Refused otherwise, and the turn records as the release before records it. The case that matters: a
# typed turn interrupted before its Stop leaves its copy under its stamp; a machine turn after it whose
# prompt hook did not run must not take that copy, or the typed turn's notes would be lost. It does
# not: the copy was kept for another prompt, so the machine turn records the interrupted typed turn's
# notes from that turn's start, exactly as the release before. Two known cases are unchanged from
# 0.2.16: a typed prompt that itself opens with a pasted form, interrupted, then a machine turn whose
# prompt hook did not run, takes that copy (it was kept for a form) and the interrupted turn gets no
# entry; and a notice interrupted after its session wrote notes, then such a machine turn, puts the
# notes back as they stood before the notice.
#
# A MESSAGE QUEUED INTO A MACHINE TURN. Claude Code runs the prompt hook for each message
# queued into a running turn. When a notice or a message from another session arrives that way after
# the machine turn's session wrote its notes, the hook used to find those notes and record the machine
# turn there and then, and take a new copy holding them. So at a prompt hook whose prompt begins with
# one of the forms and is not marked as typed, while the copy under the live stamp was kept for a form,
# the hook records nothing and keeps that copy under the new stamp (_ot_keep_copy). Every other prompt
# hook behaves exactly as before.

# _setting_on <value> - true when a per-person switch is on: on, 1, true or yes (on, true and yes in
# any case). Anything else, or nothing, is off. The one parser for every switch that is off by
# default (the send-back), so they are all read alike. Builtins only.
_setting_on() {
  case "${1:-}" in
    [Oo][Nn]|1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) return 0 ;;
  esac
  return 1
}
# _setting_off <value> - true when a switch that is on by default is turned off: off, 0, false, no or
# disabled, in any case. Anything else, or nothing, leaves it on. Builtins only.
_setting_off() {
  case "${1:-}" in
    [Oo][Ff][Ff]|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd]) return 0 ;;
  esac
  return 1
}

# On unless the person has turned it off (the escape hatch).
_ot_on() { ! _setting_off "${APROPOS_OWN_TURNS:-}"; }

# _ot_unattended - true when rules 1 to 3 say this event records nothing on the card: the entry point
# is not exactly cli or claude-vscode, the attended flag is set and is not exactly 1, or the input
# carries a top-level agent_id (a helper agent's event). Sets OT_GATE to which (entrypoint, attended
# or agent). Read from the environment Claude Code gives every hook, and the input.
OT_GATE=""
_ot_unattended() {
  OT_GATE=""
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    cli|claude-vscode) ;;
    *) OT_GATE=entrypoint; return 0 ;;
  esac
  if [[ -n "${CLAUDE_CODE_SESSION_ATTENDED+x}" && "${CLAUDE_CODE_SESSION_ATTENDED}" != 1 ]]; then
    OT_GATE=attended; return 0
  fi
  local a=""
  if command -v jq >/dev/null 2>&1; then
    a="$(printf '%s' "$INPUT" | jq -r 'if type == "object" and ((.agent_id // null) != null) then "y" else "n" end' 2>/dev/null)"
    a="${a%$'\r'}"
  elif [[ "$INPUT" =~ \"agent_id\"[[:space:]]*:[[:space:]]*[^n[:space:]] ]]; then
    a=y
  fi
  if [[ "$a" == y ]]; then OT_GATE=agent; return 0; fi
  return 1
}

# The closed list of forms. Each was found at the start of prompt records Claude Code wrote itself,
# never at the start of one marked typed, on every local transcript of the computer measured:
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
#                                    without the line the transcript writes before it. Queued: seen
#                                    directly, origin kind "peer". Prompt hook: inferred, not seen in a
#                                    hook input; the copy of the notes was kept as for a typed prompt in
#                                    39 of 39 such turns measured before this form was listed.
#   "[Cross-session idle notice]"    another session's notice that it is idle (4 turns, prompt
#                                    source "system", never typed)
# OT_BOUNDED_JQ lists the forms that are an element name, which match only when the name is followed
# by whitespace, ">" or the end of the text, so a longer element name that starts with the same
# letters is not taken for the form.
OT_FORMS_JQ='["<task-notification>", "Another Claude session sent a message:", "Stop hook feedback:", "[Usage limit reached", "[Earlier usage-limit notes", "Your claude.ai usage limit has reset", "This session is being continued from a previous conversation", "The rc-reconnect plugin sent a message:", "<agent-message", "<cross-session-message", "[Cross-session idle notice]"]'
OT_BOUNDED_JQ='["<cross-session-message"]'

OT_JQ='
  def ot_forms: '"$OT_FORMS_JQ"';
  def ot_bounded: '"$OT_BOUNDED_JQ"';
  # The text a record leads with: a string, or the first block when it is text; else nothing.
  def ot_lead: if type == "string" then .
               elif type == "array" then (if (.[0] | type) == "object" and .[0].type == "text" then (.[0].text // "" | tostring) else "" end)
               else "" end;
  def ot_form: . as $t | any(ot_forms[]; . as $f
                 | ($t | startswith($f))
                   and ((any(ot_bounded[]; . == $f) | not)
                        or ($t | length) == ($f | length)
                        or ($t[($f | length):(($f | length) + 1)] | test("^[\\s>]"))));
  def ot_pid: (.promptId // "" | tostring);
  # The mark of a typed record the release before reads (exception b, and its rule for a queued message).
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
  # Rule 4. A record carries an origin label when it has a turn origin, an origin or a prompt source.
  def ot_turn_origin: (.turnOrigin | if type == "object" then (.kind // "" | tostring) elif type == "string" then . else "" end);
  def ot_labelled: ((.turnOrigin // null) != null) or ((.origin // null) != null) or ((.promptSource // null) != null);
  # A record whose origin cannot be read: no label and no Claude Code version (exception b).
  def ot_unread: (ot_labelled | not) and ((.version // null) == null);
  # Marked as started by the person: turnOrigin human, origin kind human or a prompt source of typed;
  # or a prompt source of queued when its prompt is not one of the forms.
  def ot_person: ot_labelled
                 and (if (.promptSource // "" | tostring) == "queued" then ((.message.content | ot_lead | ot_form) | not)
                      else (ot_turn_origin == "human")
                           or (((.origin | type) == "object") and ((.origin.kind // "" | tostring) == "human"))
                           or ((.promptSource // "" | tostring) == "typed") end);
  # A message queued into the turn counts as the person when it is marked human, or carries no origin,
  # and its prompt is not one of the forms.
  def ot_queued_person: (((.attachment.origin // null) == null)
                         or (((.attachment.origin | type) == "object") and ((.attachment.origin.kind // "" | tostring) == "human")))
                        and ((.attachment.prompt | ot_lead | ot_form) | not);
  # What the prompt hook is given for a record: a message from another session without the line the
  # transcript writes before it.
  def ot_hookview: if startswith("Another Claude session sent a message:\n<cross-session-message")
                   then ltrimstr("Another Claude session sent a message:\n") else . end;
  def ot_norm: gsub("\r\n"; "\n") | sub("\\s+$"; "");
'

# _ot_machine_turn - true when this Stop ends a turn the rule says records nothing (see above), read
# from the transcript. Sets OT_PID to the turn's prompt id, and OT_FPM to 1 when the copy of the notes
# kept at the last prompt hook (ownturns-hook-<session>.json) was kept for this turn's prompt id or for
# the text of its starting record or of a message queued into it, else 0.
OT_PID=""; OT_FPM=0
_ot_machine_turn() {
  OT_PID=""; OT_FPM=0
  [[ "$EVENT" == Stop ]] || return 1
  _ot_on || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local pid="" tp="" slug size bytes cut=false v="" fpm="" hf
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
      | if . == null then "none"
        elif ot_unread then (if ot_start then "maybe" else "own" end)
        elif ot_person then "own"
        else "maybe" end' 2>/dev/null)"
  v="${v%$'\r'}"
  [[ "$v" == maybe ]] || return 1
  # Then the whole part read, for what came before and after it, and whether the copy of the notes
  # kept at the last prompt hook was kept for this turn.
  hf="$TRACK_DIR/ownturns-hook-$SID.json"
  local hargs=(--argjson hin '[]')
  [[ -s "$hf" ]] && hargs=(--slurpfile hin "$hf")
  v="$(tail -c "$bytes" "$tp" 2>/dev/null | jq -R -s -r --arg pid "$pid" --argjson cut "$cut" "${hargs[@]}" "$OT_JQ"'
      (split("\n") | (if $cut then .[1:] else . end) | map(fromjson? // empty) | map(select(type == "object"))) as $r
      | ([range(0; $r | length) as $k | select(($r[$k] | ot_text_rec) and ($r[$k] | ot_pid) == $pid) | $k] | first) as $i
      | (if $i == null then "keep"
         elif $cut and ([$r[:$i][] | select(.type == "user" and ot_pid != "" and ot_pid != $pid)] | length) == 0 then "keep"
         elif ($r[$i] | ot_unread) then
           (if ($r[$i] | ot_start | not) then "keep"
            elif any($r[$i + 1:][]; ot_text_rec and (ot_pid != $pid or ot_typed)) then "keep"
            elif any($r[$i + 1:][]; ot_queued and ot_queued_own) then "keep"
            else "skip" end)
         elif ($r[$i] | ot_person) then "keep"
         # A later record marked as the person, or one whose origin cannot be read under another prompt
         # id (or none), which the release before also took as a turn that may be the person.
         elif any($r[$i + 1:][]; ot_text_rec and (ot_person or (ot_unread and (ot_pid != $pid)))) then "keep"
         elif any($r[$i + 1:][]; ot_queued and ot_queued_person) then "keep"
         else "skip" end) as $v
      | if $v != "skip" then "keep"
        else
          (($hin[0] // {}) | if type == "object" then . else {} end) as $h
          | (($h.prompt_id // "") | tostring) as $hpid
          | ([$r[$i].message.content | ot_lead] + [$r[$i + 1:][] | select(ot_queued) | .attachment.prompt | ot_lead]
             | map(., ot_hookview) | map(ot_norm)) as $texts
          | if $hpid != "" and $hpid == $pid then "skip 1"
            elif (($h.prompt // null) | type) == "string" and ($texts | any(.[]; . == ($h.prompt | ot_norm))) then "skip 1"
            else "skip 0" end
        end' 2>/dev/null)"
  v="${v%$'\r'}"
  read -r v fpm <<< "$v"
  [[ "$v" == skip ]] || return 1
  OT_PID="$pid"
  [[ "$fpm" == 1 ]] && OT_FPM=1
  return 0
}

# The note files the copy is kept for, in TRACK_DIR, each "<name>-<session>.txt".
OT_NOTES="description worktype task project"

# _ot_hook_read - at a prompt hook: sets OT_KIND to "m" when the prompt it was given (INPUT's prompt)
# is a string that begins with one of the forms and the input does not mark it as typed by the person,
# else "t" (any other prompt, or one that cannot be read: no jq, an input that is not JSON, no prompt);
# and OT_HOOKJSON to the prompt and prompt id it was given, as one line of JSON, or nothing. One jq run.
OT_KIND=""; OT_HOOKJSON=""
_ot_hook_read() {
  local k="" j=""
  OT_KIND=t; OT_HOOKJSON=""
  if command -v jq >/dev/null 2>&1; then
    {
      IFS= read -r k; IFS= read -r j
    } < <(printf '%s' "$INPUT" | jq -c -r "$OT_JQ"'
        if type == "object" then
          (if (.prompt | type) == "string" and (.prompt | ot_form) and (ot_typed | not) and (ot_turn_origin != "human") then "m" else "t" end),
          ({prompt: (.prompt // null), prompt_id: (.prompt_id // null)} | tojson)
        else "t", "" end' 2>/dev/null)
    # jq on Windows ends its lines with a carriage return.
    k="${k%$'\r'}"; j="${j%$'\r'}"
  fi
  [[ "$k" == m ]] && OT_KIND=m
  OT_HOOKJSON="$j"
  return 0
}

# _ot_prompt_kind - prints OT_KIND for this prompt hook's input (_ot_hook_read).
_ot_prompt_kind() { _ot_hook_read; printf '%s' "$OT_KIND"; }

# _ot_snap <stamp> - at a prompt: copy the session's four note files as they stand, record whether
# the prompt began with a form (_ot_hook_read) and which notes exist, keyed by the stamp the prompt is
# about to write: "s:<stamp> <m or t> <four flags>", and keep the prompt and prompt id the hook was
# given beside it. Builtins but for that one jq run.
_ot_snap() {
  local t f v hdr
  _ot_hook_read
  hdr="s:$1 $OT_KIND"
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
  if [[ -n "$OT_HOOKJSON" ]]; then
    printf '%s\n' "$OT_HOOKJSON" > "$TRACK_DIR/ownturns-hook-$SID.json" 2>/dev/null
  else
    rm -f "$TRACK_DIR/ownturns-hook-$SID.json" 2>/dev/null
  fi
  # Written last: a copy that failed above leaves the earlier key, which matches no stamp to come.
  printf '%s\n' "$hdr" > "$TRACK_DIR/ownturns-$SID.txt" 2>/dev/null
  return 0
}

# _ot_header - reads the copy's header into OT_HKEY, OT_HKIND and OT_HFLAGS; false when there is none
# or it is not one key, one kind and exactly four flags of 0 or 1.
OT_HKEY=""; OT_HKIND=""; OT_HFLAGS=""
_ot_header() {
  local hf="$TRACK_DIR/ownturns-$SID.txt" h="" f1="" f2="" f3="" f4="" more=""
  OT_HKEY=""; OT_HKIND=""; OT_HFLAGS=""
  [[ -s "$hf" ]] || return 1
  IFS= read -r h < "$hf" 2>/dev/null
  read -r OT_HKEY OT_HKIND f1 f2 f3 f4 more <<< "$h"
  [[ -n "$OT_HKEY" && -z "$more" && "$f1$f2$f3$f4" =~ ^[01]{4}$ ]] || return 1
  OT_HFLAGS="$f1 $f2 $f3 $f4"
  return 0
}

# _ot_live_stamp - prints the prompt stamp on disk, if any.
_ot_live_stamp() {
  local sf="$TRACK_DIR/turnstart-$SID.txt" st=""
  if [[ -s "$sf" ]]; then IFS= read -r st < "$sf" 2>/dev/null; st="${st//[[:space:]]/}"; fi
  printf '%s' "$st"
}

# _ot_snap_ours - true when the copy of the notes is this turn's own (WHICH COPY IS THE TURN'S OWN,
# above). Sets OT_FLAGS to the copy's four flags (which notes existed). Builtins only.
OT_FLAGS=""
_ot_snap_ours() {
  local st=""
  OT_FLAGS=""
  _ot_header || return 1
  st="$(_ot_live_stamp)"
  if [[ -n "$OT_PID" && "$OT_HKEY" == "p:$OT_PID" ]]; then :
  elif [[ -n "$st" ]]; then
    [[ "$OT_HKEY" == "s:$st" ]] || return 1
    [[ "$OT_HKIND" == m || "$OT_FPM" == 1 ]] || return 1
  else
    [[ "$OT_HKEY" == z:* || "$OT_HKEY" == p:* ]] || return 1
  fi
  OT_FLAGS="$OT_HFLAGS"
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

# _ot_baseline - at the end of a Stop that recorded (or any Stop that changes nothing): copy the notes
# as the Stop leaves them, keyed "z:<time>". With no prompt stamp live, the next turn whose prompt
# hook does not run finds its notes exactly so, and a skip puts them back to this. Builtins only.
_ot_baseline() {
  local t f v hdr="z:${NOW:-0} b"
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
  rm -f "$TRACK_DIR/ownturns-hook-$SID.json" 2>/dev/null
  printf '%s\n' "$hdr" > "$TRACK_DIR/ownturns-$SID.txt" 2>/dev/null
  return 0
}

# _ot_keep_copy <new stamp> - at a prompt hook: true, and the copy rekeyed to the new stamp,
# when this prompt begins with one of the forms and is not marked typed, and the copy under the live
# stamp was kept for a form. The caller then records nothing and takes no new copy. Otherwise false
# and nothing is touched. One jq run (_ot_hook_read).
_ot_keep_copy() {
  local st=""
  _ot_header || return 1
  [[ "$OT_HKIND" == m ]] || return 1
  st="$(_ot_live_stamp)"
  [[ -n "$st" && "$OT_HKEY" == "s:$st" ]] || return 1
  _ot_hook_read
  [[ "$OT_KIND" == m ]] || return 1
  printf 's:%s m %s\n' "$1" "$OT_HFLAGS" > "$TRACK_DIR/ownturns-$SID.txt" 2>/dev/null || return 1
  return 0
}
