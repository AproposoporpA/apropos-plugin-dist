#!/usr/bin/env bash
# Who is recording time on this computer.
#
# The plugin used to hold a list of staff logins and their Apropos person ids in its own
# code. Anyone missing from it recorded nothing and was told nothing, and every new team
# member needed a plugin release before a minute of their time could record. Now the login
# is looked up in Apropos itself, through a read-only script beside the insert script on
# the shared drive, and the answer is kept on this machine so recording carries on when the
# lookup cannot be reached.
#
# Sourced after lib/writer.sh, which provides lookup_person. Written for bash 3.2 as well as
# Git Bash, because a Mac runs hooks with the system bash: no associative arrays, no ${x,,}.
#
#   person_resolve [--force] <login>
#       Sets PERSON_ID and returns 0 when the person is known.
#       Returns 2 when the lookup says the login has no usable account (PERSON_CAUSE says
#       which), and 3 when the lookup could not be reached and this machine has never
#       identified the login. PERSON_CAUSE is set on every non-zero return.
#
# Settings, all optional:
#   APROPOS_PERSON_FILE          cache of known logins (login TAB id TAB epoch)
#   APROPOS_PERSON_MISS_FILE     last failed lookup per login (login TAB kind TAB epoch)
#   APROPOS_PERSON_REFRESH_SECS  how old a cached answer may be before it is checked again
#   APROPOS_PERSON_RETRY_SECS    how long after a failed lookup before trying again
APROPOS_PERSON_FILE="${APROPOS_PERSON_FILE:-${HOME}/.claude/apropos-time/person.tsv}"
APROPOS_PERSON_MISS_FILE="${APROPOS_PERSON_MISS_FILE:-${HOME}/.claude/apropos-time/person-miss.tsv}"
# Once a day. A person's account does not change often, and a cached answer costs nothing,
# where a lookup starts PowerShell and opens a database connection inside a 30 second hook.
APROPOS_PERSON_REFRESH_SECS="${APROPOS_PERSON_REFRESH_SECS:-86400}"
# A failed lookup is not repeated on every turn: unreachable costs up to the lookup timeout
# each time. Session start passes --force, so a person whose account has just been fixed is
# picked up at the next session without waiting out this interval.
APROPOS_PERSON_RETRY_SECS="${APROPOS_PERSON_RETRY_SECS:-600}"

# The queue's person field for an entry recorded before the person was known. Delivery
# resolves it first. A numeric person field, as every earlier version wrote, delivers as is.
APROPOS_UNRESOLVED_PREFIX="unresolved:"

PERSON_ID=""
PERSON_CAUSE=""
PERSON_ADVICE=""

# apropos_login -> the computer login, lower-cased. Windows sets USERNAME, macOS and Linux
# set USER. Lower-cased because the lookup is case-insensitive and the cache must not hold
# two lines for one person.
#
# Every control character is removed, not only tab, CR and LF: the login is quoted in the
# notice the recorder prints as JSON, and any other character below 0x20 there makes the whole
# object invalid, so the notice would not be shown. No Apropos username holds one.
apropos_login() {
  local u="${USERNAME:-${USER:-}}"
  [[ -z "$u" ]] && u="$(id -un 2>/dev/null)"
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]' | tr -d '\000-\037\177'
}

# _person_field <file> <login> <field number> -> that field of the login's line, if any.
_person_field() {
  local f="$1" login="$2" n="$3" k a b
  [[ -s "$f" ]] || return 1
  while IFS=$'\t' read -r k a b; do
    [[ "$k" == "$login" ]] || continue
    case "$n" in 2) printf '%s' "$a" ;; 3) printf '%s' "$b" ;; esac
    return 0
  done < "$f"
  return 1
}

# _person_put <file> <login> [<field2> <field3>] - replace the login's line, or remove it when
# no fields are given. Written to a temporary file and moved into place, so a reader never
# sees half a file. Two sessions writing at once can only lose each other's line for a
# different login, and a lost line is simply looked up again.
_person_put() {
  local f="$1" login="$2" a="${3:-}" b="${4:-}" tmp k x y
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  tmp="$f.tmp.$$"
  {
    if [[ -s "$f" ]]; then
      while IFS=$'\t' read -r k x y; do
        [[ -z "$k" || "$k" == "$login" ]] && continue
        printf '%s\t%s\t%s\n' "$k" "$x" "$y"
      done < "$f"
    fi
    # An if, not [[ ]] &&: as the group's last command a false test would fail the group,
    # and the removal (no fields) would never be moved into place.
    if [[ -n "$a" ]]; then printf '%s\t%s\t%s\n' "$login" "$a" "$b"; fi
  } > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# _person_cause <kind> -> the plain reason, for the turn's notice and the alert. Every message
# names the login once, just before the reason, so the reason itself does not repeat it.
_person_cause() {
  case "$1" in
    nologin)     printf 'no login name could be read on this computer' ;;
    nomatch)     printf 'no Apropos account has that username' ;;
    inactive)    printf 'only an inactive Apropos account has that username' ;;
    multiple)    printf 'more than one active Apropos account has that username' ;;
    *)           printf 'the Apropos staff lookup could not be reached, and this computer has not identified that login before' ;;
  esac
}

# _person_is_unknown <kind> -> true for the answers that mean the account itself is missing
# or wrong, as opposed to a lookup that could not be completed.
_person_is_unknown() { case "$1" in nologin|nomatch|inactive|multiple) return 0 ;; esac; return 1; }

# _person_advice <kind> -> what gets it fixed, said after the cause. For the unreachable case
# this is the recorder's advice, which holds the time; a time command holds nothing and says
# so itself (person-id.sh).
_person_advice() {
  case "$1" in
    nologin)  printf 'Check that Claude Code is started with the USERNAME (Windows) or USER (Mac) setting present.' ;;
    nomatch)  printf 'Ask whoever manages Apropos accounts to set the username on your account to that login.' ;;
    inactive) printf 'Ask whoever manages Apropos accounts to put that login on your active account.' ;;
    multiple) printf 'Ask whoever manages Apropos accounts to leave that login on your account only.' ;;
    *)        printf 'The kept time is sent automatically once you are on the office network with the shared drive connected.' ;;
  esac
}

person_resolve() {
  local force=0
  [[ "${1:-}" == "--force" ]] && { force=1; shift; }
  local login="${1:-}" now id epoch kind mepoch out rc
  PERSON_ID=""; PERSON_CAUSE=""; PERSON_ADVICE=""
  now="$(date -u +%s)"

  if [[ -z "$login" ]]; then
    PERSON_CAUSE="$(_person_cause nologin)"
    PERSON_ADVICE="$(_person_advice nologin)"
    return 2
  fi

  id="$(_person_field "$APROPOS_PERSON_FILE" "$login" 2)"
  epoch="$(_person_field "$APROPOS_PERSON_FILE" "$login" 3)"
  [[ "$id" =~ ^[0-9]+$ ]] || id=""
  [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0

  # A fresh answer on this machine: no lookup at all, so the hook spends nothing.
  if [[ -n "$id" ]] && (( now - epoch < APROPOS_PERSON_REFRESH_SECS )); then
    PERSON_ID="$id"; return 0
  fi

  # A lookup failed recently: repeat its answer rather than paying for another one.
  kind="$(_person_field "$APROPOS_PERSON_MISS_FILE" "$login" 2)"
  mepoch="$(_person_field "$APROPOS_PERSON_MISS_FILE" "$login" 3)"
  [[ "$mepoch" =~ ^[0-9]+$ ]] || mepoch=0
  if (( ! force )) && [[ -n "$kind" ]] && (( now - mepoch < APROPOS_PERSON_RETRY_SECS )); then
    if _person_is_unknown "$kind"; then
      PERSON_CAUSE="$(_person_cause "$kind")"; PERSON_ADVICE="$(_person_advice "$kind")"; return 2
    fi
    if [[ -n "$id" ]]; then PERSON_ID="$id"; return 0; fi
    PERSON_CAUSE="$(_person_cause unreachable)"; PERSON_ADVICE="$(_person_advice unreachable)"; return 3
  fi

  out="$(lookup_person "$login" 2>/dev/null)"; rc=$?
  if (( rc == 0 )); then
    local found
    found="$(printf '%s' "$out" | tr -d '\r' | grep -o 'APROPOS_PERSON_ID=[0-9][0-9]*' | head -1 | cut -d= -f2)"
    if [[ "$found" =~ ^[0-9]+$ ]]; then
      _person_put "$APROPOS_PERSON_FILE" "$login" "$found" "$now"
      _person_put "$APROPOS_PERSON_MISS_FILE" "$login"
      PERSON_ID="$found"; return 0
    fi
    rc=5   # a zero exit without an id is not an answer; treat it as unreachable
  fi

  case "$rc" in
    2) kind=nomatch ;;
    3) kind=inactive ;;
    4) kind=multiple ;;
    *) kind=unreachable ;;
  esac
  _person_put "$APROPOS_PERSON_MISS_FILE" "$login" "$kind" "$now"

  if _person_is_unknown "$kind"; then
    # The lookup answered, and the answer is that this login has no usable account. A
    # cached id is now known to be wrong (the account was deactivated, or the username
    # moved), so it is dropped rather than used to write time against the wrong person.
    # The turn is still kept, queued, and delivered once the account is put right.
    _person_put "$APROPOS_PERSON_FILE" "$login"
    PERSON_CAUSE="$(_person_cause "$kind")"
    PERSON_ADVICE="$(_person_advice "$kind")"
    return 2
  fi
  # The lookup could not be completed: off the network, the shared drive not mapped, the
  # database down, or the script not there. A person this machine has identified before
  # carries on recording under the id it last confirmed.
  if [[ -n "$id" ]]; then PERSON_ID="$id"; return 0; fi
  PERSON_CAUSE="$(_person_cause unreachable)"
  PERSON_ADVICE="$(_person_advice unreachable)"
  return 3
}
