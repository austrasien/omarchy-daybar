# Reporters

The scripts that feed the day bar's agent cards on the author's machine,
kept here as working examples of the `agent`, `summary`, `summarizing` and
`ask` commands. They are not loaded by the plugin; each one is linked into
place by hand.

| File | Linked as | What it does |
| --- | --- | --- |
| `spaces-agent.sh` | `~/.claude/hooks/spaces-agent.sh`, on every Claude Code hook event in `~/.claude/settings.json` | Reports each session's state. On a permission prompt, sends the tool call it stopped on (`ask`); at the end of a turn, starts `agent-summary`. |
| `agent-summary` | `~/.config/omarchy/bin/agent-summary` | Turns the agent's last reply into a sentence for its card. A reply of 30 words or less goes as it is; a longer one is summarised in the agent's own voice by a local model behind an OpenAI-compatible API (here Lemonade on the NPU, through a priority queue at `127.0.0.1:13306`, at background priority). A newer turn drops a late summary. |
| `notify-card` | called by the notification daemon (the author's clone of `omarchy.notifications`) for each notification it shows | Sends it to the bar as a message card (`notify`; the bar tells the daemon whether it made one, so a carded notification stays off the ticker), then its body through `agent-summary`: as it is when short, retold in a sentence when long. |
| `agent-ask` | `~/.config/omarchy/bin/agent-ask` | The tool call in one line (`$ git push`, `Edit ~/x.lua`), for both reporters. |
| `spaces-forge-watch` | `~/.config/omarchy/bin/spaces-forge-watch`, started per window by the Forge launcher | Claude Code in tmux on a remote host, over one long-lived ssh: a small monitor runs there and writes a line only when the state changes, with the turn's reply or tool call. |
| `hooks/spaces-forge-stamp-claude.py` | installed on the remote host by `spaces-forge-watch` | The remote Claude Code hook: writes the state stamps the monitor reads. |

Logs: `~/.local/state/omarchy/spaces-agent-hook.log`, `agent-summary.log`,
`spaces-forge-watch.log`.
