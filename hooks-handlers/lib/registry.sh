#!/usr/bin/env bash
# Which plugin version this computer runs, told to the person and to the team's machine registry.
#
# Sourced by session-init.sh. Local reads, and one small file written to the team's shared folder.
# No credentials and no database access.
#
# WHY. Nobody could see which plugin version each computer ran. Two computers still ran an old
# install, and the only way to find out was to visit each one. And a session can run one version
# while another is installed (an update made while the session ran, or an install record that did not
# move), which nobody noticed until entries went wrong.
#
# WHAT.
#   - At session start the running version (this copy's own plugin.json) is compared with the
#     installed one (Claude Code's install record). When they differ, the session is told once, in
#     words it passes on to the person (reg_version_notice).
#   - In the background, one file per computer is written to the team's machine registry,
#     <hub>/setup/runs/registry/plugin/<COMPUTER>.json: the login and person id, the running and
#     installed versions, the installed commit, the Claude Code version, node's version, and when it
#     was written. It is written through a temporary file and a rename, so a reader never sees half a
#     file, and not at all when the file already written today holds the same values, so a computer
#     writes it at most once a day, and again only when something changes (reg_write).
#
# Where: APROPOS_REGISTRY_DIR when set; otherwise the hub the time skill lives in
# (APROPOS_SKILL_DIR, default R:/Intranet/ClaudeAI/skills/work-management/time), whose
# setup/runs/registry folder must already exist. Off the network, or anywhere else, nothing is written.

REG_RUNNING=""; REG_INSTALLED=""; REG_COMMIT=""

# _reg_json_field <file> <jq path> <grep key> - a string field of a small JSON file: by jq when there
# is one, else the first "key": "value" pair of that name.
_reg_json_field() {
  local f="$1" v=""
  [[ -s "$f" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r "$2 // empty" "$f" 2>/dev/null | head -1)"
  else
    v="$(grep -o "\"$3\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
  fi
  v="${v%$'\r'}"
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# reg_versions <plugin root> - sets REG_RUNNING from the plugin's own plugin.json, and REG_INSTALLED
# and REG_COMMIT from Claude Code's install record for this plugin: the entry whose install path is
# this copy's, else the first. Each is empty when it cannot be read. Local reads only.
reg_versions() {
  local root="${1:-}" rec="${APROPOS_INSTALL_RECORD:-${HOME}/.claude/plugins/installed_plugins.json}" out="" v c p
  REG_RUNNING=""; REG_INSTALLED=""; REG_COMMIT=""
  [[ -n "$root" ]] && REG_RUNNING="$(_reg_json_field "$root/.claude-plugin/plugin.json" '.version' version)"
  [[ -s "$rec" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    out="$(jq -r --arg root "${root//\\//}" '
        (.plugins["apropos@apropos-plugin"] // []) | if type == "array" then . else [.] end
        | (map(select(((.installPath // "") | gsub("\\\\"; "/") | ascii_downcase) == ($root | ascii_downcase))) + .)[0] // {}
        | [(.version // ""), (.gitCommitSha // "")] | @tsv' "$rec" 2>/dev/null)"
    out="${out%$'\r'}"
    IFS=$'\t' read -r v c <<< "$out"
  else
    # Without jq: the first version and commit after the plugin's name.
    p="$(tr -d '\r\n' < "$rec" 2>/dev/null | sed 's/.*"apropos@apropos-plugin"//')"
    v="$(printf '%s' "$p" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
    c="$(printf '%s' "$p" | grep -o '"gitCommitSha"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
  fi
  # Versions and commits are plain: anything else is not reported.
  [[ "$REG_RUNNING" =~ ^[0-9A-Za-z.+-]{1,40}$ ]] || REG_RUNNING=""
  [[ "$v" =~ ^[0-9A-Za-z.+-]{1,40}$ ]] && REG_INSTALLED="$v"
  [[ "$c" =~ ^[0-9a-fA-F]{7,64}$ ]] && REG_COMMIT="$c"
  return 0
}

# reg_version_notice <session id> - prints the notice when the running and installed versions are
# both known and differ, once per session (remembered in version-told-<session>.txt beside the
# session's other files; with no session id, once a day). Prints nothing otherwise.
reg_version_notice() {
  local sid="${1:-}" dir="${APROPOS_TRACK_DIR:-/tmp/claude-timetrack}" key f
  [[ -n "$REG_RUNNING" && -n "$REG_INSTALLED" && "$REG_RUNNING" != "$REG_INSTALLED" ]] || return 0
  sid="${sid//[^A-Za-z0-9_-]/}"
  [[ -n "$sid" ]] || sid="day-$(date -u +%Y-%m-%d)"
  key="$REG_RUNNING $REG_INSTALLED"
  f="$dir/version-told-$sid.txt"
  mkdir -p "$dir" 2>/dev/null
  if [[ -s "$f" ]] && [[ "$(head -1 "$f" 2>/dev/null)" == "$key" ]]; then return 0; fi
  printf '%s\n' "$key" > "$f" 2>/dev/null
  echo ""
  echo "APROPOS: this session is running version $REG_RUNNING of the time recording plugin, but version $REG_INSTALLED is installed. Run /reload-plugins, or restart Claude Code, so the installed version records your time."
  return 0
}

# reg_dir - prints the folder the registry file goes in, when there is one to write to.
reg_dir() {
  local d="${APROPOS_REGISTRY_DIR:-}" s hub
  if [[ -z "$d" ]]; then
    s="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}"
    s="${s//\\//}"; s="${s%/}"
    case "$s" in
      */skills/work-management/time) hub="${s%/skills/work-management/time}" ;;
      *) return 1 ;;
    esac
    [[ -d "$hub/setup/runs/registry" ]] || return 1
    d="$hub/setup/runs/registry/plugin"
  fi
  d="${d//\\//}"
  [[ -d "$d" ]] || mkdir "$d" 2>/dev/null || return 1
  printf '%s' "$d"
}

# reg_computer - this computer's name, upper case, letters, digits, dash and underscore only.
reg_computer() {
  local c="${COMPUTERNAME:-}"
  [[ -z "$c" ]] && command -v scutil >/dev/null 2>&1 && c="$(scutil --get LocalHostName 2>/dev/null)"
  [[ -z "$c" ]] && c="$(hostname -s 2>/dev/null || hostname 2>/dev/null)"
  c="${c%%.*}"; c="${c//[^A-Za-z0-9_-]/}"
  printf '%s' "$c" | tr '[:lower:]' '[:upper:]'
}

# reg_claude_version - the Claude Code version: from the package beside the program Claude Code says
# it runs (CLAUDE_CODE_EXECPATH), from a versions/<x.y.z> folder in that path, or by asking it.
reg_claude_version() {
  local e="${CLAUDE_CODE_EXECPATH:-}" d v="" i
  e="${e//\\//}"
  if [[ -n "$e" ]]; then
    d="$(dirname "$e")"
    for i in 1 2 3; do
      if [[ -s "$d/package.json" ]]; then
        v="$(_reg_json_field "$d/package.json" '.version' version)"
        [[ -n "$v" ]] && break
      fi
      d="$(dirname "$d")"
    done
    [[ -z "$v" && "$e" =~ /versions/([0-9]+\.[0-9]+\.[0-9]+[^/]*) ]] && v="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$v" ]] && command -v claude >/dev/null 2>&1; then
    v="$(claude --version 2>/dev/null | head -1)"; v="${v%% *}"
  fi
  [[ "$v" =~ ^[0-9][0-9A-Za-z.+-]{0,39}$ ]] || v=""
  printf '%s' "$v"
}

# _reg_q <value> - the value as a JSON string, or null when empty. Values are already plain.
_reg_q() { if [[ -n "$1" ]]; then printf '"%s"' "$1"; else printf 'null'; fi; }

# reg_write <login> <person id> - writes this computer's registry file when it is missing, was not
# written today (UTC), or holds other values. Call after reg_versions. Returns 0 when it wrote, 1 when
# it skipped, 2 when there is nowhere to write.
reg_write() {
  local login="${1:-}" pid="${2:-}" d c f tmp os node cc today body old=""
  d="$(reg_dir)" || return 2
  c="$(reg_computer)"; [[ -n "$c" ]] || return 2
  login="${login//[^A-Za-z0-9._@-]/}"
  [[ "$pid" =~ ^[0-9]{1,12}$ ]] || pid=""
  case "$(uname -s 2>/dev/null)" in
    Darwin) os=Mac ;; Linux) os=Linux ;; *) os=Windows ;;
  esac
  node=""
  if command -v node >/dev/null 2>&1; then node="$(node --version 2>/dev/null | head -1)"; node="${node%$'\r'}"; fi
  [[ "$node" =~ ^v?[0-9][0-9A-Za-z.+-]{0,39}$ ]] || node=""
  cc="$(reg_claude_version)"
  # One field per line, in a fixed order, so the file can be compared without its time line.
  body="{
  \"computer\": $(_reg_q "$c"),
  \"login\": $(_reg_q "$login"),
  \"personId\": $(_reg_q "$pid"),
  \"os\": $(_reg_q "$os"),
  \"pluginRunning\": $(_reg_q "$REG_RUNNING"),
  \"pluginInstalled\": $(_reg_q "$REG_INSTALLED"),
  \"pluginCommit\": $(_reg_q "$REG_COMMIT"),
  \"claudeCode\": $(_reg_q "$cc"),
  \"node\": $(_reg_q "$node"),"
  today="$(date -u +%Y-%m-%d)"
  f="$d/$c.json"
  if [[ -s "$f" ]]; then
    old="$(tr -d '\r' < "$f" 2>/dev/null)"
    if [[ "$old" == "$body"$'\n  "writtenAt": "'"$today"T* ]]; then return 1; fi
  fi
  tmp="$d/.$c.json.$$.tmp"
  printf '%s\n  "writtenAt": "%s"\n}\n' "$body" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 2; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 2; }
  return 0
}
