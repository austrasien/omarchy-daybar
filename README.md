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
  a tag sweeps its window for five seconds, then holds still in its middle, for
  five minutes in all or until you open that desk: the
  window's title for Claude Code, Claude Code Local and Forge, in green when
  finished and red when blocked; the desk and `DONE` or `WAIT` for the others.
- **Hold Super** to deploy the bar and see the desk numbers beside it.
- **Click** a window to focus it.
- **Drag** a window onto another desk to send it there; you stay where you are.
- A desk's outline darkens the longer it goes unvisited, and the
  icons of windows untouched for a while fade on the current desk.
- The **scratchpad** comes first, reading `0`, while it holds windows.
- A desk with too many windows ends in a `+n` cell.

## Agents

Any reporter that speaks Spaces' agent IPC works:

```sh
omarchy-shell austraz.daybar agent <session> <working|waiting|done|idle|end> <pid,pid,...>
```

- **Working**: a white bar goes up and down the window's cell from a random
  place.
- **Waiting**: a fast red blink; the cell grows out of the rail in a target
  frame, with a `WAIT` tag sweeping it. A Hyprland "urgent" window does the same.
- **Done**: a slow accent blink until you see the window or its desk, three
  quick blinks when it is already in view.

A Claude Code agent whose turn ended while a shell keeps running in the
background still counts as working (background subagents do not show this
way). Agent states survive a shell restart, until the next boot.

With Hyprland animations off, every marker holds still, except when the
call-mode plugin (`austraz.callmode`) is what turned them off. Claims whose agent
process died are dropped every minute.

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
| `autoCompact` | Renumber the desks 1..n whenever a gap appears. |
| `leds` | Drive the alert LEDs and the agents-live file. |
| `iconOverrides` | `{ "<window class>": "<icon name or path>" }`. |
| `hideFullscreen` | Window class regexes the bar hides over in fullscreen, on top of the windows that tell Hyprland they are games. |

`autoCompact` and `leds` are off by default: only one plugin may do these at
a time, so turn them on once austraz.minimap is gone.

## Commands

```sh
omarchy-shell austraz.daybar toggle       # show or hide
omarchy-shell austraz.daybar focusAlert   # go to the desk being signalled
omarchy-shell austraz.daybar showNumbers  # held Super (hideNumbers on release)
omarchy-shell austraz.daybar alerts       # the agents and the desk signalled, as JSON
omarchy-shell austraz.daybar peek on      # deploy without the pointer (peek off)
omarchy-shell austraz.daybar state        # what the rail holds, as JSON
omarchy-shell austraz.daybar snapshot /tmp/daybar.png
```

## Tests

```sh
node --test test/*.test.js
```

## Credits

`bin/alert-leds` and `bin/favicons.py` come from Omarchy Spaces (MIT, © Tornike
Gomareli).

## License

MIT
