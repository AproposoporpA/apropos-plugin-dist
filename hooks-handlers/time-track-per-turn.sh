#!/usr/bin/env bash
# apropos plugin — per-turn time recording hook. Handles TWO events:
#
#   UserPromptSubmit — stamps the turn's real start time, flushes the queue, and
#                      recovers a description that Stop failed to consume.
#   Stop             — the primary recorder. Runs after the response is complete,
#                      so the model's description for THIS turn already exists.
#
# Always records (or durably queues) exactly one start-marker per turn.
# Credentialed write stays in R: Record-Time.ps1; this layer is local so it
# survives R:/network outages. Exits 0 always.
#
# WHY TWO EVENTS (changed 2026-08-07). The hook previously ran on UserPromptSubmit
# only, which fires at the START of a turn and therefore read the description file
# written at the END of the previous turn. Three consequences, all measured on
# one team machine on 2026-08-07:
#   1. Turn 1 of every session had no description file yet, so it recorded the
#      placeholder "[needs description] <cwd basename>". With a working directory
#      named "Claude" that literal string was "[needs description]
#      Claude", putting an AI reference on a client-invoice-facing field. 13 of
#      that day's 39 entries.
#   2. The final turn of every session was never recorded, because no further
#      prompt ever arrived to consume its file. 7 orphaned description files were
#      sitting in /tmp/claude-timetrack at worktypes 18, 48, 57 and 86 with zero
#      entries at any of those worktypes in the database.
#   3. Every description that did land was stamped with the NEXT turn's start time.
# Recording on Stop fixes all three: the description is the current turn's, the
# final turn fires, and StartTime comes from the stamp laid down at prompt time.
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What the person is shown. Claude Code discards the stderr of a hook that exits 0 (it goes
# to the debug log only), so a notice written there reaches nobody. What it does show is the
# systemMessage of a JSON object printed on stdout, for both events this hook runs on. So
# stdout is kept for that one object: file descriptor 3 holds it, and everything else this
# hook runs writes its stdout nowhere, because any stray line would stop the object being
# read as JSON. The notice is printed once, just before the final flush (see the end of file).
exec 3>&1 1>/dev/null
APROPOS_NOTICE=""
notice_add() { APROPOS_NOTICE="${APROPOS_NOTICE:+$APROPOS_NOTICE }$1"; }
notice_emit() {
  [[ -n "$APROPOS_NOTICE" ]] || return 0
  local s="$APROPOS_NOTICE" bs dq
  bs="$(printf '\134')"; dq='"'     # a backslash and a double quote, the two JSON escapes
  s="${s//"$bs"/"$bs$bs"}"; s="${s//"$dq"/"$bs$dq"}"
  s="${s//$'\t'/ }"; s="${s//$'\r'/ }"; s="${s//$'\n'/ }"
  # Any other control character is not allowed raw in a JSON string. The login is already
  # cleaned (apropos_login); this covers whatever else reaches the notice.
  s="$(printf '%s' "$s" | tr -d '\000-\037\177')"
  printf '{"systemMessage":"%s"}\n' "$s" >&3
}
source "$HERE/lib/queue.sh"
source "$HERE/lib/writer.sh"
source "$HERE/lib/ledger.sh"

TRACK_DIR="${APROPOS_TRACK_DIR:-/tmp/claude-timetrack}"
QUEUE="${HOME}/.claude/apropos-time/pending.tsv"
mkdir -p "$TRACK_DIR" "${HOME}/.claude/apropos-time" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Parse session id + cwd + event (prefer jq; grep fallback).
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
else
  SID="$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  CWD="$(printf '%s' "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  EVENT="$(printf '%s' "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
fi
SID="${SID:-${CLAUDE_CODE_SESSION_ID:-nosession}}"
# Older payloads / direct invocation carry no event name. Treat as UserPromptSubmit
# so an un-migrated hooks.json keeps the previous single-event behaviour.
EVENT="${EVENT:-UserPromptSubmit}"

# Opt out of time recording entirely. Scheduled and headless runs are nobody's
# working time: a `claude -p` job fired by Task Scheduler has no human at the keyboard
# and never writes a description file, so every one of them booked a
# "[needs description] <cwd>" placeholder against the machine's owner. Over the 2026-08-08 weekend
# that was 7 scheduled runs, which the queue defect then multiplied into 239 rows.
#
# Two ways to opt out, because the launchers and the agent directories are maintained
# by different people:
#   APROPOS_TIME_TRACKING=off   (or APROPOS_SKIP=1) in the scheduled launcher's env
#   a .apropos-notime file in the working directory, which covers that agent however
#   it is started, including a manual run
case "$(printf '%s' "${APROPOS_TIME_TRACKING:-}" | tr '[:upper:]' '[:lower:]')" in
  off|0|false|no|disabled) exit 0 ;;
esac
case "$(printf '%s' "${APROPOS_SKIP:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) exit 0 ;;
esac
# Stamp the working directory before the marker check, not after. The Stop payload
# carries no cwd, so without this an opted-out session would exit at UserPromptSubmit
# having recorded nothing, and then Stop would have no cwd to test the marker against
# and would record anyway.
[[ -n "$CWD" ]] && printf '%s' "$CWD" > "$TRACK_DIR/cwd-$SID.txt" 2>/dev/null
# ONE walk up the tree, collecting everything the directory can tell us. Three markers:
#
#   .apropos-notime    do not record this work at all
#   .apropos-task      the task the work in this folder belongs to
#   .apropos-project   the project it belongs to
#
# The task and project markers exist because a session that does not state its task books
# the hour to the person's catch-all and says nothing: 28 of 40 entries and 3.33 of 5.08
# hours on 2026-08-27, including a customer go-live confirmation and a client dashboard
# republish. The folder knew every time, even when the session did not.
#
# Walking UP means the FIRST marker found is the NEAREST, so a marker deeper in the tree
# beats one at the client root. Only the first of each kind is taken.
#
# This is one walk, not three, and it uses bash string work rather than dirname. It called
# dirname once per level before, and a subprocess costs about 525ms on the machine this
# ships to, so a six-deep path spent several seconds of a per-turn budget that also has to
# fit a network write. Reading a marker uses the read builtin for the same reason.
#
# A marker is bounded to nine digits as well as being numeric. "A plain number" is not
# the same as "a plausible id": real ones are five figures, and a corrupted file should
# fail here, locally and visibly, rather than travel to the writer and land the hour
# somewhere nobody will find it.
_dir_task=""; _dir_proj=""
_optout_dir="$CWD"; [[ -z "$_optout_dir" && -s "$TRACK_DIR/cwd-$SID.txt" ]] && _optout_dir="$(cat "$TRACK_DIR/cwd-$SID.txt")"
if [[ -n "$_optout_dir" ]]; then
  _d="${_optout_dir//\\//}"; _d="${_d%/}"
  while [[ -n "$_d" && "$_d" != "/" && "$_d" != "." ]]; do
    [[ -e "$_d/.apropos-notime" ]] && exit 0
    if [[ -z "$_dir_task" && -s "$_d/.apropos-task" ]]; then
      _mv=""; read -r _mv < "$_d/.apropos-task" 2>/dev/null || _mv=""
      _mv="${_mv%$'\r'}"; _mv="${_mv#\#}"
      [[ "$_mv" =~ ^[0-9]{1,9}$ ]] && _dir_task="$_mv"
    fi
    if [[ -z "$_dir_proj" && -s "$_d/.apropos-project" ]]; then
      _mv=""; read -r _mv < "$_d/.apropos-project" 2>/dev/null || _mv=""
      _mv="${_mv%$'\r'}"
      [[ "$_mv" =~ ^[0-9]{1,9}$ ]] && _dir_proj="$_mv"
    fi
    case "$_d" in
      */*) _d="${_d%/*}" ;;
      *)   break ;;
    esac
  done
fi

# Person resolution.
#
# Until 0.2.9 the person came from a list of staff logins written into this file, and a
# login missing from it exited here: nothing recorded and nothing said, so the only symptom
# was an empty timesheet found days later, and every new person needed a release. Now the
# login is looked up in Apropos (lib/person.sh), cached on this machine, and a turn whose
# person cannot be identified is still kept: it is queued with the person unresolved, the
# turn says why in its systemMessage, session start raises an alert, and delivery resolves the person
# before writing. It is never written under a guessed person, and never dropped.
source "$HERE/lib/person.sh"
LOGIN="$(apropos_login)"
PERSON=""; PERSON_UNRESOLVED=""; PERSON_UNRESOLVED_ADVICE=""
if person_resolve "$LOGIN"; then
  PERSON="$PERSON_ID"
else
  PERSON_UNRESOLVED="$PERSON_CAUSE"; PERSON_UNRESOLVED_ADVICE="$PERSON_ADVICE"
fi

descf="$TRACK_DIR/description-$SID.txt"
wtf="$TRACK_DIR/worktype-$SID.txt"
taskf="$TRACK_DIR/task-$SID.txt"
projf="$TRACK_DIR/project-$SID.txt"
# The worktype the model wrote is a one-shot file, deleted at the end of the turn.
# These two are what make it survive: the session carries its last worktype, and the
# machine remembers the worktype last used on each task so a NEW session on known
# work does not fall back to Engineering.
stickywtf="$TRACK_DIR/worktype-sticky-$SID.txt"
taskwtf="$TRACK_DIR/task-worktype.tsv"
lastf="$TRACK_DIR/last-entry-$SID.txt"
startf="$TRACK_DIR/turnstart-$SID.txt"
cwdf="$TRACK_DIR/cwd-$SID.txt"

NOW="$(date -u +%s)"

# Description cap. The DB column is nvarchar(500) but the downstream Intervals
# import truncates at 255, which was cutting real entries mid-sentence with no
# signal. Cap here so the boundary is visible and consistent.
DESC_MAX=255

# Two flag wordings, because a flagged entry has two causes and they call for opposite
# responses. A description was written and the screen judged it unfit for a customer
# invoice, or nothing was written and there was nothing to judge. The first is the cost
# of protecting the invoice; the second is a session that did not do its job. Recording
# both as the same words made the placeholder rate uncountable, so the work to bring it down
# could not be sized against anything real.
#
# Constraints on any wording chosen here: it reaches a customer invoice, so it must name
# no tooling and read as an instruction to the person holding the timesheet; it must fit
# inside DESC_MAX whole; and the two must not share a prefix, or a count cannot separate
# them. Kept as constants rather than literals because the dedup guard, the audit and
# the tests all have to agree on them.
DESC_PH_NONE="[needs description]"
DESC_PH_REJECTED="[rewrite description]"

# Is this description one of the flags rather than a record of work? Used by the dedup
# guard, which must exempt EVERY flag: a flag is an admission that we do not know what
# the work was, not evidence that two turns were the same. Written as a function over
# both constants so adding a third wording cannot silently reintroduce the dropped-time
# defect QA found when the stricter screen first shipped.
_desc_is_placeholder() {
  case "$1" in
    "$DESC_PH_NONE"*|"$DESC_PH_REJECTED"*) return 0 ;;
  esac
  return 1
}

_hash() {
  # Short fingerprint of the description, so dedup can tell "same activity
  # re-marked" from "new work at the same worktype/task".
  if command -v md5sum >/dev/null 2>&1; then printf '%s' "$1" | md5sum | cut -c1-10
  elif command -v cksum >/dev/null 2>&1; then printf '%s' "$1" | cksum | tr -d ' '
  else printf '%s' "${#1}"; fi
}

# Cap how far back a turn-start stamp may drag an entry. The stamp is written at
# UserPromptSubmit and consumed when the response ends, so a session left idle keeps a
# stale stamp: observed 2026-08-11, work done at 07:13 PT was stamped 21:06 PT the
# previous evening, a 607-minute backdate that moved it onto the wrong day. Beyond this
# window the stamp is not a credible start time, so fall back to now-60s.
APROPOS_MAX_BACKDATE_SECS="${APROPOS_MAX_BACKDATE_SECS:-7200}"

# start_from_stamp <stampfile> -> echoes a UTC "YYYY-MM-DD HH:MM:SS"
start_from_stamp() {
  local f="$1" ts age
  if [[ -s "$f" ]]; then
    ts="$(tr -d '[:space:]' < "$f")"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      age=$(( NOW - ts ))
      if (( age >= 0 && age <= APROPOS_MAX_BACKDATE_SECS )); then
        date -u -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
        return 0
      fi
    fi
  fi
  date -u -d '1 minute ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -v-1M '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# Locate this session's transcript. Claude Code stores it at
#   ~/.claude/projects/<slug>/<session-id>.jsonl
# where <slug> is the working directory with every non-alphanumeric character
# replaced by a hyphen ("R:\Team Share\Claude" -> "R--Team-Share-Claude").
# Derived rather than read from the hook payload, because the Stop payload's fields
# are not guaranteed and the working directory is already stamped at prompt time.
# $APROPOS_TRANSCRIPT overrides, which is how the tests drive this.
transcript_path() {
  local sid="$1" dir="$2" slug p
  if [[ -n "${APROPOS_TRANSCRIPT:-}" ]]; then
    [[ -s "$APROPOS_TRANSCRIPT" ]] && { printf '%s' "$APROPOS_TRANSCRIPT"; return 0; }
    return 1
  fi
  [[ -n "$dir" && -n "$sid" ]] || return 1
  slug="$(printf '%s' "$dir" | sed 's/[^A-Za-z0-9]/-/g')"
  p="${HOME}/.claude/projects/${slug}/${sid}.jsonl"
  [[ -s "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

# Words that must never reach an invoice-facing field, whatever the source.
APROPOS_BANNED='claude|anthropic|\bAI\b|assistant|chatbot|copilot'

# Last resort before the placeholder: describe the turn from what the response
# actually said. The final assistant text block IS this turn's answer, because Stop
# only fires once the response is complete.
#
# Added 2026-08-12. The plugin README has claimed this behaviour since 0.2.0 but no
# code implemented it, so every turn where the model forgot to write a description
# booked "[needs description] <project>" instead. On one team machine the working
# directory is named "Claude", so that placeholder put a literal AI reference on a
# client-invoice-facing field, repeatedly.
# Shortest derived description worth putting on a timesheet. Measured against 12 real
# sessions: below this the candidates are things like "Sent", "Draft below" and
# "Incident is closed", which say less than an honest placeholder does.
#
# Length alone is not enough. A floor of 60 was tried and rejected because it threw
# out real descriptions ("Rebuilt the template and verified it at five widths.", 52).
# The bad short candidates are conversational acknowledgements, not short work, so
# they are matched by shape below instead.
APROPOS_DERIVE_MIN="${APROPOS_DERIVE_MIN:-40}"

# Punctuation the house style rules ban outright. Normalised rather than refused, and
# done with bash parameter expansion rather than sed: this runs on every turn, and a
# subprocess costs about half a second on the Windows shell this ships to.
_desc_normalise() {
  local s="$1"
  s="${s//—/-}"; s="${s//–/-}"
  s="${s//‘/\'}"; s="${s//’/\'}"
  s="${s//“/\"}"; s="${s//”/\"}"
  s="${s//…/...}"
  printf '%s' "$s"
}

# Is one token a past tense verb? Irregulars were matched as whole tokens, so every
# prefixed form was invisible: "rebuilt" is not "built", "rewrote" is not "wrote",
# "resent" is not "sent", "reset" is not "set". All four open real entries in the
# record, and a record of work carrying a copula in the same clause was then refused as
# a state report. Prefixes are stripped from a known short list rather than matching any
# suffix, because "present" ends in "sent" and "asset" ends in "set".
_desc_past_token() {
  local t="$1"
  case "$t" in
    *ed) return 0 ;;
    wrote|ran|sent|built|made|took|set|met|put|held|got|gave|left|told|brought|caught|found|kept|spent|dealt|began|drew|read|split|cut|shut|hit|let|won|lost|paid|said|saw|went|came|did|had|was|were) return 0 ;;
  esac
  case "$t" in
    re?*|un?*|over?*|under?*|mis?*|out?*)
      local b="${t#re}"
      [[ "$b" == "$t" ]] && b="${t#un}"
      [[ "$b" == "$t" ]] && b="${t#over}"
      [[ "$b" == "$t" ]] && b="${t#under}"
      [[ "$b" == "$t" ]] && b="${t#mis}"
      [[ "$b" == "$t" ]] && b="${t#out}"
      case "$b" in
        wrote|ran|sent|built|made|took|set|met|put|held|got|gave|left|told|brought|caught|found|kept|spent|dealt|began|drew|read|split|cut|shut|hit|let|won|lost|paid|said|saw|went|came|did|had|was|were) return 0 ;;
      esac
    ;;
  esac
  return 1
}

# Does the OPENING clause of a padded, lowercased description carry completed work?
# Returns 0 when it does. Only the first five tokens count: "Retracting Finding 3 as I
# wrote it" has a past tense verb, but it sits in a subordinate clause and the sentence
# is still narration, while "Onboarding tasks were reassigned" carries its past tense up
# front. Shared by the gerund rule and the quantifier openers.
_desc_opens_past() {
  local tok p1="" p2="" p3="" seen=0
  for tok in $1; do
    seen=$((seen+1)); (( seen > 5 )) && break
    case "$tok" in
      *ed)
        # A PRESENT copula in front of the participle makes it a state, not work:
        # "Both programmes ARE connected" describes how things stand, while "Both
        # files WERE regenerated" is work that happened.
        #
        # The copula is not always the word immediately before. An adverb sits between
        # them constantly, and QA round 4 found that a single one defeated the check:
        # "Both changes are NOW merged", "Both PRs are ALREADY approved", "Testing is
        # ESSENTIALLY finished" all reached the invoice field. So look back three
        # tokens, not one. "have been regenerated" is deliberately NOT blocked: present
        # perfect passive reports work that was completed.
        case " is are am be being " in
          *" $p1 "*|*" $p2 "*|*" $p3 "*) p3="$p2"; p2="$p1"; p1="$tok"; continue ;;
        esac
        return 0 ;;
      *)
        _desc_past_token "$tok" && return 0 ;;
    esac
    p3="$p2"; p2="$p1"; p1="$tok"
  done
  return 1
}

# Does this text read as a reply, a report or a finding rather than a record of the work?
# Returns 0 when it must NOT reach the invoice field.
#
# Rewritten 2026-08-28 after QA failed it. The first version only inspected the FIRST
# word, so the defect kept landing in other shapes: proper-noun and numeral subjects,
# "there is" mid sentence, gerund narration, a lowercase verdict, and commit hashes. Of
# 12 real entries recorded in the hour after it shipped, it refused none and 6 were still
# defective. Every rule below is matched against real examples from that record.
#
# No subprocesses. Everything is bash string work.
_desc_refuse() {
  local s="$1" l w p
  l="${s,,}"
  # Punctuation to spaces, padded, so a plain substring test gives word boundaries.
  p=" ${l//[^a-z0-9]/ } "
  p="${p//  / }"; p="${p//  / }"; p="${p//  / }"

  # Second person. The field is read by a customer, not by the person being replied to.
  case "$p" in *" you "*|*" your "*|*" yours "*|*" youre "*) return 0 ;; esac
  # Contracted forms survive the punctuation strip as two tokens, so match them on the
  # normalised text instead.
  case "$l" in *"y'all"*|*"ya'll"*|*" yall "*|"yall "*) return 0 ;; esac

  # First-person analysis and retraction, which narrates thinking rather than work.
  case "$p" in
    " i "*|*" i had "*|*" i have not "*|*" i cannot "*|*" i could not "*|*" i was wrong "*|*" i am not "*|*" i do not "*) return 0 ;;
  esac

  w="${l%% *}"; w="${w//[^a-z0-9]/}"
  # A condition or a state, not an action.
  case " the it that this there these those nothing here " in
    *" $w "*) return 0 ;;
  esac
  # "all" and "both" are quantifiers, and in front of completed work they open an
  # ordinary record: "Both files were regenerated and checked". They only signal a
  # state when nothing in the opening clause is past tense, which is the same
  # discriminator the gerund rule below already uses. QA round 3 found the blanket
  # form throwing real entries away.
  case " all both " in
    *" $w "*) _desc_opens_past "$p" || return 0 ;;
  esac
  # A verdict opening the sentence. The rule further down catches a verdict sitting
  # after a comma or a colon, but one that OPENS the sentence has neither in front of
  # it, so "approved, no blocking concerns" reached the invoice while "Security review
  # complete, approved, ..." was refused. The upper case form was refused too, so the
  # test case passed while the class it stands for did not.
  #
  # A verdict word is also an ordinary transitive verb. "Passed the release gate
  # through stakeholder QA and handed it off" is a real entry from the record and must
  # survive. The discriminator is whether the word takes an object: a comma straight
  # after it, or a preposition where a noun phrase would go, means it does not.
  case " approved blocked passed failed rejected denied " in
    *" $w "*)
      case "$l" in "$w,"*|"$w."*|"$w;"*|"$w:"*) return 0 ;; esac
      local second="${p#" $w "}"; second="${second%% *}"
      # A preposition where a noun phrase would go means the verdict takes no object.
      # QA round 4 found the original short list let "approved by the client",
      # "approved over email" and "blocked in review" through.
      case " with without on at for pending against by over during in into after before since under about " in
        *" $second "*) return 0 ;;
      esac
    ;;
  esac
  # State and finding openers. Each one announces a condition or an opinion rather
  # than work that was done. Measured against 1151 real descriptions covering 25 days,
  # not one opens with any of them, so this costs nothing. Before this, the screen
  # refused "Everything downstream waits on a db owner" while accepting "Still waiting
  # on the db owner", which made the rule arbitrary rather than principled: QA round 3
  # ruled that the refusals were right and the equivalents had to follow.
  case " still currently not no looks seems appears waiting pending awaiting unable ready my " in
    *" $w "*) return 0 ;;
  esac
  # A present tense copula in the opening clause, with nothing completed in front of
  # it, is a state report whatever the subject is: "Status is now resolved", "Coverage
  # is largely adequate", "Being now fully resolved, ...". This is general rather than
  # another opener on a denylist, and QA round 5 is why. The round 4 copula guard was
  # only ever REACHED from two gates, a "both"/"all" opener or an "-ing" opener, so any
  # other subject skipped it, and "being" satisfies the -ing gate itself so a fourth
  # adverb walked past the three token lookback. It also closes the noun-subject gap
  # that had been disclosed and accepted since round 1.
  #
  # Scanned forward: a past tense verb reached first means the sentence is a record of
  # work and the copula is only reporting what was found, so "Determined that the key
  # audit is blocked" survives. "to be responsive" survives because "be" is not in the
  # set and "Rebuilt" comes first anyway. Measured across 1151 real descriptions this
  # refuses 8 more, and every one of them is either a finding or real work written in
  # the present passive rather than the past tense the house rules ask for.
  local ctok cseen=0
  for ctok in $p; do
    cseen=$((cseen+1)); (( cseen > 5 )) && break
    case " is are am being " in
      *" $ctok "*) return 0 ;;
    esac
    _desc_past_token "$ctok" && break
  done
  # A numeral subject: "412 is closed as not reproducible".
  case "$w" in ''|*[!0-9]*) ;; *) return 0 ;; esac
  # A count opening the sentence, but only before a lowercase word, so a proper noun
  # such as "One Horse product import verified" is not refused.
  case " one two three four five six seven eight nine ten " in
    *" $w "*)
      local rest="${s#* }"
      # "One of my entries was ..." is a partitive, not a count opening a report. But
      # the skip was written as "anything after of", which also swallowed the genuine
      # count report "Two of three closed out cleanly" that this ticket claimed to
      # catch. A partitive names things; a count report names another number.
      case "$rest" in
        "of "*|"Of "*)
          local after="${rest#* }"; after="${after%% *}"; after="${after//[^a-zA-Z0-9]/}"
          after="${after,,}"
          case " one two three four five six seven eight nine ten " in
            *" $after "*) return 0 ;;
          esac
          case "$after" in ''|*[!0-9]*) ;; *) return 0 ;; esac
          ;;
        [a-z]*) return 0 ;;
      esac
    ;;
  esac
  # Gerund narration: "Retracting Finding 3...", "Correcting the report...". A completed
  # record says "Retracted" or "Corrected".
  #
  # But plenty of ordinary work opens with an -ing NOUN: "Onboarding tasks were
  # reassigned", "Billing report exported and reconciled". The discriminator is whether
  # the sentence reports completed work at all, so only refuse when nothing in it is
  # past tense. Every example here came out of the real record.
  case "$w" in
    *ing)
      # Only the opening clause counts. "Retracting Finding 3 as I wrote it" has a past
      # tense verb, but it sits in a subordinate clause and the sentence is still
      # narration. "Onboarding tasks were reassigned" carries its past tense up front.
      _desc_opens_past "$p" || return 0
    ;;
  esac

  # A condition stated as the point of the sentence, which means at its start or straight
  # after a colon. NOT as the object of completed work: "confirmed there is no guard for
  # orders that already shipped" is a proper record and must survive.
  case "$l" in
    "there is"*|"there are"*|"there was"*|"there were"*) return 0 ;;
    *": there is"*|*": there are"*|*": there was"*|*": there were"*) return 0 ;;
  esac

  # A verdict lifted out of a review. Matched in its report shape rather than as a bare
  # word, so "deployed it after the full suite passed" is still allowed.
  case "$l" in
    *": approved"*|*", approved,"*|*", approved."*|*": blocked"*|*", blocked,"*|*", blocked."*) return 0 ;;
  esac
  # Shouted verdicts, as whole tokens. A substring test would also fire on BYPASS and
  # COMPASS, and on PASSED inside ordinary prose.
  local u=" ${s//[^A-Za-z0-9]/ } "
  u="${u//  / }"; u="${u//  / }"; u="${u//  / }"
  case "$u" in *" APPROVED "*|*" BLOCKED "*|*" PASS "*|*" FAIL "*|*" PASSED "*|*" FAILED "*) return 0 ;; esac

  # Internal identifiers: draft ids, and commit hashes such as "committed as 55793a7".
  local t
  for t in $p; do
    case "$t" in
      r[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) return 0 ;;
    esac
    if [[ ${#t} -ge 7 && ${#t} -le 40 && "$t" != *[!0-9a-f]* && "$t" == *[a-f]* && "$t" == *[0-9]* ]]; then
      return 0
    fi
  done

  # Parity with the derived path: a file path or a reference to the tooling must never
  # reach the field from either route. QA found these applied only to the derived text.
  case "$l" in
    *".ps1"*|*".sh"*|*".js"*|*".md"*|*".sql"*|*".json"*|*".html"*|*".jsonl"*|*".yaml"*|*".yml"*|*".py"*|*".csv"*|*".txt"*|*".bat"*|*".cmd"*|*".php"*|*".xlsx"*) return 0 ;;
    # Any backslash at all. Measured across 550 real descriptions from ten days: not one
    # contains a backslash, so this costs nothing and catches every Windows and UNC path
    # shape without trying to enumerate them.
    *\\*) return 0 ;;
    */[a-z0-9_.-]*/[a-z0-9_.-]*) return 0 ;;
  esac
  case "$p" in *" claude "*|*" anthropic "*|*" ai "*|*" assistant "*|*" chatbot "*|*" copilot "*|*" agent "*|*" subagent "*) return 0 ;; esac

  return 1
}

# Clean one candidate sentence, or fail. Shared by both sources below.
_clean_candidate() {
  local s
  s="$(printf '%s' "$1" \
       | sed -e 's/[*`#|_>]/ /g' \
             -e 's/\[\([^]]*\)\]([^)]*)/\1/g' \
             -e 's/^[[:space:]]*[Tt]imestamp:[[:space:]]*//' \
             -e 's/^[[:space:]]*[0-9-]\{10\}[[:space:]][0-9:]\{5,8\}[[:space:]]*UTC[[:space:]-]*//' \
             -e 's/^[[:space:]]*[-—–][[:space:]]*//' \
             -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
  s="${s%%. *}"; s="${s%.}"
  (( ${#s} < APROPOS_DERIVE_MIN )) && return 1
  # Acknowledgements, not work. "Noted, that reads well and the ask is clear" passes a
  # length floor but describes nothing that happened.
  printf '%s' "$s" | grep -Eqi '^(noted|sent|done|yes|no|correct|agreed|thanks|thank you|ok|okay|right|sure|understood|good|fair|exactly|indeed|got it|perfect)([^[:alnum:]]|$)' && return 1
  # The rules ban file paths and script names from an invoice-facing field.
  printf '%s' "$s" | grep -Eq '[A-Za-z]:\\|\\\\|/[A-Za-z0-9_.-]+/|\.(ps1|sh|js|md|php|sql|json|html|txt|csv|xlsx|jsonl|cmd|bat|py)\b' && return 1
  printf '%s' "$s" | grep -Eqi "$APROPOS_BANNED" && return 1
  # The same voice screen the model-written description gets, so neither route bypasses
  # it. The derived text is the worse offender: it is lifted from a reply.
  s="$(_desc_normalise "$s")"
  _desc_refuse "$s" && return 1
  (( ${#s} > DESC_MAX )) && { s="${s:0:$DESC_MAX}"; s="${s% *}"; }
  # Sentence case, since a lifted fragment often starts mid-thought.
  printf '%s.' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')${s:1}"
}

# Last resort before the placeholder: describe the turn from what the response
# actually said. The final assistant text block IS this turn's answer, because Stop
# only fires once the response is complete.
#
# Two sources, best first: the labelled summary that ends a long reply, then the
# reply's opening sentence. Measured across 12 real sessions, the summary is present
# about 60% of the time and is usually a statement of what was done; the opening
# sentence is the better of the rest. Anything failing the floor or the content rules
# falls through to the placeholder, which is the honest outcome.
#
# Added 2026-08-12. The plugin README has claimed this behaviour since 0.2.0 but no
# code implemented it, so every turn where the model forgot to write a description
# booked "[needs description] <project>". On one team machine the working directory
# is named "Claude", so that put a literal AI reference on an invoice-facing field.
desc_from_transcript() {
  local f raw out
  command -v jq >/dev/null 2>&1 || return 1
  f="$(transcript_path "$SID" "$1")" || return 1

  # One line per text block, newest last. gsub collapses the block so tail -1 gets a
  # whole block rather than its last physical line.
  raw="$(tail -n 800 "$f" 2>/dev/null \
        | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text | gsub("\\s+"; " ")' 2>/dev/null \
        | awk 'NF' | tail -n 1)"
  [[ -n "$raw" ]] || return 1

  case "$raw" in
    *"Summary:"*) out="$(_clean_candidate "${raw##*Summary:}")" && { printf '%s' "$out"; return 0; } ;;
  esac
  out="$(_clean_candidate "$raw")" && { printf '%s' "$out"; return 0; }
  return 1
}

# THE SELF-REPAIR PASS.
#
# A flagged entry has no id: fl_record keeps its start time, its session and its cwd
# (lib/ledger.sh), because that is all record_turn still has when it writes the flag. To
# repair one later, point desc_from_transcript at that row's own session and cwd rather
# than the current turn's, and amend the row by start time instead of by id.
#
# _flag_text_for_cwd <ph> <cwd> - reconstructs the exact text record_turn would have
# written for this folder, so the repair pass has something to pass as -ExpectDescription
# without the ledger having to carry a copy of the row's current description. Mirrors
# record_turn's own derivation exactly: the folder name appended, unless it names the
# tooling or the result would run past the cap, in which case the bare flag stands alone.
_flag_text_for_cwd() {
  local ph="$1" cwd="$2" proj desc
  proj="$(basename "$cwd" 2>/dev/null)"
  if printf '%s' "$proj" | grep -Eqi "$APROPOS_BANNED"; then proj=""; fi
  if [[ -n "$proj" && "$proj" != "." && "$proj" != "/" ]]; then
    desc="$ph $proj"
    (( ${#desc} > DESC_MAX )) && desc="$ph"
  else
    desc="$ph"
  fi
  printf '%s' "$desc"
}

# repair_pending [session_filter] - walk the ledger and try to turn a flagged entry's
# placeholder into a real description, now that its transcript may hold more than it did
# when the flag was written. Called once a turn for the running session, so a later turn
# can repair this SAME session's earlier flags, and once a day for the whole ledger, so a
# session that has already ended still gets cleaned up (see sweep_due below). With no
# filter, every row is tried; with one, only that session's rows are.
#
# Never invents an attribution: this only ever rewrites a description. A candidate that
# is empty or is itself a flag is left alone rather than written over a flag, and the row
# stays pending. Nothing here may cost the turn or the session, so every caller swallows
# this function's failures; nothing inside it is allowed to propagate either.
repair_pending() {
  local _rp_filter="${1:-}"
  local _rp_start _rp_sess _rp_cwd _rp_epoch _rp_rc
  local -a _rp_clear=()
  while IFS=$'\t' read -r _rp_start _rp_sess _rp_cwd _rp_epoch; do
    [[ -n "$_rp_start" ]] || continue
    [[ -n "$_rp_filter" && "$_rp_sess" != "$_rp_filter" ]] && continue

    # Nothing usable yet, or the transcript still only yields another flag: leave the row
    # for the next pass rather than writing a flag over a flag.
    _repair_candidate "$_rp_sess" "$_rp_cwd"
    [[ -n "$RC_CAND" ]] || continue

    # 0 amended, 2 the row holds neither flag: a person already corrected it, so it is no
    # longer ours to repair and is cleared rather than retried forever. Any other outcome
    # (no such row yet, more than one match, the database unreachable) leaves it pending.
    _repair_amend "$_rp_start" "$_rp_cwd" "$RC_CAND"; _rp_rc=$?
    [[ "$_rp_rc" == "0" || "$_rp_rc" == "2" ]] && _rp_clear+=("$_rp_start")
  done < <(fl_pending)
  fl_clear_many "${_rp_clear[@]}"
  return 0
}

# _repair_candidate <session> <cwd> - sets RC_CAND to the description the session's
# transcript yields for a row of that session and folder, or to nothing when it yields
# nothing usable or only another flag.
#
# Read once per session and folder per run, however many rows share them. The
# 0.2.9 pass read the whole transcript tail again for every row, and with 30 rows over
# transcripts of 1 to 5 MB that one step took nearly all of a 17 second pass, inside a
# start-up budget of about 20. What is derived depends only on the session and folder, so
# reading once gives every row exactly what it got before, at a fraction of the cost.
#
# desc_from_transcript reads the GLOBAL $SID, not an argument, because it derives the
# transcript path from the session id it was written for. Point it at the row's session
# for the call, then restore the caller's own so nothing else in the turn is disturbed.
# Kept in two plain arrays because bash 3.2 (macOS) has no associative arrays.
_RC_KEYS=(); _RC_VALS=()
_repair_candidate() {
  local _rc_k="$1|$2" _rc_i _rc_saved="$SID"
  for (( _rc_i = 0; _rc_i < ${#_RC_KEYS[@]}; _rc_i++ )); do
    if [[ "${_RC_KEYS[$_rc_i]}" == "$_rc_k" ]]; then RC_CAND="${_RC_VALS[$_rc_i]}"; return 0; fi
  done
  SID="$1"
  RC_CAND="$(desc_from_transcript "$2" 2>/dev/null)"
  SID="$_rc_saved"
  [[ -n "${RC_CAND//[[:space:]]/}" ]] || RC_CAND=""
  _desc_is_placeholder "$RC_CAND" && RC_CAND=""
  _RC_KEYS+=("$_rc_k"); _RC_VALS+=("$RC_CAND")
  return 0
}

# _repair_amend <start> <cwd> <candidate> - amend one flagged row by start time.
# Returns 0 amended, 2 the row holds neither flag (already corrected, nothing sent),
# 3 there is no such row (lib/writer.sh amend_by_start), anything else otherwise.
#
# Which flag the row carries is not recorded, so both are tried, and the amend script's
# own guard tells a wrong guess apart from a corrected row: it refuses with 2, and writes
# nothing, whenever the row does not hold exactly what was offered as expected. That same
# guard is why a row is never repaired twice: once amended it no longer holds a flag.
#
# Inside the daily pass, SW_LAST_START is the last value of $SECONDS at which a correction may
# still be started. When the first guess is refused after that, the second is not sent, and
# this returns 4: nothing was written, and the pass sends only the second guess next time.
# Outside the pass it is unset and both guesses are always tried, as before.
_repair_amend() {
  local _ra_rc
  _flag_text_cached "$DESC_PH_NONE" "$2"
  amend_by_start "$1" "$PERSON" "$3" "$FT_VAL"; _ra_rc=$?
  [[ "$_ra_rc" == "2" ]] || return "$_ra_rc"
  [[ -n "${SW_LAST_START:-}" ]] && (( SECONDS > SW_LAST_START )) && return 4
  _repair_amend_second "$1" "$2" "$3"
}

# _repair_amend_second <start> <cwd> <candidate> - the second guess alone: the row holds the
# rejected-wording flag.
_repair_amend_second() {
  _flag_text_cached "$DESC_PH_REJECTED" "$2"
  amend_by_start "$1" "$PERSON" "$3" "$FT_VAL"
}

# _flag_text_cached <flag> <cwd> - sets FT_VAL to _flag_text_for_cwd's answer, worked out once
# per flag and folder: it costs several subprocesses, and many rows share a folder.
_FT_KEYS=(); _FT_VALS=()
_flag_text_cached() {
  local _ft_k="$1|$2" _ft_i
  for (( _ft_i = 0; _ft_i < ${#_FT_KEYS[@]}; _ft_i++ )); do
    if [[ "${_FT_KEYS[$_ft_i]}" == "$_ft_k" ]]; then FT_VAL="${_FT_VALS[$_ft_i]}"; return 0; fi
  done
  FT_VAL="$(_flag_text_for_cwd "$1" "$2")"
  _FT_KEYS+=("$_ft_k"); _FT_VALS+=("$FT_VAL")
  return 0
}

# Once-a-machine-per-day guard for the whole-ledger sweep: sweep_due and sweep_mark, with
# the stamp file, the resume list, the pass log and the lock, live in lib/ledger.sh, because
# session start reads the same stamp to report a due pass it had no time to start.

# How long a pending row is worth retrying. Past this, nothing left in the transcript is
# going to change, and the row would otherwise sit in the ledger forever, retried on
# every turn and every day's sweep for no gain.
APROPOS_SWEEP_DAYS="${APROPOS_SWEEP_DAYS:-7}"

# sweep_prune - drop rows past the window, in one rewrite. Sets SW_PRUNED to the count.
sweep_prune() {
  local _sp_cutoff; _sp_cutoff=$(( $(date -u +%s) - APROPOS_SWEEP_DAYS * 86400 ))
  local _sp_start _sp_sess _sp_cwd _sp_epoch
  local -a _sp_drop=()
  while IFS=$'\t' read -r _sp_start _sp_sess _sp_cwd _sp_epoch; do
    [[ -n "$_sp_start" ]] || continue
    [[ "$_sp_epoch" =~ ^[0-9]+$ ]] || continue
    (( _sp_epoch < _sp_cutoff )) && _sp_drop+=("$_sp_start")
  done < <(fl_pending)
  SW_PRUNED=${#_sp_drop[@]}
  fl_clear_many "${_sp_drop[@]}"
  return 0
}

# THE DAILY PASS.
#
# In 0.2.9 the pass never finished on the machine it was meant to help: last-sweep stayed
# at the day before the release through many session starts. Measured without writing
# anything, it took 17 seconds against a start-up budget of about 20, nearly all of it
# re-reading a large transcript once per row; it marked itself done only at the very end,
# so a pass cut off by the hook's time limit started again from the oldest row next time;
# and rows already corrected by hand, or no longer in Apropos, were never removed, so every
# pass paid for them again. Of the 30 rows it held, 24 were one or the other.
#
# So the pass now:
#   - reads each session's transcript once (_repair_candidate), not once per row;
#   - records each row as revisited the moment it is settled, or just before its correction
#     is sent (sweep_visit), so a pass that is cut off, even in the middle of a slow
#     correction, carries on at the next row at the next session start, and a row is never
#     sent twice in a day;
#   - does not start a row's second flag guess once too little time is left, and sends only
#     that guess next time;
#   - works in two phases, the cheap one first: every row is looked at and the ones with
#     nothing to send are settled, then corrections are sent while enough time is left;
#   - stops at APROPOS_SWEEP_DEADLINE, which session start sets inside its own hard limit,
#     and starts a correction only with APROPOS_SWEEP_AMEND_SECS of it still left;
#   - is done for the day once every row has been revisited, repaired or not;
#   - removes a row whose Apropos entry no longer holds the flag, a row whose entry is gone,
#     and a row whose session can never give it a description;
#   - runs one pass at a time on a machine, and writes one log line as it starts and one as
#     it ends, with counts only.
#
# A row counts as unrecoverable when its session's transcript is missing, or yields nothing
# usable and has not changed for APROPOS_SWEEP_IDLE_SECS: that session has ended, and the
# same transcript will give the same nothing tomorrow. A live session keeps its rows; its own
# turns retry them (repair_pending "$SID" in record_turn), and so does tomorrow's pass.
#
# A row counts as gone when the amend script finds no entry at its start time, the entry is
# not still waiting in this machine's queue, and the flag is older than
# APROPOS_SWEEP_GONE_SECS, so an entry that simply has not been delivered yet is never mistaken
# for one that was deleted.
APROPOS_SWEEP_IDLE_SECS="${APROPOS_SWEEP_IDLE_SECS:-43200}"
APROPOS_SWEEP_GONE_SECS="${APROPOS_SWEEP_GONE_SECS:-3600}"
# One real write was measured at 12 to 20 seconds. An amend that is cut off costs nothing:
# either it had not written, or it had, and the next attempt is refused because the row no
# longer holds the flag, which removes it. Its row is recorded as revisited before the amend
# is sent, so the next start moves on to the next row rather than spending itself on the same
# one. So this only avoids starting work that cannot finish, and can be shorter than a write.
APROPOS_SWEEP_AMEND_SECS="${APROPOS_SWEEP_AMEND_SECS:-10}"
[[ "$APROPOS_SWEEP_IDLE_SECS" =~ ^[0-9]+$ ]] || APROPOS_SWEEP_IDLE_SECS=43200
[[ "$APROPOS_SWEEP_GONE_SECS" =~ ^[0-9]+$ ]] || APROPOS_SWEEP_GONE_SECS=3600
[[ "$APROPOS_SWEEP_AMEND_SECS" =~ ^[0-9]+$ ]] || APROPOS_SWEEP_AMEND_SECS=10

# _sweep_unrecoverable <session> <cwd> - true when the row's transcript is missing or idle.
# Answered once per session and folder, like the candidate.
#
# "Idle" counts only where jq is present. Without it desc_from_transcript cannot read a
# transcript at all, so an empty candidate says nothing about what the transcript holds, and
# the row is kept for a computer, or a day, that can judge it. A missing transcript needs no
# jq to judge: nothing will ever repair that row.
_SU_KEYS=(); _SU_VALS=()
_sweep_unrecoverable() {
  local _su_k="$1|$2" _su_i _su_f _su_mins _su_v=1
  for (( _su_i = 0; _su_i < ${#_SU_KEYS[@]}; _su_i++ )); do
    [[ "${_SU_KEYS[$_su_i]}" == "$_su_k" ]] && return "${_SU_VALS[$_su_i]}"
  done
  if ! _su_f="$(transcript_path "$1" "$2")"; then
    _su_v=0
  elif command -v jq >/dev/null 2>&1; then
    _su_mins=$(( APROPOS_SWEEP_IDLE_SECS / 60 ))
    [[ -n "$(find "$_su_f" -maxdepth 0 -mmin +"$_su_mins" 2>/dev/null)" ]] && _su_v=0
  fi
  _SU_KEYS+=("$_su_k"); _SU_VALS+=("$_su_v")
  return "$_su_v"
}

# _sweep_queued <start> - true when an entry with this start time is still in the queue, or in
# the side file an earlier version kept undelivered lines in, which the next flush folds back
# into the queue (lib/queue.sh). Until then an entry there is just as undelivered.
_sweep_queued() {
  local _sq_f
  for _sq_f in "$QUEUE" "$QUEUE.retry"; do
    [[ -s "$_sq_f" ]] || continue
    awk -F'\t' -v s="$1" '$6 == s { found = 1; exit } END { exit !found }' "$_sq_f" 2>/dev/null && return 0
  done
  return 1
}

sweep_run() {
  sweep_due || return 0
  if [[ -z "$PERSON" ]]; then sweep_log "end result=no-person"; return 0; fi
  if ! sweep_lock; then sweep_log "end result=busy"; return 0; fi
  # Another start may have finished the day's pass between the check above and the lock.
  sweep_due || { sweep_unlock; return 0; }
  # Rows settled in phase 2 are removed from the ledger in one rewrite at the end, or here if
  # the pass is killed first. A kill that beats even this loses nothing: each row is already
  # on today's revisited list, and tomorrow's attempt is refused because it no longer holds a
  # flag, which removes it then.
  local -a _sw_clear=()
  trap 'fl_clear_many "${_sw_clear[@]}"; sweep_log "end result=killed"; sweep_unlock; exit 143' TERM INT

  # Clock kept with bash's own counter, so checking it costs no subprocess per row.
  local _sw_t0=$SECONDS _sw_e0 _sw_deadline="${APROPOS_SWEEP_DEADLINE:-}"
  _sw_e0="$(date -u +%s)"
  [[ "$_sw_deadline" =~ ^[0-9]+$ ]] || _sw_deadline=""
  SW_TODAY="$(_sw_today)"
  sweep_log "start deadline_in=${_sw_deadline:+$(( _sw_deadline - _sw_e0 ))s}"

  SW_PRUNED=0
  sweep_prune
  sweep_visited_load

  local _sw_rows=0 _sw_earlier=0 _sw_done=0 _sw_repaired=0 _sw_removed=0 _sw_kept=0 _sw_waiting=0
  local _sw_start _sw_sess _sw_cwd _sw_epoch _sw_now _sw_i _sw_rc _sw_stopped=0 _sw_mode _sw_n
  # Rows with a correction to send: start, folder, candidate, flag epoch, and how to send it
  # (0 both guesses, 1 the second guess only, 2 a retry of a correction an earlier pass was
  # cut off in the middle of, 3 the same retry of a row that was being sent the second guess
  # only, which stays the second guess only). Retries are held in their own list and sent last.
  local -a _sw_retire=() _sw_cs=() _sw_cc=() _sw_ct=() _sw_ce=() _sw_cm=()
  local -a _sw_rs=() _sw_rc2=() _sw_rt=() _sw_re=() _sw_rm=()

  # Phase 1: look at every row not yet revisited today. Rows with nothing to send are
  # settled here; rows with a correction to send are held for phase 2.
  while IFS=$'\t' read -r _sw_start _sw_sess _sw_cwd _sw_epoch; do
    [[ -n "$_sw_start" ]] || continue
    _sw_rows=$(( _sw_rows + 1 ))
    case "$SW_VISITED" in *$'\n'"$_sw_start"$'\n'*) _sw_earlier=$(( _sw_earlier + 1 )); continue ;; esac
    _sw_mode=0
    case "$SW_SECOND" in *$'\n'"$_sw_start"$'\n'*) _sw_mode=1 ;; esac
    case "$SW_TRIED" in *$'\n'"$_sw_start"$'\n'*) _sw_mode=$(( _sw_mode == 1 ? 3 : 2 )) ;; esac
    if [[ -n "$_sw_deadline" ]] && (( _sw_e0 + SECONDS - _sw_t0 >= _sw_deadline )); then
      _sw_stopped=1; _sw_waiting=$(( _sw_waiting + 1 )); continue
    fi
    _repair_candidate "$_sw_sess" "$_sw_cwd"
    if [[ -z "$RC_CAND" ]]; then
      if _sweep_unrecoverable "$_sw_sess" "$_sw_cwd"; then
        _sw_retire+=("$_sw_start"); _sw_removed=$(( _sw_removed + 1 ))
      else
        _sw_kept=$(( _sw_kept + 1 ))
      fi
      sweep_visit "$_sw_start"; _sw_done=$(( _sw_done + 1 ))
      continue
    fi
    if (( _sw_mode >= 2 )); then
      _sw_rs+=("$_sw_start"); _sw_rc2+=("$_sw_cwd"); _sw_rt+=("$RC_CAND"); _sw_re+=("$_sw_epoch"); _sw_rm+=("$_sw_mode")
    else
      _sw_cs+=("$_sw_start"); _sw_cc+=("$_sw_cwd"); _sw_ct+=("$RC_CAND"); _sw_ce+=("$_sw_epoch"); _sw_cm+=("$_sw_mode")
    fi
  done < <(fl_pending)
  fl_clear_many "${_sw_retire[@]}"
  for (( _sw_i = 0; _sw_i < ${#_sw_rs[@]}; _sw_i++ )); do
    _sw_cs+=("${_sw_rs[$_sw_i]}"); _sw_cc+=("${_sw_rc2[$_sw_i]}"); _sw_ct+=("${_sw_rt[$_sw_i]}"); _sw_ce+=("${_sw_re[$_sw_i]}"); _sw_cm+=("${_sw_rm[$_sw_i]}")
  done
  local _sw_scan=$(( SECONDS - _sw_t0 ))

  # Phase 2: send the corrections, oldest first and retries last, while there is time to
  # finish one. SW_LAST_START is the last $SECONDS at which a correction, or a row's second
  # flag guess (_repair_amend), may still be started: APROPOS_SWEEP_AMEND_SECS before the
  # deadline. Each row is recorded before its correction is sent (sweep_visit explains why).
  local SW_LAST_START=""
  [[ -n "$_sw_deadline" ]] && SW_LAST_START=$(( _sw_t0 + _sw_deadline - _sw_e0 - APROPOS_SWEEP_AMEND_SECS ))
  _sw_n=${#_sw_cs[@]}
  for (( _sw_i = 0; _sw_i < _sw_n; _sw_i++ )); do
    if [[ -n "$SW_LAST_START" ]] && (( SECONDS > SW_LAST_START )); then
      _sw_stopped=1; _sw_waiting=$(( _sw_waiting + _sw_n - _sw_i )); break
    fi
    _sw_start="${_sw_cs[$_sw_i]}"; _sw_mode="${_sw_cm[$_sw_i]}"
    case "$_sw_mode" in
      0) sweep_visit "$_sw_start" tried ;;
      1) sweep_visit "$_sw_start" tried-second ;;
      *) sweep_visit "$_sw_start" ;;
    esac
    if (( _sw_mode == 1 || _sw_mode == 3 )); then
      _repair_amend_second "$_sw_start" "${_sw_cc[$_sw_i]}" "${_sw_ct[$_sw_i]}"; _sw_rc=$?
    else
      _repair_amend "$_sw_start" "${_sw_cc[$_sw_i]}" "${_sw_ct[$_sw_i]}"; _sw_rc=$?
    fi
    (( _sw_mode >= 2 )) || [[ "$_sw_rc" == "4" ]] || sweep_visit "$_sw_start"
    case "$_sw_rc" in
      4)
        # The first guess was refused and there is no time for the second: nothing was
        # written. The next pass sends this row the second guess only; a retry is already
        # recorded as done for today, and waits for tomorrow.
        if (( _sw_mode >= 2 )); then
          _sw_kept=$(( _sw_kept + 1 )); _sw_done=$(( _sw_done + 1 ))
          (( _sw_i + 1 < _sw_n )) && _sw_stopped=1
          _sw_waiting=$(( _sw_waiting + _sw_n - _sw_i - 1 ))
        else
          sweep_visit "$_sw_start" second
          _sw_stopped=1; _sw_waiting=$(( _sw_waiting + _sw_n - _sw_i ))
        fi
        break
        ;;
      0) _sw_clear+=("$_sw_start"); _sw_repaired=$(( _sw_repaired + 1 )) ;;
      2)
        # Refused: the entry no longer holds a flag. On a retry that is the cut-off
        # correction having landed, so it counts as repaired; otherwise the entry was
        # corrected some other way, and simply leaves the list.
        _sw_clear+=("$_sw_start")
        if (( _sw_mode >= 2 )); then _sw_repaired=$(( _sw_repaired + 1 )); else _sw_removed=$(( _sw_removed + 1 )); fi
        ;;
      3)
        _sw_now=$(( _sw_e0 + SECONDS - _sw_t0 ))
        if [[ "${_sw_ce[$_sw_i]}" =~ ^[0-9]+$ ]] && (( _sw_now - ${_sw_ce[$_sw_i]} > APROPOS_SWEEP_GONE_SECS )) && ! _sweep_queued "$_sw_start"; then
          _sw_clear+=("$_sw_start"); _sw_removed=$(( _sw_removed + 1 ))
        else
          _sw_kept=$(( _sw_kept + 1 ))
        fi
        ;;
      *) _sw_kept=$(( _sw_kept + 1 )) ;;
    esac
    _sw_done=$(( _sw_done + 1 ))
  done
  fl_clear_many "${_sw_clear[@]}"; _sw_clear=()

  local _sw_result=deadline
  if (( ! _sw_stopped && _sw_waiting == 0 )); then
    sweep_mark; sweep_visited_reset; _sw_result=complete
  fi
  sweep_log "end result=$_sw_result entries=$_sw_rows revisited=$_sw_done earlier=$_sw_earlier repaired=$_sw_repaired removed=$_sw_removed kept=$_sw_kept remaining=$_sw_waiting aged_out=$SW_PRUNED scan_secs=$_sw_scan secs=$(( SECONDS - _sw_t0 ))"
  sweep_log_trim
  trap - TERM INT
  sweep_unlock
  return 0
}

# task_wt_lookup <task> -> prints the worktype last recorded against that task.
task_wt_lookup() {
  local t="$1" k v
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" != "0" ]] || return 1
  [[ -s "$taskwtf" ]] || return 1
  while IFS=$'	' read -r k v; do
    if [[ "$k" == "$t" ]]; then printf '%s' "$v"; return 0; fi
  done < "$taskwtf"
  return 1
}

# task_wt_record <task> <worktype> — remember the worktype for this task. Shared across
# every session on the machine, so it is a read-modify-write and takes the lock. Failing
# to get it means the next session may fall back to the default, which is untidy, where
# clobbering the file would lose every task's worktype at once.
task_wt_record() {
  local t="$1" w="$2" tmp k v
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" != "0" ]] || return 0
  [[ "$w" =~ ^[0-9]+$ ]] || return 0
  mkdir -p "$(dirname "$taskwtf")" 2>/dev/null || true
  # Retry rather than give up on the first miss. QA measured the single-attempt version
  # keeping only 2 or 3 of 20 concurrent writes, which silently defeats the whole point
  # of the map: the next session finds nothing and falls back to Engineering. _oe_lock is
  # the same bounded retry the open-entry map already uses, added after this identical
  # failure mode lost real data. Reusing it rather than repeating the mistake.
  _tw_lock "$taskwtf" || return 0
  tmp="$taskwtf.tmp.$$"
  {
    if [[ -s "$taskwtf" ]]; then
      while IFS=$'	' read -r k v; do
        [[ "$k" == "$t" ]] && continue
        [[ "$k" =~ ^[0-9]+$ ]] && [[ "$v" =~ ^[0-9]+$ ]] || continue
        printf '%s	%s
' "$k" "$v"
      done < "$taskwtf"
    fi
    printf '%s	%s
' "$t" "$w"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$taskwtf" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  q_unlock "$taskwtf"
}

# Bounded retry around the shared task map, mirroring _oe_lock in lib/writer.sh. Kept
# local to this file because writer.sh's copy is bound to APROPOS_OPEN_FILE.
_tw_lock() {
  local f="$1" i=0
  command -v q_lock >/dev/null 2>&1 || return 1
  while (( i < 50 )); do
    q_lock "$f" && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

record_turn() {
  # $1 = start time as UTC "YYYY-MM-DD HH:MM:SS"
  local START="$1"

  # Description, best source first:
  #   1. the model-written file, which is the intended path
  #   2. the last assistant message from the transcript
  #   3. a flagged placeholder
  # Never the raw prompt, which describes the request rather than the work done.
  local DESC=""
  # Whether the screen threw away a description this turn. The recorder has always known
  # this at the moment of refusal and then discarded it before writing the entry, which
  # is the entire defect: the two causes of a flagged entry became indistinguishable in
  # the record. Carried to the placeholder rather than stored anywhere new.
  local REFUSED=0
  if [[ -s "$descf" ]]; then
    DESC="$(_desc_normalise "$(cat "$descf")")"
    # A supplied description is held to the same standard as a derived one. Refusing it
    # falls through to the transcript and then to the flagged placeholder, which is
    # visible and gets corrected, rather than shipping a reply onto an invoice.
    if _desc_refuse "$DESC"; then
      printf 'apropos: the description written this turn reads as a reply rather than a record of the work, so it was not used. Rewrite it in the past tense, from your own perspective, saying what was accomplished.\n' >&2
      DESC=""
      REFUSED=1
    fi
  fi
  local basecwd="$CWD"
  [[ -z "$basecwd" && -s "$cwdf" ]] && basecwd="$(cat "$cwdf")"
  # APROPOS_DERIVE=off keeps the old behaviour, for anyone who would rather see an
  # explicit placeholder to correct than an approximate description that reads as
  # finished. The derived text is a safety net; the model writing one is the fix.
  case "$(printf '%s' "${APROPOS_DERIVE:-on}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no) ;;
    *) [[ -z "${DESC//[[:space:]]/}" ]] && DESC="$(desc_from_transcript "$basecwd" 2>/dev/null)" ;;
  esac
  if [[ -z "${DESC//[[:space:]]/}" ]]; then
    # Which flag. A refused TRANSCRIPT is not a rejection: the transcript is a salvage
    # attempt, not a description the session wrote, so it stays the never-written cause.
    # Counting it against the screen would inflate the one number this exists to make
    # trustworthy. Only a description the session actually wrote can be rejected.
    local ph="$DESC_PH_NONE"
    (( REFUSED )) && ph="$DESC_PH_REJECTED"
    local proj; proj="$(basename "$basecwd" 2>/dev/null)"
    # Do not tag the placeholder with a project name that is itself an AI reference.
    # A working directory named "Claude" would otherwise write "[needs description] Claude"
    # onto a field that reaches client invoices.
    if printf '%s' "$proj" | grep -Eqi "$APROPOS_BANNED"; then proj=""; fi
    if [[ -n "$proj" && "$proj" != "." && "$proj" != "/" ]]; then
      DESC="$ph $proj"
      # A folder name long enough to push the flag past the cap would otherwise be cut
      # mid-word by the truncation below, leaving a ragged half-word on an invoice. The
      # flag is the part that matters, so the folder is what gives way.
      (( ${#DESC} > DESC_MAX )) && DESC="$ph"
    else
      DESC="$ph"
    fi
  fi
  DESC="${DESC:0:$DESC_MAX}"

  # Now that this turn's own description is settled, take the chance to revisit any flag
  # THIS session left behind earlier. Its transcript holds more now than it did when the
  # flag was written, so a candidate that did not exist then might exist now. Never
  # allowed to cost the turn: every failure inside is swallowed.
  # Needs the person, since every repair is scoped to one person's rows.
  [[ -n "$PERSON" ]] && { repair_pending "$SID" 2>/dev/null || true; }

  # Optional sticky task/project. Resolved BEFORE the worktype, because the worktype can
  # be inherited from the task.
  local TASK="0"; [[ -s "$taskf" ]] && TASK="$(tr -d '[:space:]#' < "$taskf")"; [[ "$TASK" =~ ^[0-9]+$ ]] || TASK="0"
  local PROJ="0"; [[ -s "$projf" ]] && PROJ="$(tr -d '[:space:]' < "$projf")"; [[ "$PROJ" =~ ^[0-9]+$ ]] || PROJ="0"

  # The folder answers when the session did not. A session that states its own task still
  # wins, so a marker never overrides a deliberate choice; it only fills a silence that
  # would otherwise have become somebody else's invoice.
  if [[ "$TASK" == "0" && -n "$_dir_task" ]]; then TASK="$_dir_task"; fi
  if [[ "$PROJ" == "0" && -n "$_dir_proj" ]]; then PROJ="$_dir_proj"; fi

  # ...and when nothing answers, say so. Until now this was the silent path: TASK stayed 0,
  # the writer applied the person's fallback task, and the first anyone knew was reading
  # the timesheet days later. Client work booked as internal overhead under-bills the
  # customer and misreports where the day went, so it is worth interrupting for.
  if [[ "$TASK" == "0" ]]; then
    printf 'apropos: no task was stated this turn and no .apropos-task marker was found in %s or above it, so this entry goes to your catch-all task. Correct it today, or put a .apropos-task file holding the task number at the top of that folder so the work attributes itself from now on.
' "${_optout_dir:-the working directory}" >&2
  fi

  # Worktype, best source first:
  #   1. the file the model wrote this turn
  #   2. the worktype last used on this task, by any session on this machine
  #   3. the worktype this session carried from an earlier turn
  #   4. the documented default, reported so it can be corrected the same day
  #
  # Originally this was step 1 or the default, and the file in step 1 is deleted at the
  # end of every turn, so only the first turn of a stretch was categorised as intended.
  # Everything after it booked as Engineering.
  local WT="" WTSRC="" v=""
  if [[ -s "$wtf" ]]; then
    v="$(tr -d '[:space:]' < "$wtf")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then WT="$v"; WTSRC="written this turn"; fi
  fi
  if [[ -z "$WT" ]]; then
    v="$(task_wt_lookup "$TASK" 2>/dev/null)"
    if [[ "$v" =~ ^[0-9]+$ ]]; then WT="$v"; WTSRC="last used on this task"; fi
  fi
  if [[ -z "$WT" ]] && [[ -s "$stickywtf" ]]; then
    v="$(tr -d '[:space:]' < "$stickywtf")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then WT="$v"; WTSRC="carried from this session"; fi
  fi
  if [[ -z "$WT" ]]; then
    WT="13"; WTSRC="default"
    printf 'apropos: no worktype was written this turn and none is on record for task %s, so this entry took the default worktype 13 (Engineering). Correct it if that is wrong.
' "$TASK" >&2
  fi
  printf '%s' "$WT" > "$stickywtf" 2>/dev/null || true
  # Only a chosen worktype is worth remembering for the task. Recording the bare default
  # would pin a guess into the shared map as though somebody had established it, and
  # every later session would then inherit the guess with no warning.
  # NOT recorded here. task_wt_record can now genuinely retry for the lock, and this runs
  # before the entry is queued, so at high contention a slow lock would gate the write
  # that actually reaches the invoice. QA measured a 38s worst case at 20 concurrent
  # sessions against a 30s hook timeout, which would drop the whole turn rather than
  # merely lose a worktype hint. The map is a convenience; the time is not. Recorded at
  # the end of record_turn instead, once the entry is safely queued.

  # Dedup key now includes the description fingerprint. Previously the key was
  # worktype|task|project only, so two consecutive turns of different work on the
  # same task deduped — and because the file deletion below used to run
  # unconditionally, the second turn's real description was DELETED rather than
  # merely left unmarked. The plugin spec (§5.1) says dedup is "de-duplicate only,
  # never a reason to record nothing"; keying on the description honours that.
  # ONE OPEN ENTRY PER ACTIVITY, shared across every session on this machine.
  #
  # Until 2026-08-13 this recorded a row per turn. Measured on one person: over three hundred
  # rows Monday to Thursday, 80 a day, of which 185 of 320 were under five minutes and 20 were zero
  # length. That cannot be reconciled with the 15-minute increment convention, and it
  # overran the timecard's own page load so the day stopped displaying partway down.
  #
  # The old duplicate check could not prevent it. Its key included a hash of the
  # description, and the description differs every turn, so the key never repeated and
  # the check never fired. The hash went in on 2026-08-07 to stop a second turn's
  # description being deleted; it fixed that and caused this.
  #
  # So the key is the ACTIVITY, task and worktype and project, with no description in
  # it. A turn continuing an activity that is already open amends that entry rather than
  # inserting beside it. One person may run six to eight sessions at once, so the open entries
  # are held in one shared file rather than per session state: otherwise two sessions on
  # two tasks alternate and nothing ever merges. Modelled on real days this takes
  # ~84 entries a day to ~27, the number of distinct activities actually worked.
  #
  # APROPOS_MERGE=off restores a row per turn.
  local ACT="$WT|$TASK|$PROJ"
  local MERGED=0
  # The open entry's id when this turn's flag was withheld rather than amended over it.
  local WITHHELD=""
  # Which turn this is, for every notice below. Stop records the turn just answered, but
  # UserPromptSubmit only reaches here to recover the previous turn, whose Stop never ran.
  local _held_turn="this turn"
  [[ "$EVENT" == "Stop" ]] || _held_turn="your previous turn"
  # A person not yet identified never amends. An amend is checked against the person's own
  # rows, and claiming the activity for an entry that cannot be written yet would only make
  # other sessions wait on it. The turn is queued as its own entry below.
  local MERGE_MODE="${APROPOS_MERGE:-on}"
  [[ -z "$PERSON" ]] && MERGE_MODE=off
  case "$(printf '%s' "$MERGE_MODE" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no) ;;
    *)
      # Markers and unattributed turns are never merged: a break is not a continuation of
      # work, and an entry with no task cannot be amended without dropping attribution.
      if [[ "$TASK" != "0" ]]; then
        local open id
        # No entry open yet for this activity? Claim it before inserting, so a second
        # session starting the same brand-new activity in the same window waits for this
        # one's id instead of inserting a second row for the same work. If the claim is
        # refused, somebody else got there first, so wait for their id and amend that.
        if ! oe_lookup "$ACT" >/dev/null 2>&1; then
          if ! oe_claim "$ACT"; then
            open="$(oe_await "$ACT" 2>/dev/null)" || open=""
          fi
        fi
        if [[ -n "$open" ]] || open="$(oe_lookup "$ACT")"; then
          id="${open%% *}"
          # A FLAG NEVER REPLACES THE OPEN ENTRY'S DESCRIPTION. This branch used to
          # send every turn's description as the amend, the flag included, so a turn that
          # wrote nothing usable replaced the one real record of the stretch with "we do not
          # know what this was". Seen 2026-09-26: an entry recorded with a real description was
          # amended to the bare flag a few minutes later by the next turn on the same work.
          #
          # So a flagged turn is absorbed into the open entry without an amend. That is exactly
          # what a successful amend does to the time: no new start marker, so the turn's time
          # stays on this same worktype, task and project until the next marker. Nothing that
          # decides attribution is skipped, only the description write. Deliberately untouched:
          # the open-entry map (so the merge cap still runs from when the entry opened, and a
          # run of flagged turns cannot stretch one description past it), the duplicate guard
          # (not written for any merged turn) and the flag ledger (there is no new row to
          # repair). Asked of the predicate, never a literal, so every flag wording is covered.
          # An entry that itself holds a flag is still replaced by a later real description,
          # because only this turn's description is tested here.
          if _desc_is_placeholder "$DESC"; then
            MERGED=1; WITHHELD="$id"
          else
            # Third field is what this recorder last wrote for that entry. Pass it back so
            # the writer can refuse the amend if the row has been corrected since. A refusal
            # leaves MERGED at 0, so the turn is recorded as its own entry rather than
            # overwriting somebody's correction or being lost.
            local expect_b64 expect=""
            expect_b64="$(printf '%s' "$open" | awk '{print $3}')"
            local amend_ok=1
            if [[ -n "$expect_b64" ]]; then
              # A corrupt field decodes to an empty string, and an empty expectation used to
              # mean "nothing to compare", so the amend went ahead unconditionally and could
              # discard a real correction: the very bug this guard exists to prevent, back
              # again for that one row. Exit status alone is not a reliable gate, since a
              # valid but unpadded value also returns 1, so require a clean round trip.
              # Anything else refuses the amend, which falls back to inserting.
              expect="$(printf '%s' "$expect_b64" | base64 -d 2>/dev/null)"
              if [[ "$(printf '%s' "$expect" | base64 | tr -d '\n')" != "$expect_b64" ]]; then
                amend_ok=0
                printf 'apropos: the open-entry record for this activity is unreadable, so the entry was recorded separately rather than risk overwriting a correction.\n' >&2
              fi
            fi
            if (( amend_ok )) && amend_entry "$id" "$PERSON" "$DESC" "$expect"; then
              MERGED=1
              # The row now holds this turn's description, so that is what the next amend must
              # expect. Left at the insert's text, every amend after the second was refused as
              # though a person had corrected the row, and the work split into extra entries.
              # Failing to record it costs at most one extra entry, never a correction.
              oe_update_desc "$ACT" "$id" "$(printf '%s' "$DESC" | base64 | tr -d '\n')" || true
            fi
          fi
        fi
      fi
      ;;
  esac

  # A withheld flag is still a turn nobody described, so it is counted and said, not hidden.
  # Until 0.2.10 it was visible as the flag on the entry itself; now the entry keeps its real
  # description, so the day's local tally and this turn's notice carry it instead. Local, like
  # the catch-all tally, and every failure is swallowed: the time is already safe.
  if [[ -n "$WITHHELD" ]]; then
    local _wh_file _wh_n=0 _wh_line _wh_count="" _wh_cause _wh_msg _wh_ok=0
    _wh_file="${HOME}/.claude/apropos-time/withheld-flags-$(date -u +%Y-%m-%d).tsv"
    {
      mkdir -p "${HOME}/.claude/apropos-time" 2>/dev/null &&
      printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%H:%M:%S)" "$WITHHELD" "$ACT" "$DESC" "${basecwd:-unknown}" >> "$_wh_file"
    } 2>/dev/null && _wh_ok=1
    # The count and the file are only mentioned when this turn's line reached the file. A
    # failed write once produced "0 turns today", naming a file that did not exist.
    if (( _wh_ok )) && [[ -f "$_wh_file" ]]; then
      while IFS= read -r _wh_line; do [[ -n "$_wh_line" ]] && _wh_n=$((_wh_n+1)); done < "$_wh_file" 2>/dev/null
      if (( _wh_n == 1 )); then _wh_count=" 1 turn today so far, listed in $_wh_file."
      elif (( _wh_n > 1 )); then _wh_count=" $_wh_n turns today so far, listed in $_wh_file."; fi
    fi
    # Say which of the two causes, in words the person uses: nothing written, or something
    # written that the screen turned down.
    case "$DESC" in
      "$DESC_PH_REJECTED"*) _wh_cause="the description written for $_held_turn was not accepted" ;;
      *)                    _wh_cause="no description was written for $_held_turn" ;;
    esac
    _wh_msg="Apropos: $_wh_cause, so the entry already open for this work kept its earlier description. The time stays on the same task. If $_held_turn was different work, update that entry's description.$_wh_count"
    notice_add "$_wh_msg"
    printf '%s\n' "$_wh_msg" >&2
  fi

  # The old same-everything guard still applies to the insert path, so a genuinely
  # identical turn inside 15 minutes does not open a second entry.
  local SEG="$WT|$TASK|$PROJ|$(_hash "$DESC")"
  local DEDUP=0
  # ...but never on the flagged placeholder. The placeholder is identical every time it
  # is written, so two different turns that both failed to produce a usable description
  # looked like one repeated turn and the second turn's time was dropped outright. A
  # placeholder is an admission that we do not know what the work was; it is not
  # evidence that the work was the same. The stricter description screen made this
  # reachable in ordinary use rather than rarely.
  #
  # Written against the LITERAL string until a second flag wording was added. The second
  # wording did not share the prefix, so it fell straight back INTO dedup and two
  # rejected turns inside the window recorded once: the exact time-losing defect this
  # guard exists to prevent, reintroduced by adding a flag. Asking the predicate instead
  # of matching a string means a third wording cannot do it again.
  if [[ -f "$lastf" ]] && ! _desc_is_placeholder "$DESC"; then
    local line lt lk
    line="$(head -1 "$lastf")"; lt="${line%%|*}"; lk="${line#*|}"
    if [[ "$lt" =~ ^[0-9]+$ && "$lk" == "$SEG" && $((NOW - lt)) -lt 900 ]]; then DEDUP=1; fi
  fi

  if [[ $MERGED -eq 0 && $DEDUP -eq 0 ]]; then
    if [[ -n "$PERSON" ]]; then
      q_enqueue "$QUEUE" "$PERSON" "$DESC" "$WT" "$TASK" "$PROJ" "$START"
    else
      # Kept, not dropped: queued under the login, and delivered once the login resolves to
      # a person. Said on this turn, plainly, because a silent miss is how a person used to
      # lose days of time without knowing.
      q_enqueue "$QUEUE" "${APROPOS_UNRESOLVED_PREFIX}${LOGIN}" "$DESC" "$WT" "$TASK" "$PROJ" "$START"
      # Shown to the person through the hook's systemMessage, and kept on stderr for the debug log.
      # Which turn is set once, above the merge, from the event that is recording it.
      local _held_msg
      if [[ -n "$LOGIN" ]]; then
        _held_msg="Apropos has not recorded $_held_turn yet for the login $LOGIN, because ${PERSON_UNRESOLVED:-you could not be identified}. It is kept on this computer and will be recorded once you are identified. $PERSON_UNRESOLVED_ADVICE"
      else
        # With no login there is nothing to identify later: the kept line carries no login, so
        # no lookup can ever resolve it and it is never sent on its own. Say so, rather than
        # promise a delivery that cannot happen.
        _held_msg="Apropos has not recorded $_held_turn, because ${PERSON_UNRESOLVED:-no login name could be read on this computer}. It is kept on this computer, but without a login it cannot be sent to Apropos later, so record this time yourself with /apropos:time once the login is fixed. $PERSON_UNRESOLVED_ADVICE"
      fi
      notice_add "$_held_msg"
      printf 'apropos: %s\n' "$_held_msg" >&2
    fi
    # A flagged entry is remembered so a later turn, or the daily sweep, can try again with
    # the transcript as it finally stands. Keyed on the start time because the entry has no
    # id yet: this call only enqueues, and the id is parsed later inside write_entry, which
    # knows nothing about the session or the directory.
    if _desc_is_placeholder "$DESC"; then
      fl_record "$START" "$SID" "$basecwd" "$(date -u +%s)" || true
    fi
    printf '%s|%s\n' "$NOW" "$SEG" > "$lastf"
    # The day's tally, written HERE rather than beside the catch-all announcement,
    # because only this branch actually creates an entry. At the announcement it also
    # counted turns that were deduped away, so the audit reported more entries than
    # exist, and an audit that overcounts is one people stop reading.
    #
    # Local, built from what the recorder saw. No credentials or database access ship
    # in this plugin and an audit is not a reason to change that. Every failure is
    # swallowed: recording the hour matters more than auditing it.
    if [[ "$TASK" == "0" ]]; then
      {
        mkdir -p "${HOME}/.claude/apropos-time" 2>/dev/null &&
        printf '%s	%s	%s
' "$(date -u +%H:%M:%S)" "${_optout_dir:-unknown}" "$DESC" \
          >> "${HOME}/.claude/apropos-time/catchall-$(date -u +%Y-%m-%d).tsv"
      } 2>/dev/null || true
    fi
  fi


  # Re-surface the day's running total from HERE, not only at session start. Session start
  # fires on a new session, a resume, a clear or a compact, none of which a single unbroken
  # session is guaranteed to hit, so a day spent in one session would see the total once and
  # never again. This hook runs on every turn regardless.
  #
  # Throttled to once an hour. A reminder on every turn is one people learn to scroll past,
  # which is how it would quietly stop working.
  if [[ "$TASK" == "0" ]]; then
    _ca_file="${HOME}/.claude/apropos-time/catchall-$(date -u +%Y-%m-%d).tsv"
    _ca_stamp="${HOME}/.claude/apropos-time/catchall-last-report"
    if [[ -s "$_ca_file" ]]; then
      _ca_last=0; [[ -s "$_ca_stamp" ]] && read -r _ca_last < "$_ca_stamp" 2>/dev/null
      [[ "$_ca_last" =~ ^[0-9]+$ ]] || _ca_last=0
      if (( NOW - _ca_last >= ${APROPOS_CATCHALL_REPORT_SECS:-3600} )); then
        _ca_n=0; while read -r _ca_l; do [[ -n "$_ca_l" ]] && _ca_n=$((_ca_n+1)); done < "$_ca_file"
        printf 'apropos: %s entries so far today have gone to your catch-all task instead of a client. They are listed in %s. Correct them before the day closes.
' "$_ca_n" "$_ca_file" >&2
        printf '%s' "$NOW" > "$_ca_stamp" 2>/dev/null || true
      fi
    fi
  fi

  # Consume the one-shot model files. Safe here because this line is reached only
  # after the entry was enqueued, or after it was confirmed a true duplicate
  # (identical description AND segment within 15 min). Nothing unrecorded is lost.
  # Safe to do now: the entry is queued, so a slow lock here can cost the worktype hint
  # for the next session but can never cost the time itself.
  [[ "$WTSRC" != "default" ]] && task_wt_record "$TASK" "$WT"

  rm -f "$descf" "$wtf" 2>/dev/null || true
}

case "$EVENT" in
  Stop)
    # Primary recorder. Use the start time stamped when the prompt came in, so the
    # marker sits at the real beginning of the work rather than at its end.
    START="$(start_from_stamp "$startf")"
    record_turn "$START"
    rm -f "$startf" 2>/dev/null || true
    ;;
  Sweep)
    # Once-a-day repair pass across the WHOLE ledger, triggered from session-init.sh's
    # SessionStart path. That path runs this file as a real subprocess with the event
    # piped in as JSON, rather than sourcing it: this script reads its event from stdin,
    # not from the environment (see the header comment on EVENT), and ends by exiting, so
    # sourcing it would exit session-init.sh's own hook too. sweep_due keeps this to once
    # per machine per day even though every concurrent session's start asks for it, and
    # sweep_run resumes a pass an earlier start did not finish.
    sweep_run
    ;;
  *)
    # UserPromptSubmit. Recovery first: a leftover description file means Stop did
    # not run for the previous turn (crash, kill, Stop not registered). Record it
    # with that turn's stamped start so the work is not lost.
    if [[ -s "$descf" ]]; then
      record_turn "$(start_from_stamp "$startf")"
    fi
    # Stamp this turn's start for the Stop hook to use.
    printf '%s' "$NOW" > "$startf"
    [[ -n "$CWD" ]] && printf '%s' "$CWD" > "$cwdf"
    ;;
esac

# The notice goes out BEFORE the flush. A flush can run to the hook's time limit, and a hook
# cut off there shows nothing, so a notice printed after it was lost exactly when the backlog
# was largest. The flush writes nothing to stdout, so the object stays the only thing on it.
# The real stdout is then closed, so a write still running when a hook is cut off does not hold
# it open after the hook has gone.
notice_emit
exec 3>&-

# Always attempt to flush (delivers this entry and any prior queued ones), but start no delivery
# more than APROPOS_TURN_FLUSH_SECS after the flush begins. Before this the per-turn flush had no
# deadline, and the first flush after a person was identified ran their whole held backlog into
# the 30 second limit on every prompt, where the write in flight could be cut off and sent again
# next time. One real write was measured at 12 to 20 seconds, so this normally means one or two
# deliveries per turn, and the rest follow on later turns.
#
# Counted from the flush, not from the hook's start, so the first delivery is always attempted,
# as it always has been. Counted from the hook's start, a turn whose own work ran long (waiting
# on another session's claim on the activity can take 25 seconds) started no delivery at all,
# and on a computer where that was every turn nothing would ever be delivered by a turn. A
# deadline set by the caller (session start runs the daily pass through this file) wins when it
# is sooner. Lines not reached stay queued.
_tf_secs="${APROPOS_TURN_FLUSH_SECS:-15}"; [[ "$_tf_secs" =~ ^[0-9]+$ ]] || _tf_secs=15
_tf_deadline=$(( $(date -u +%s) + _tf_secs ))
if [[ "${APROPOS_FLUSH_DEADLINE:-}" =~ ^[0-9]+$ ]] && (( APROPOS_FLUSH_DEADLINE < _tf_deadline )); then
  _tf_deadline="$APROPOS_FLUSH_DEADLINE"
fi
APROPOS_FLUSH_DEADLINE="$_tf_deadline" q_flush "$QUEUE" write_entry
exit 0
