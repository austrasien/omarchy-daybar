// Pure helpers for the day bar: which desks and windows the rail shows and
// where they go, the agents' states, desk ageing and renumbering. No QML
// here, so the logic can be checked with node.
// Agents, icons, desk ageing and compaction come from austraz.minimap.

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

function normalizeConfig(raw) {
  var c = raw && typeof raw === "object" ? raw : {}
  var rail = parseInt(c.railWidth, 10)
  return {
    visible: c.visible !== false,
    monitor: c.monitor ? String(c.monitor) : "",
    // 0 = automatic: the gap beside the windows.
    railWidth: isNaN(rail) ? 0 : clamp(rail, 4, 40),
    // Off while austraz.minimap still runs: only one plugin may renumber
    // the desks and drive the LEDs.
    autoCompact: c.autoCompact === true,
    leds: c.leds === true,
    iconOverrides: c.iconOverrides && typeof c.iconOverrides === "object" ? c.iconOverrides : {},
    hideFullscreen: Array.isArray(c.hideFullscreen) ? c.hideFullscreen.map(String) : []
  }
}

// Whether a window makes the bar step aside: fullscreen (not merely
// maximized) and either a game by its content type or a class in `patterns`.
function hidesBar(win, patterns) {
  if (!win || (win.fullscreen || 0) < 2) return false
  if (win.contentType === "game") return true
  for (var i = 0; i < patterns.length; i++) {
    try { if (new RegExp(patterns[i]).test(win.appId)) return true } catch (e) {}
  }
  return false
}

// Same model as Omarchy Spaces, so the day bar can replace it: reporters
// (coding-agent hooks and the like) send `agent <session> <state> <pids>`
// over IPC; pids run from the agent process up to init, and the nearest
// one that owns a window is the agent's window.

var AGENT_REPORT_STATES = { working: true, waiting: true, done: true, idle: true }
var AGENT_LIVE_STATES = { working: true, waiting: true }

function normalizeAddress(address) {
  return String(address || "").toLowerCase().replace(/^0x/, "")
}

function normalizeAgentState(state) {
  var value = String(state || "")
  return AGENT_REPORT_STATES[value] ? value : ""
}

function parsePids(csv) {
  return String(csv || "").split(",").map(function(v) { return Number(v) }).filter(function(n) { return n > 1 })
}

function agentWindowsByPid(windows) {
  var byPid = {}
  for (var w = 0; w < (windows || []).length; w++) {
    var pid = Number(windows[w].pid)
    if (!pid) continue
    if (!byPid[pid]) byPid[pid] = []
    byPid[pid].push(normalizeAddress(windows[w].address))
  }
  return byPid
}

// Windows showing an agent: its pinned window, or every window of its
// nearest ancestor pid when that is ambiguous (one terminal server, many
// windows).
function agentAddresses(agent, byPid) {
  var candidates = null
  for (var i = 0; i < agent.pids.length; i++) {
    if (byPid[agent.pids[i]]) { candidates = byPid[agent.pids[i]]; break }
  }
  if (!candidates) return []
  var pinned = normalizeAddress(agent.address)
  if (pinned && candidates.indexOf(pinned) !== -1) return [pinned]
  return candidates
}

function agentPinAddress(pids, windows, activeAddress) {
  var addresses = agentAddresses({ pids: pids }, agentWindowsByPid(windows))
  if (addresses.length === 1) return addresses[0]
  var active = normalizeAddress(activeAddress)
  return active && addresses.indexOf(active) !== -1 ? active : ""
}

// Strongest marker wins when several agents share one window.
var STATE_RANK = { waiting: 3, done: 2, working: 1 }

// { session: {state, pids, address} } → { normalizedAddress: state }
function agentWindowStates(agents, windows) {
  var byPid = agentWindowsByPid(windows)
  var out = {}
  for (var session in agents) {
    var agent = agents[session]
    var rank = STATE_RANK[agent.state] || 0
    if (!rank) continue
    var addresses = agentAddresses(agent, byPid)
    for (var c = 0; c < addresses.length; c++) {
      var address = addresses[c]
      if (!out[address] || STATE_RANK[out[address]] < rank) out[address] = agent.state
    }
  }
  return out
}

// Agent processes to check that they are still there.
function agentProcessIds(agents) {
  var out = []
  for (var session in agents) {
    var agent = agents[session]
    if (!agent) continue
    var pid = Number(agent.pids && agent.pids[0])
    if (pid > 1 && out.indexOf(pid) === -1) out.push(pid)
  }
  return out.sort(function(a, b) { return a - b })
}

// A crashed reporter never sends "end": drop the agents whose process died.
function pruneDeadAgents(agents, alivePids) {
  var alive = {}
  for (var i = 0; i < (alivePids || []).length; i++) alive[String(Number(alivePids[i]))] = true
  var pruned = false, out = {}
  for (var session in agents) {
    var agent = agents[session]
    var pid = Number(agent && agent.pids && agent.pids[0])
    if (agent && pid > 1 && !alive[String(pid)]) { pruned = true; continue }
    out[session] = agent
  }
  return pruned ? out : agents
}

// The desks from top to bottom: the scratchpad (negative id, it reads "0")
// first, then the numbered desks in order.
function deskOrder(a, b) {
  return (b.id < 0) - (a.id < 0) || a.id - b.id
}

// Windows of a desk from top to bottom: as they read on screen, left to
// right, then top to bottom.
function windowOrder(a, b) {
  var ax = a.at ? a.at[0] : 0, bx = b.at ? b.at[0] : 0
  var ay = a.at ? a.at[1] : 0, by = b.at ? b.at[1] : 0
  return ax - bx || ay - by || (a.address < b.address ? -1 : a.address > b.address ? 1 : 0)
}

// Cuts `total` px into n equal parts with `gap` px between them, on whole
// pixels, so the parts always end exactly at `total`.
function split(total, n, gap) {
  if (n <= 0) return []
  var g = gap || 0
  var each = Math.max(0, total - g * (n - 1)) / n
  var out = []
  for (var i = 0; i < n; i++) {
    var y = Math.round(i * (each + g))
    out.push({ y: y, height: Math.round(i * (each + g) + each) - y })
  }
  return out
}

// The rail, cut in equal parts between the desks, each desk in equal parts
// between its windows. A desk with more windows than fit shows the first
// ones and one last cell standing for the others ("+n").
// desks: [{ id, current, windows: [{ address, appId, icon }] }]
function deskLayout(desks, height, options) {
  var o = options || {}
  var minCell = o.minCell || 22
  var maxCells = o.maxCells || 12
  var cellGap = o.cellGap === undefined ? 1 : o.cellGap
  var parts = split(height, desks.length, o.gap === undefined ? 3 : o.gap)
  return desks.map(function(desk, d) {
    var part = parts[d]
    var fit = clamp(Math.floor((part.height + cellGap) / (minCell + cellGap)), 1, maxCells)
    var windows = desk.windows
    var shown = windows.length > fit ? fit - 1 : windows.length
    var cells = []
    for (var i = 0; i < shown; i++)
      cells.push({ more: false, address: windows[i].address, appId: windows[i].appId, icon: windows[i].icon || "" })
    if (windows.length > shown) {
      var rest = windows.slice(shown).map(function(w) { return w.address })
      cells.push({ more: true, address: "", appId: "", icon: "", count: rest.length, hidden: rest })
    }
    var cuts = split(part.height, cells.length, cellGap)
    cells.forEach(function(cell, c) { cell.y = cuts[c].y; cell.height = cuts[c].height })
    return { id: desk.id, label: desk.id < 0 ? "0" : String(desk.id), current: !!desk.current,
      count: windows.length, y: part.y, height: part.height, cells: cells }
  })
}

// The desk at height y on the rail; a y in the gap between two desks counts
// for the one above it.
function deskAt(layout, y) {
  var found = null
  for (var i = 0; i < layout.length; i++) if (layout[i].y <= y) found = layout[i]
  return found
}

// What each window shows: its agent's state, a Hyprland "urgent" window
// reading as a waiting agent.
function windowStates(markers, urgent) {
  var out = {}
  for (var address in markers) out[address] = markers[address]
  for (var key in urgent) if (urgent[key]) out[key] = "waiting"
  return out
}

// Position of a warning tag sweeping a cell, 0 at its top and 1 at its
// bottom, for a clock running from 0 to 2.
function sweep(clock) {
  var t = ((clock % 2) + 2) % 2
  return t <= 1 ? t : 2 - t
}

// The white bar of a working agent, for a clock running from 0 to 2: a tennis
// ball between two walls. It slows as it nears a wall; touching it, it stays
// there a moment, flattening and bulging, then springs out longer than it
// was and off the other way, settling as it flies. `at` is 0 at the top and 1 at the bottom, `scale` the
// factor of its height and `girth` the factor of its width.
function bounce(clock) {
  var t = ((clock % 2) + 2) % 2
  var down = t < 1
  var u = down ? t : t - 1
  var flight = 0.64
  var spring = 0.35   // how much longer than at rest it springs off a wall
  if (u < flight) {
    var v = u / flight
    // Steady in the middle, braking as it nears a wall and picking up off it.
    var pos = 0.4 * v + 0.6 * v * v * (3 - 2 * v)
    var settling = Math.max(0, 1 - v / 0.2)
    return { at: down ? pos : 1 - pos, scale: 1 + spring * settling, girth: 0.65 }
  }
  var q = (u - flight) / (1 - flight)
  var press = Math.sin(Math.PI * Math.min(q / 0.75, 1))
  var leaving = Math.max(0, (q - 0.75) / 0.25)
  return { at: down ? 1 : 0, scale: 1 - 0.8 * press + spring * leaving, girth: 0.65 + 0.35 * press }
}

// When a tag sweeping its window has reached the middle for good: the first
// time it goes through it after `minMs`.
function tagSweepEnd(oneWayMs, minMs) {
  return (Math.ceil(minMs / oneWayMs - 0.5) + 0.5) * oneWayMs
}

// A tag's place in its window, `elapsedMs` after it appeared: going up and
// down, then still in the middle, where it arrives on its own.
function tagSweep(elapsedMs, oneWayMs, minMs) {
  if (elapsedMs >= tagSweepEnd(oneWayMs, minMs)) return 0.5
  return sweep(Math.max(0, elapsedMs) / oneWayMs)
}

// Strongest agent state across a set of window addresses.
function strongestState(addresses, markers) {
  var best = ""
  for (var i = 0; i < addresses.length; i++) {
    var st = markers[addresses[i]]
    if (st && (!best || STATE_RANK[st] > STATE_RANK[best])) best = st
  }
  return best
}

// Desktop-entry ids to try for a window class, most specific first, as
// Spaces does: reverse-DNS ids often ship a file named after the last part.
function appIdCandidates(appId) {
  var id = String(appId || "")
  if (id === "") return []
  var out = [id]
  function add(v) { if (v && out.indexOf(v) === -1) out.push(v) }
  add(id.toLowerCase())
  add(id + ".desktop")
  add(id.toLowerCase() + ".desktop")
  var dot = id.lastIndexOf(".")
  if (dot > 0 && dot < id.length - 1) {
    add(id.slice(dot + 1))
    add(id.slice(dot + 1).toLowerCase())
  }
  return out
}

// Chromium-family --app windows use classes like
// "brave-chat.google.com__u_1_app_home-Default": host and path, so the
// launcher whose Exec opens that address can be found (as Spaces does).
function webAppHint(appId) {
  var m = /^(?:chrome|chromium|brave|msedge|vivaldi|helium|opera)-([^_]+?)__(.*?)-(?:Default|Profile_\d+)$/i.exec(String(appId || ""))
  if (!m) return null
  return { host: m[1], path: String(m[2] || "").replace(/_/g, "/").replace(/^\/+|\/+$/g, "") }
}

function scoreWebAppExec(exec, hint) {
  var text = String(exec || "")
  var needle = "//" + hint.host
  var at = text.indexOf(needle)
  if (at === -1) return -1
  var execPath = text.slice(at + needle.length).replace(/[?"'\s].*$/, "").replace(/^\/+/, "").replace(/\/+$/, "")
  if (hint.path) {
    if (execPath === hint.path || execPath.indexOf(hint.path + "/") === 0) return 1000 + execPath.length
    return -1
  }
  return 100 - Math.min(99, execPath.length)
}

// Index of the best launcher: same path first (keeps two accounts apart),
// else any launcher for the host, shorter paths first. -1 when none.
function bestWebAppExecIndex(execs, hint) {
  if (!hint || !execs || execs.length === 0) return -1
  function pick(h) {
    var best = -1, bestScore = -1
    for (var i = 0; i < execs.length; i++) {
      var score = scoreWebAppExec(execs[i], h)
      if (score > bestScore) { bestScore = score; best = i }
    }
    return bestScore >= 0 ? best : -1
  }
  var found = pick(hint)
  return found >= 0 || !hint.path ? found : pick({ host: hint.host, path: "" })
}

// Ordinary browser windows (not --app web apps) all share one class, so
// they show the current tab's favicon instead, as in Spaces.
var BROWSER_APP_IDS = {
  "brave-origin": true, "brave-browser": true, "brave-browser-stable": true, "brave": true,
  "chromium": true, "chromium-browser": true, "google-chrome": true, "google-chrome-stable": true,
  "helium": true
}

function isBrowserWindow(appId) {
  return !!BROWSER_APP_IDS[String(appId || "").toLowerCase()]
}

// Icon index helpers: an SVG beats any PNG, a bigger PNG beats a smaller.
function iconPathScore(path) {
  var p = String(path || "")
  if (/\.svg$/i.test(p)) return 100000
  var m = /\/(\d+)x\d+\//.exec(p)
  if (m) return Number(m[1])
  return /\/pixmaps\//.test(p) ? 48 : 1
}

function iconNameFromPath(path) {
  var value = String(path || "")
  var file = value.slice(value.lastIndexOf("/") + 1)
  var dot = file.lastIndexOf(".")
  return dot > 0 ? file.slice(0, dot) : file
}

// How dark an unvisited desk's arc gets, 0 (plain grey) to 1 (black):
// unchanged for 2 min, then quickly at first and slower after, black at 1 h.
function deskDarkness(idle) {
  if (!(idle > 120)) return 0
  if (idle >= 3600) return 1
  return Math.pow((idle - 120) / 3480, 0.6)
}

// Renumbering that closes the gaps between workspaces, like Super+Shift+
// Backspace on an empty desk: normal workspaces become 1..n in their order,
// persistent ones (a projector desk) keep their id and are skipped as
// targets, empty ones that still exist go after the occupied ones.
// `workspaces`: hyprctl workspaces -j. Returns [{ from, to }].
function compactionPlan(workspaces) {
  var fixed = {}, occupied = [], empty = []
  for (var i = 0; i < workspaces.length; i++) {
    var ws = workspaces[i]
    if (!(ws.id > 0) || String(ws.name || "").indexOf("special") === 0) continue
    if (ws.ispersistent) fixed[ws.id] = true
    else if (ws.windows > 0) occupied.push(ws.id)
    else empty.push(ws.id)
  }
  var num = function(a, b) { return a - b }
  occupied.sort(num)
  empty.sort(num)
  var order = occupied.concat(empty)
  var plan = [], next = 1
  for (var k = 0; k < order.length; k++) {
    while (fixed[next]) next++
    if (order[k] !== next) plan.push({ from: order[k], to: next })
    next++
  }
  return plan
}

// Fog of war: windows untouched for a while fade out, never below `floor`.
function fogOpacity(lastFocused, nowSec, floor) {
  if (!lastFocused) return floor
  var idle = nowSec - lastFocused
  if (idle < 600) return 1
  if (idle > 3600) return floor
  return 1 - (1 - floor) * (idle - 600) / 3000
}

// A turn can end while work carries on in the background (a shell Claude
// Code left running): the reporter says "done", no hook fires until it
// resumes. The agent process and its terminal are the first two pids.
var AGENT_RESTING_STATES = { done: true, idle: true }

function backgroundCandidates(agents) {
  var out = []
  for (var session in agents) {
    var agent = agents[session]
    if (!agent || !AGENT_RESTING_STATES[agent.state]) continue
    var pids = (agent.pids || []).slice(0, 2)
    for (var i = 0; i < pids.length; i++)
      if (pids[i] > 1 && out.indexOf(pids[i]) === -1) out.push(pids[i])
  }
  return out.sort(function(a, b) { return a - b })
}

// The agents as they should show: resting ones with background work count
// as working. `busy`: { pid: true }.
function withBackground(agents, busy) {
  var out = {}
  for (var session in agents) {
    var agent = agents[session]
    var working = agent && AGENT_RESTING_STATES[agent.state]
      && (agent.pids || []).slice(0, 2).some(function(p) { return busy[p] })
    out[session] = working ? { state: "working", pids: agent.pids, address: agent.address } : agent
  }
  return out
}

// From the top of the first waiting window to the bottom of the last one on
// the rail, or null. `layout`: deskLayout; `states`: { address: state }.
function waitingSpan(layout, states) {
  var top = -1, bottom = -1
  for (var d = 0; d < layout.length; d++) {
    var desk = layout[d]
    for (var c = 0; c < desk.cells.length; c++) {
      var cell = desk.cells[c]
      if (strongestState(cell.more ? cell.hidden : [cell.address], states) !== "waiting") continue
      if (top < 0) top = desk.y + cell.y
      bottom = desk.y + cell.y + cell.height
    }
  }
  return top < 0 ? null : { y: top, height: bottom - top }
}

// The windows of the desks on screen, the scratchpad when it is shown.
function currentAddresses(layout) {
  var out = {}
  layout.forEach(function(desk) {
    if (!desk.current) return
    desk.cells.forEach(function(cell) {
      if (cell.more) cell.hidden.forEach(function(a) { out[a] = true })
      else out[cell.address] = true
    })
  })
  return out
}

// A state tag lasts `ttl` ms from the moment a window's state changes, and
// ends for good once the window's desk is on screen; a window whose desk is
// on screen when its state changes gets none. { address: { state, until } }.
// Returns `tags` itself when nothing changed.
function updateTags(tags, states, onScreen, nowMs, ttl) {
  var next = {}, changed = false
  for (var address in states) {
    var prev = tags[address]
    var seen = !!onScreen[address]
    if (!prev || prev.state !== states[address]) {
      next[address] = { state: states[address], until: seen ? 0 : nowMs + ttl }
      changed = true
    } else if (seen && prev.until !== 0) {
      next[address] = { state: prev.state, until: 0 }
      changed = true
    } else {
      next[address] = prev
    }
  }
  for (var old in tags) if (!states[old]) changed = true
  return changed ? next : tags
}

// Claude Code, Claude Code Local and Forge terminals: their title says what
// the session is about.
function isClaudeWindow(appId) {
  return /^org\.omarchy\.agent\.(claude|claude-local|forge)$/.test(String(appId || ""))
}

// A window title without the spinner Claude Code puts in front of it.
function cleanTitle(title) {
  return String(title || "").replace(/^[\s*·•✳✶✻✽✢◐◑◒◓⠀-⣿]+/, "")
}

// The battery on its zone of the rail: the zone is a whole battery, filled
// to the current level, and ticks count the hours. Charging, in the part
// still empty: the hours to full. On battery, in the filled part: the hours
// left. Plugged in without charging, the zone is full and the ticks the hours
// it would last unplugged. b: { mode, seconds, percent }.
function batteryGauge(b, height) {
  var plugged = b.mode === "estimate"
  var filled = plugged ? height : clamp(b.percent / 100, 0, 1) * height
  var charging = b.mode === "charging"
  var start = charging ? filled : 0
  var span = charging ? height - filled : filled
  var hour = b.seconds > 0 ? span * 3600 / b.seconds : 0
  var ticks = []
  if (hour >= 4) for (var y = start + hour; y < start + span - 0.5; y += hour) ticks.push(Math.round(y))
  return { filled: filled, ticks: ticks, onFilled: !charging }
}

// The middle value of `values`, 0 when there are none.
function median(values) {
  if (!values.length) return 0
  var sorted = values.slice().sort(function(a, b) { return a - b })
  return sorted[Math.floor(sorted.length / 2)]
}

// UPower GetHistory("rate") as printed by gdbus: (time, watts, state)
// tuples, state 2 = discharging. Median discharge rate over the last
// `days`, in watts, or 0 when there is nothing to go on.
function dischargeRate(text, nowSec, days) {
  var re = /\((?:uint32 )?(\d+), ([\d.]+), (?:uint32 )?(\d+)\)/g
  var rates = [], m
  var since = nowSec - (days || 7) * 86400
  while ((m = re.exec(String(text || ""))) !== null) {
    var t = Number(m[1]), w = Number(m[2]), st = Number(m[3])
    if (st === 2 && t >= since && w > 0.5) rates.push(w)
  }
  if (rates.length === 0) return 0
  rates.sort(function(a, b) { return a - b })
  return rates[Math.floor(rates.length / 2)]
}

function durationText(seconds) {
  if (!(seconds > 0)) return ""
  var m = Math.round(seconds / 60)
  if (m < 60) return m + " min"
  var rest = m % 60
  return Math.floor(m / 60) + " h " + (rest < 10 ? "0" : "") + rest
}

// ISO times with microseconds, which Date.parse does not take. Epoch seconds.
function isoEpoch(iso) {
  var t = Date.parse(String(iso || "").replace(/(\.\d{3})\d+/, "$1"))
  return isNaN(t) ? 0 : t / 1000
}

// Claude's two weekly limits, as usage/claude.json has them: the week first
// (the bottom gauge), then the week's Fable share. used and forecast are
// shares of the limit, elapsed how much of the window has gone by (-1 when
// unknown), risk "full" when the limit would be hit before the reset.
var GAUGE_SPECS = [
  { key: "weekly", label: "7j", span: 7 * 86400, match: /^weekly/i },
  { key: "fable", label: "F", span: 7 * 86400, match: /fable/i }
]

function usageGauges(limits, nowSec) {
  return GAUGE_SPECS.map(function(spec) {
    var limit = null
    for (var j = 0; j < (limits || []).length; j++)
      if (spec.match.test(String(limits[j].label || ""))) { limit = limits[j]; break }
    if (!limit) return { key: spec.key, label: spec.label, known: false }
    var used = Math.max(0, Number(limit.percent) || 0)
    var f = limit.forecast || {}
    var forecast = Math.max(used, Number(f.mid) || used)
    var reset = isoEpoch(limit.resetsAt)
    var cap = isoEpoch(f.capAt)
    var full = used >= 1 || forecast >= 1 || (cap > 0 && (reset === 0 || cap < reset))
    return {
      key: spec.key, label: spec.label, known: true, used: used, forecast: forecast, reset: reset, cap: cap,
      elapsed: reset > 0 ? clamp(1 - (reset - nowSec) / spec.span, 0, 1) : -1,
      risk: full ? "full" : "ok",
      window: spec.key + "|" + String(limit.resetsAt || "")
    }
  })
}

// A gauge's hue: green (1/3) up to a 70 % forecast, then on to red (0) at 100 %.
function gaugeHue(gauge) {
  var t = gauge.risk === "full" ? 1 : clamp((gauge.forecast - 0.7) / 0.3, 0, 1)
  return (1 - t) / 3
}

// Battery details, as in austraz.power.
var CPU_BAR_COLORS = ["#5aa8ff", "#ff7a59", "#3dd68c", "#e0c35a", "#c084fc"]

function parseTopCpu(raw, limit) {
  var max = Math.max(1, Number(limit) || 5)
  var lines = String(raw || "").split("\n")
  var byName = ({})
  var order = []

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var cpu = NaN
    var name = ""
    var m = line.match(/^(\d+(?:\.\d+)?)\s+(\S+)\s+(.+)$/)
    if (m) {
      cpu = Number(m[1])
      name = m[3].trim()
    } else {
      m = line.match(/^(\d+(?:\.\d+)?)\s+(.+)$/)
      if (!m) continue
      cpu = Number(m[1])
      name = m[2].trim()
    }
    if (!name || !isFinite(cpu) || cpu < 0) continue

    if (!byName[name]) {
      byName[name] = { name: name, cpu: 0, pids: 0 }
      order.push(name)
    }
    byName[name].cpu += cpu
    byName[name].pids += 1
  }

  var merged = []
  for (var j = 0; j < order.length; j++) merged.push(byName[order[j]])
  merged.sort(function(a, b) { return b.cpu - a.cpu })

  var out = []
  for (var k = 0; k < merged.length && out.length < max; k++) {
    out.push({
      name: merged[k].name,
      cpu: merged[k].cpu,
      pid: "",
      pids: merged[k].pids
    })
  }
  return out
}

function cpuBarSegments(topCpu, colors) {
  var list = Array.isArray(topCpu) ? topCpu : []
  var palette = Array.isArray(colors) && colors.length > 0 ? colors : CPU_BAR_COLORS
  var total = 0
  var i
  for (i = 0; i < list.length; i++) {
    var cpu = Number(list[i] && list[i].cpu)
    if (isFinite(cpu) && cpu > 0) total += cpu
  }
  if (!(total > 0)) total = 1

  var out = []
  for (i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    var value = Number(entry.cpu)
    if (!isFinite(value) || value < 0) value = 0
    var pids = Number(entry.pids)
    if (!isFinite(pids) || pids < 1) pids = 1
    out.push({
      name: String(entry.name || "—"),
      pid: String(entry.pid || ""),
      pids: pids,
      cpu: value,
      share: value / total,
      color: palette[i % palette.length]
    })
  }
  return out
}

function pruneWattHistory(points, windowMs, nowMs) {
  var list = Array.isArray(points) ? points.slice() : []
  var window = Math.max(1000, Number(windowMs) || 900000)
  var now = Number(nowMs)
  if (!isFinite(now) || now <= 0) now = Date.now()
  var cutoff = now - window
  while (list.length > 0 && Number(list[0].t) < cutoff) list.shift()
  return list
}

function parseWattHistory(raw, windowMs, nowMs) {
  var text = String(raw || "").trim()
  if (!text) return []
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return []
  }
  if (!Array.isArray(data)) return []
  var out = []
  for (var i = 0; i < data.length; i++) {
    var p = data[i]
    if (!p) continue
    var t = Number(p.t)
    var w = Number(p.watts)
    if (!isFinite(t) || t <= 0 || !isFinite(w) || w < 0) continue
    out.push({ t: t, watts: w })
  }
  out.sort(function(a, b) { return a.t - b.t })
  return pruneWattHistory(out, windowMs, nowMs)
}

function niceCeil(n) {
  var v = Number(n)
  if (!(v > 0) || !isFinite(v)) return 0
  var exp = Math.pow(10, Math.floor(Math.log(v) / Math.LN10))
  var nice = Math.ceil(v / exp)
  if (nice <= 1) nice = 1
  else if (nice <= 2) nice = 2
  else if (nice <= 5) nice = 5
  else nice = 10
  return nice * exp
}

function wattExtent(points) {
  var list = Array.isArray(points) ? points : []
  var peak = 0
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p) continue
    var v = Number(p.watts)
    if (isFinite(v) && v > peak) peak = v
  }
  return { peak: peak, axis: peak > 0 ? niceCeil(peak) : 0 }
}

function trafficWindow(points, windowMs, nowMs) {
  var list = Array.isArray(points) ? points : []
  var now = Number(nowMs)
  if (!isFinite(now) || now <= 0) now = Date.now()
  var window = Math.max(1000, Number(windowMs) || 900000)
  var t1 = now
  var t0 = now - window
  if (list.length > 0) {
    var last = list[list.length - 1]
    if (last && Number(last.t) > t1) t1 = Number(last.t)
  }
  return { t0: t0, t1: t1 }
}

function formatWatts(n) {
  var v = Number(n)
  if (!isFinite(v) || v < 0) v = 0
  if (v >= 10) return Math.round(v) + "W"
  var rounded = Math.round(v * 10) / 10
  return String(rounded) + "W"
}

// Short token counts: 7.1B, 216M, 12K.
function tokenText(n) {
  var v = Number(n) || 0
  if (v >= 1e9) return (Math.round(v / 1e8) / 10) + "B"
  if (v >= 1e6) return Math.round(v / 1e6) + "M"
  if (v >= 1e3) return Math.round(v / 1e3) + "K"
  return String(Math.round(v))
}

function isoDay(date) {
  var pad = function(v) { return v < 10 ? "0" + v : String(v) }
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
}

// One bar per day for the last `span` days, oldest first, today last; days
// the history lacks count for nothing.
function historyBars(days, span, nowMs) {
  var byDate = {}
  ;(days || []).forEach(function(d) { byDate[String(d.date)] = Number(d.tokens) || 0 })
  var out = []
  var today = new Date(nowMs)
  for (var i = span - 1; i >= 0; i--) {
    var d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - i)
    var iso = isoDay(d)
    out.push({ date: iso, tokens: byDate[iso] || 0, today: i === 0 })
  }
  return out
}

// The battery's cycle count and health, from three lines of sysfs: cycle
// count, full capacity, design capacity.
function parseBatterySysfs(raw) {
  var lines = String(raw || "").trim().split("\n").map(function(l) { return l.trim() })
  var full = Number(lines[1])
  var design = Number(lines[2])
  return {
    cycles: lines[0] || "",
    health: full > 0 && design > 0 ? Math.max(0, Math.min(100, Math.round(100 * full / design))) : null
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseBatterySysfs: parseBatterySysfs,
    parseTopCpu: parseTopCpu,
    cpuBarSegments: cpuBarSegments,
    pruneWattHistory: pruneWattHistory,
    parseWattHistory: parseWattHistory,
    niceCeil: niceCeil,
    wattExtent: wattExtent,
    trafficWindow: trafficWindow,
    formatWatts: formatWatts,
    tokenText: tokenText,
    isoDay: isoDay,
    historyBars: historyBars,
    batteryGauge: batteryGauge,
    median: median,
    dischargeRate: dischargeRate,
    durationText: durationText,
    isoEpoch: isoEpoch,
    usageGauges: usageGauges,
    gaugeHue: gaugeHue,
    isClaudeWindow: isClaudeWindow,
    cleanTitle: cleanTitle,
    currentAddresses: currentAddresses,
    updateTags: updateTags,
    waitingSpan: waitingSpan,
    backgroundCandidates: backgroundCandidates,
    withBackground: withBackground,
    clamp: clamp,
    normalizeConfig: normalizeConfig,
    hidesBar: hidesBar,
    normalizeAddress: normalizeAddress,
    normalizeAgentState: normalizeAgentState,
    parsePids: parsePids,
    agentWindowsByPid: agentWindowsByPid,
    agentAddresses: agentAddresses,
    agentPinAddress: agentPinAddress,
    agentWindowStates: agentWindowStates,
    agentProcessIds: agentProcessIds,
    pruneDeadAgents: pruneDeadAgents,
    deskOrder: deskOrder,
    windowOrder: windowOrder,
    split: split,
    deskLayout: deskLayout,
    deskAt: deskAt,
    windowStates: windowStates,
    sweep: sweep,
    bounce: bounce,
    tagSweepEnd: tagSweepEnd,
    tagSweep: tagSweep,
    strongestState: strongestState,
    appIdCandidates: appIdCandidates,
    webAppHint: webAppHint,
    scoreWebAppExec: scoreWebAppExec,
    bestWebAppExecIndex: bestWebAppExecIndex,
    isBrowserWindow: isBrowserWindow,
    iconPathScore: iconPathScore,
    iconNameFromPath: iconNameFromPath,
    deskDarkness: deskDarkness,
    compactionPlan: compactionPlan,
    fogOpacity: fogOpacity,
    AGENT_LIVE_STATES: AGENT_LIVE_STATES
  }
}
