#!/usr/bin/env bash
# Prints the Apropos person id of whoever is logged in to this computer, for the time
# commands (/apropos:time, :break, :lunch, :out).
#
# Resolved exactly as the recorder resolves it (lib/person.sh): the login is looked up in
# Apropos and the answer cached on this machine, so the commands never carry a staff list.
#
#   APROPOS_PERSON_ID=<id>   exit 0
#   a plain reason on stderr exit 2 (no usable account) or 3 (lookup unreachable, never
#                            identified on this computer)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/queue.sh"
source "$HERE/lib/writer.sh"
source "$HERE/lib/person.sh"

login="$(apropos_login)"
person_resolve --force "$login"; rc=$?
if (( rc == 0 )); then
  printf 'APROPOS_PERSON_ID=%s\n' "$PERSON_ID"
  exit 0
fi
# A command keeps nothing: unlike a turn, what it was asked to record is not queued. So the
# unreachable case says to try again, not that anything will be delivered later.
advice="$PERSON_ADVICE"
(( rc == 3 )) && advice="Try again once you are on the office network with the shared drive connected."
printf 'apropos: nothing was recorded for the login %s, because %s. %s\n' "${login:-(none)}" "$PERSON_CAUSE" "$advice" >&2
exit "$rc"
