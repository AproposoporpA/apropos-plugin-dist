#!/usr/bin/env bash
# The day's catch-all entries, as the person is shown them.
#
# The recorder appends one line per entry it sends with no task and no project, which the insert
# script then books to the person's catch-all task (or leaves with no task, for someone who has
# none): catchall-<UTC date>.tsv in ~/.claude/apropos-time, columns
#   UTC time written <TAB> folder <TAB> description <TAB> local start time (HH:MM)
# Lines written before the fourth column existed show their UTC time instead.
#
# Used by the per-turn message and by session start, so both say the same thing. Local only: no
# credentials and no database access ship in this plugin.

# catchall_list <file> <max shown, 0 for all> <separator> [prefix] [lead] [closing] [cut width, 0 for none]
# Prints "<prefix>N entries today went to your catch-all task ...:<lead>HH:MM description<sep>..."
# with the newest <max shown> entries (every entry when 0), oldest of them first, and how many
# earlier ones are not shown and where they are listed, then the closing sentence (an empty closing
# leaves it off). A description longer than the cut width is shortened to fit it. Prints nothing
# and returns 1 when the file has no entries.
catchall_list() {
  local f="$1" max="${2:-6}" sep="${3:-; }" prefix="${4:-}" lead="${5:- }"
  local closing="${6- Set the task for the work, and move these to the right task before the day closes.}"
  local width="${7:-70}"
  local -a items=()
  local line t folder d hm n=0 shown="" i start noun
  [[ -s "$f" ]] || return 1
  [[ "$max" =~ ^[0-9]+$ ]] || max=6
  [[ "$width" =~ ^[0-9]+$ ]] || width=70
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    # Split on each tab exactly. read with IFS set to a tab would merge two tabs in a row, so an
    # empty column would move the next one into its place.
    t="${line%%$'\t'*}"; line="${line#*$'\t'}"
    folder="${line%%$'\t'*}"; line="${line#"$folder"}"; line="${line#$'\t'}"
    d="${line%%$'\t'*}"; hm=""
    [[ "$line" == *$'\t'* ]] && { hm="${line#*$'\t'}"; hm="${hm%%$'\t'*}"; }
    [[ "$hm" =~ ^[0-9]{2}:[0-9]{2}$ ]] || hm="${t:0:5} UTC"
    (( width > 3 && ${#d} > width )) && d="${d:0:$((width - 3))}..."
    items+=("$hm ${d:-(no description)}")
    n=$((n+1))
  done < "$f"
  (( n > 0 )) || return 1
  start=0
  (( max > 0 && n > max )) && start=$(( n - max ))
  for (( i = start; i < n; i++ )); do
    shown="${shown:+$shown$sep}${items[$i]}"
  done
  noun="entries"; (( n == 1 )) && noun="entry"
  printf '%s%s %s today went to your catch-all task because no task was set for that work:%s%s' "$prefix" "$n" "$noun" "$lead" "$shown"
  if (( start > 0 )); then
    printf '%s(and %s earlier, listed in %s)' "$sep" "$start" "$f"; shown=")"
  fi
  # The closing is a new sentence, so the list ends with one full stop, never two.
  if [[ -n "$closing" ]]; then
    case "$shown" in *[.!?]) ;; *) printf '.' ;; esac
    printf '%s' "$closing"
  fi
  return 0
}
