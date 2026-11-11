# Day bar

A HUD-style rail along the right edge of the Omarchy shell, the mirror of
[Day tape](https://github.com/austrasien/omarchy-daytape): the left edge shows
the time, this one the space.

- **At rest** only a thin rail shows, as wide as the gap beside your windows.
  It is cut in equal parts between the open desks, each desk in equal parts
  between its windows. The whole current desk is in a dim shade of the theme
  accent, the others are outlines.
- **Hover** and the window icons deploy in a wave from the pointer. Browser
  windows show their current tab's favicon.
- When an agent finishes or gets blocked on another desk or in the scratchpad,
  a card sweeps its window for a second and a half, then holds still in its middle, for
  five minutes, then stays with no background (its text only, clicks going
  through) until you open that desk: the window's title for Claude
  Code, Claude Code Local and Forge, in green when finished and red when blocked;
  the desk and `DONE` or `WAIT` for the others. **Click** the card to open that
  window on its desk; until then it covers what is under it.
- **Hold Super** to deploy the bar and see the desk numbers beside it.
- **Click** a window to focus it.
- **Drag** a window onto another desk to send it there; you stay where you are.
- A desk's outline darkens the longer it goes unvisited, and the
  icons of windows untouched for a while fade on the current desk.
- The **scratchpad** comes first, reading `0`, while it holds windows.
- A desk with too many windows ends in a `+n` cell.

## Battery and limits

The rail gives 60 % of its height to the desks, 20 % to the battery above them
and 20 % to Claude's limits below them. Hovering one of them shows its card,
opening as a target lock and closing the same way before the bar goes home: the
battery's details, power chart and busiest apps, or both of Claude's limits with
the last 90 days and tokens by day. A click opens the Power panel or My Agents.

The power chart and that click need the austraz.power plugin, which writes
`~/.local/state/omarchy/power/watt-history.json`; without it, the card has no
chart.

- **Battery**, filling from the top to the current level, ticks counting the
  hours. Its colour goes from red through orange and yellow to green with the level,
  charging or not. Charging, with the hours to full in the empty part.
  On battery, blinking at
  10 % or less, with the hours left in the filled part. Plugged in without
  charging, full and green, with the hours it would last if unplugged, from the
  median discharge rate of the last week.
- **Limits**: the week below, filling from its bottom up, and its Fable share
  above, filling from its top down. Each shows the share used, solid, then the forecast at the reset, pale, and a line
  for how much of the window has gone by. Green up to a 70 % forecast, then on
  to red at 100 %. A gauge turning red blinks. They read what
  My Agents writes in
  `~/.local/state/omarchy/agents/usage/claude.json`, and fade when it is older
  than 15 minutes.

## Agents

Any reporter that speaks Spaces' agent IPC works:

```sh
omarchy-shell austraz.daybar agent <session> <working|waiting|done|idle|end> <pid,pid,...>
```

- **Working**: a white bar goes up and down the window's cell from a random
  place.
- **Waiting**: a fast red blink; the cell grows out of the rail in a target
  frame. A Hyprland "urgent" window does the same.
- **Done**: a slow accent blink until you see the window or its desk, three
  quick blinks when it is already in view.

A Claude Code agent whose turn ended while a shell keeps running in the
background still counts as working (background subagents do not show this
way). Agent states survive a shell restart, until the next boot.

With Hyprland animations off, every marker holds still, except when the
call-mode plugin (`austraz.callmode`) is what turned them off. Claims whose agent
process died are dropped every minute.

A reporter can add a one-line summary of the agent's last reply with
`summary <session> <text>` once the turn has ended: Claude Code, Claude Code
Local and Forge cards show it under the title. It is dropped when the next
turn starts, and ignored if the agent is no longer done. Announced first with
`summarizing <session>`, it keeps the card's reticle turning until it comes,
then types itself out under the title as the day tape's card does.

## Install

```sh
omarchy plugin add https://github.com/austrasien/omarchy-daybar.git --enable
```

After editing the QML, run `omarchy-restart-shell`: the panel is keepLoaded.

## Settings

`~/.config/omarchy/daybar.json`, all optional:

| Key | Meaning |
| --- | --- |
| `visible` | Show the bar. |
| `monitor` | Screen to stay on. Absent: the focused one. |
| `railWidth` | Width at rest, in pixels. Absent: the gap beside windows. |
| `verticalGap` | Gap above and below the windows, if a workspace rule makes it differ from `gaps_out`. |
| `autoCompact` | Renumber the desks 1..n whenever a gap appears. |
| `leds` | Drive the alert LEDs and the agents-live file. |
| `iconOverrides` | `{ "<window class>": "<icon name or path>" }`. |
| `hideFullscreen` | Window class regexes the bar hides over in fullscreen, on top of the windows that tell Hyprland they are games. |

`autoCompact` and `leds` are off by default: only one plugin may do these at
a time.

## Commands

```sh
omarchy-shell austraz.daybar toggle       # show or hide
omarchy-shell austraz.daybar focusAlert   # go to the desk being signalled
omarchy-shell austraz.daybar showNumbers  # held Super (hideNumbers on release)
omarchy-shell austraz.daybar summarizing <session>     # the card's reticle turns meanwhile
omarchy-shell austraz.daybar summary <session> <text>  # a line under the card's title ("" ends the wait)
omarchy-shell austraz.daybar alerts       # the agents and the desk signalled, as JSON
omarchy-shell austraz.daybar peek on      # deploy without the pointer (peek off)
omarchy-shell austraz.daybar state        # what the rail holds, as JSON
omarchy-shell austraz.daybar snapshot /tmp/daybar.png
omarchy-shell austraz.daybar snapshotCards /tmp/cards.png  # the cards alone
```

## Holding Super

Bind `showNumbers` to the press of Super and `hideNumbers` to its release, in
`~/.config/hypr/bindings.lua`. The release needs all four flags: a plain release
bind does not fire once another key was pressed, as in Super, 1, 2.

```lua
hl.unbind("SUPER_L")
o.bind("SUPER_L", "Show workspace numbers",
  hl.dsp.exec_cmd("omarchy-shell austraz.daybar showNumbers"),
  { non_consuming = true })
hl.unbind("SUPER + SUPER_L")
o.bind("SUPER + SUPER_L", "Hide workspace numbers",
  hl.dsp.exec_cmd("omarchy-shell austraz.daybar hideNumbers"),
  { release = true, transparent = true, ignore_mods = true, non_consuming = true })
```

Do the same for `SUPER_R` if you use it. A lost release closes the bar after
30 seconds without a move between desks.

## Tests

```sh
node --test test/*.test.js
```

## Credits

`bin/alert-leds` and `bin/favicons.py` come from Omarchy Spaces (MIT, © Tornike
Gomareli).

## License

MIT
