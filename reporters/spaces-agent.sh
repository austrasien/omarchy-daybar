#!/usr/bin/env bash
# Claude Code hook: tells the day bar (austraz.daybar) what a session is doing.
# One command for every hook event; the state comes from hook_event_name.
#
#   working  a turn is in progress
#   waiting  Claude Code is blocked on a permission prompt (and what it asks)
#   done     the turn finished (and a summary of the reply, by agent-summary)
#   end      the session is gone
#
# pids[0] is the live agent process: the bar drops the agent if it dies.
# Claude Code runs this hook from a short-lived shell, so the claude process
# goes first (then foot, systemd) rather than PPID.
# Hooks must stay silent on stdout: Claude Code reads it as hook output.

export PATH="/usr/share/omarchy/bin:/usr/bin:/usr/local/bin:${PATH:-}"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/spaces-agent"
LAST_DIR="$STATE_DIR/last"
LOG="${HOME}/.local/state/omarchy/spaces-agent-hook.log"
LOG_MAX=204800

# Agent state goes to the day bar (austraz.daybar), which took over from
# Spaces; add tornikegomareli.spaces back to report to Spaces again.
AGENT_PLUGINS=(austraz.daybar)
send_agent() {
  local plugin
  for plugin in "${AGENT_PLUGINS[@]}"; do
    omarchy-shell "$plugin" agent "$@" >/dev/null 2>&1 &
  done
}

rotate_log() {
  local sz
  [[ -f $LOG ]] || return 0
  sz=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  ((sz > LOG_MAX)) || return 0
  tail -c $((LOG_MAX / 2)) "$LOG" >"${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
}

log() {
  mkdir -p "$(dirname "$LOG")"
  printf '%s %s\n' "$(date '+%H:%M:%S')" "[claude] $*" >>"$LOG" 2>/dev/null || true
}

safe_id() {
  local s=$1
  s=${s//[^A-Za-z0-9._-]/_}
  printf '%s' "${s:-unknown}"
}

last_is() {
  local id=$1 want=$2 line f
  f="$LAST_DIR/$(safe_id "$id")"
  [[ -f $f ]] || return 1
  line=$(<"$f")
  [[ $line == "$want "* || $line == "$want" ]]
}

# Keep the claude process (or the terminal child) first so the gold chip
# survives Spaces' once-a-minute pids[0] probe.
reorder_session_pids() {
  local csv=$1
  [[ -n $csv ]] || return 0
  local IFS=','
  local -a chain=($csv)
  unset IFS
  local i comm cmd pick=""
  for ((i=${#chain[@]}-1; i>=0; i--)); do
    comm=$(<"/proc/${chain[i]}/comm" 2>/dev/null) || continue
    cmd=$(tr '\0' ' ' <"/proc/${chain[i]}/cmdline" 2>/dev/null || true)
    if [[ $comm == claude || $cmd == */claude\ * || $cmd == claude\ * ]]; then
      pick=${chain[i]}
      break
    fi
  done
  if [[ -z $pick ]]; then
    for ((i=${#chain[@]}-1; i>=0; i--)); do
      comm=$(<"/proc/${chain[i]}/comm" 2>/dev/null) || continue
      case $comm in
        foot|kitty|ghostty|alacritty|wezterm|wezterm-gui|xterm|kgx)
          ((i>0)) && pick=${chain[i-1]}
          break
          ;;
      esac
    done
  fi
  [[ -n $pick ]] || pick=${chain[0]}
  local out=$pick
  local pid
  for pid in "${chain[@]}"; do
    [[ $pid == "$pick" ]] && continue
    out+=",$pid"
  done
  printf '%s' "$out"
}

last_probe_alive() {
  local id=$1 line f first
  f="$LAST_DIR/$(safe_id "$id")"
  [[ -f $f ]] || return 1
  line=$(<"$f")
  first=${line#* }
  first=${first%%,*}
  first=${first%% *}
  [[ ${first:-0} -gt 1 && -r /proc/$first/stat ]]
}

# Re-push the last working report without walking /proc. Spaces is in-memory:
# a shell restart drops the gold chip, and last/ still says working so we
# would otherwise stay silent until the next turn.
reassert_working() {
  local id=$1 f line cached
  f="$LAST_DIR/$(safe_id "$id")"
  [[ -f $f ]] || return 1
  line=$(<"$f")
  cached=${line#working }
  [[ -n $cached && $cached != "$line" ]] || return 1
  send_agent "$id" working "$cached"
}

remember() {
  local id=$1 state=$2
  mkdir -p "$LAST_DIR"
  printf '%s %s\n' "$state" "$pids" >"$LAST_DIR/$(safe_id "$id")"
}

forget() {
  rm -f "$LAST_DIR/$(safe_id "$1")"
}

# The day bar's card shows a one-line summary of the reply, made on the
# local NPU model by agent-summary, detached so the hook returns at once.
# A turn stamp lets a slow summary of an older turn be dropped.
SUMMARY_DIR="$STATE_DIR/summary"
mark_turn() {
  mkdir -p "$SUMMARY_DIR"
  printf '%s\n' "$2" >"$SUMMARY_DIR/$(safe_id "$1")"
}
summarize() {
  local id=$1 turn
  turn="$(date +%s%N)"
  mark_turn "$id" "$turn"
  command -v agent-summary >/dev/null 2>&1 || [[ -x $HOME/.config/omarchy/bin/agent-summary ]] || return 0
  setsid "$HOME/.config/omarchy/bin/agent-summary" "$(safe_id "$id")" "$turn" \
    <<<"$input" >/dev/null 2>&1 &
}

rotate_log

input=$(cat 2>/dev/null || true)
# call: the tool call about to run, as compact JSON, kept for the day bar's
# card if Claude Code then stops on a permission prompt (see agent-ask).
{
  IFS=$'\x1f' read -r event session ntype call
} < <(jq -r '[
  (.hook_event_name // ""),
  (.session_id // ""),
  (.notification_type // ""),
  (if .tool_name then {tool_name, tool_input} | tojson else "" end)
] | join("\u001f")' <<<"$input" 2>/dev/null || printf '\x1f\x1f\x1f\n')
[[ -n $session ]] || session="pid${PPID:-0}"
session="claude-$session"

ASK_DIR="$STATE_DIR/ask"
if [[ $event == PreToolUse && -n $call ]]; then
  mkdir -p "$ASK_DIR"
  printf '%s\n' "$call" >"$ASK_DIR/$(safe_id "$session")"
fi

# Mid-turn tool events: skip the /proc walk when the last report's probe
# PID is still alive, but re-assert working in case the shell restarted.
case "$event" in
  PreToolUse|PostToolUse)
    if last_is "$session" working && last_probe_alive "$session"; then
      reassert_working "$session"
      exit 0
    fi
    ;;
esac

pids=""
pid=${PPID:-0}
while [[ $pid -gt 1 && -r /proc/$pid/stat ]]; do
  pids+="${pids:+,}$pid"
  stat=$(</proc/$pid/stat)
  stat=${stat##*) }
  read -r _ pid _ <<<"$stat"
done
pids=$(reorder_session_pids "$pids")

report() {
  local id=$1 state=$2
  [[ -n $id && -n $state ]] || return 0
  log "report $state id=$id event=$event pids=$pids"
  remember "$id" "$state"
  send_agent "$id" "$state" "$pids"
}

case "$event" in
  UserPromptSubmit|PreToolUse|PostToolUse)
    [[ $event == UserPromptSubmit ]] && mark_turn "$session" working
    report "$session" working
    ;;
  SubagentStop)
    # Subagents share the parent's session_id. Background subagents often
    # stop after the parent's Stop, so only re-assert an ongoing turn:
    # never turn done back into working.
    if last_is "$session" working; then
      report "$session" working
    else
      log "skip SubagentStop after done session=$session"
    fi
    ;;
  Notification)
    if [[ $ntype == permission_prompt ]]; then
      report "$session" waiting
      # The tool call it stopped on, else Claude Code's own message.
      ask=$("$HOME/.config/omarchy/bin/agent-ask" <"$ASK_DIR/$(safe_id "$session")" 2>/dev/null) || ask=""
      [[ -n $ask ]] || ask=$(jq -r '.message // ""' <<<"$input" 2>/dev/null)
      log "ask id=$session: $ask"
      [[ -n $ask ]] && omarchy-shell austraz.daybar ask "$session" "$ask" >/dev/null 2>&1 &
    else
      log "skip notification type=${ntype:-empty} session=$session"
    fi
    ;;
  Stop)
    report "$session" done
    summarize "$session"
    ;;
  SessionEnd)
    report "$session" end
    forget "$session"
    rm -f "$ASK_DIR/$(safe_id "$session")" "$SUMMARY_DIR/$(safe_id "$session")"
    ;;
  *)
    log "skip event=${event:-empty} session=$session"
    ;;
esac

exit 0
