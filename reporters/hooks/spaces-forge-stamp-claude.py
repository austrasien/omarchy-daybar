#!/usr/bin/env python3
"""Claude Code hook on the persist host. Writes a stamp keyed by the tmux
session the hook runs in; the laptop watcher talks to Spaces. Does not
call omarchy-shell (wrong machine). Must stay silent on stdout."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

STAMP_DIR = Path.home() / ".local/state/spaces-forge/claude"
WORKING_EVENTS = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop"}
SOCK = os.environ.get("SPACES_FORGE_SOCK") or "claude-code"


def tmux_out(*args: str) -> str:
    try:
        return subprocess.check_output(
            ["tmux", *args], text=True, stderr=subprocess.DEVNULL, timeout=2
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def ppid_of(pid: int) -> int:
    try:
        stat = Path("/proc/%d/stat" % pid).read_text()
        return int(stat.rsplit(")", 1)[1].split()[1])
    except (OSError, IndexError, ValueError):
        return 0


def tmux_session() -> str:
    # Background agents (claude daemon / bg-pty-host) run outside tmux with no
    # $TMUX, but still descend from the pane's claude: walk up to a pane pid.
    panes = {}
    for line in tmux_out("-L", SOCK, "list-panes", "-a", "-F", "#{pane_pid}\t#{session_name}").splitlines():
        pid, _, name = line.partition("\t")
        if pid.isdigit() and name:
            panes[int(pid)] = name.strip()
    pid = os.getpid()
    for _ in range(32):
        if pid <= 1:
            break
        if pid in panes:
            return panes[pid]
        pid = ppid_of(pid)
    if os.environ.get("TMUX"):
        return tmux_out("display-message", "-p", "#{session_name}").strip()
    return ""


def main() -> int:
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        data = {}
    event = str(data.get("hook_event_name") or "")
    state = ""
    if event in WORKING_EVENTS:
        state = "working"
    elif event == "Notification":
        if data.get("notification_type") == "permission_prompt":
            state = "waiting"
    elif event == "Stop":
        state = "done"
    elif event == "SessionEnd":
        state = "end"
    if not state:
        return 0
    session = tmux_session()
    if not session or "/" in session:
        return 0
    STAMP_DIR.mkdir(parents=True, exist_ok=True)
    (STAMP_DIR / session).write_text("%s %d\n" % (state, int(time.time())), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
