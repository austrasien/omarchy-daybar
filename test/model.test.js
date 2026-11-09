// Checks for Model.js, the day bar's pure helpers: node --test test/*.test.js
const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

const win = (address, x = 0, y = 0) => ({ address, appId: "app", icon: "", at: [x, y] })

test("normalizeConfig: the shared duties stay off by default", () => {
  const c = Model.normalizeConfig({})
  assert.equal(c.visible, true)
  assert.equal(c.autoCompact, false)
  assert.equal(c.leds, false)
  assert.equal(c.railWidth, 0)
})

test("split: equal parts that end exactly at the total", () => {
  const parts = Model.split(100, 3, 2)
  assert.equal(parts.length, 3)
  assert.equal(parts[0].y, 0)
  const last = parts[2]
  assert.equal(last.y + last.height, 100)
  assert.ok(Math.abs(parts[0].height - parts[1].height) <= 1)
  assert.deepEqual(Model.split(100, 0, 2), [])
})

test("deskOrder: the scratchpad comes first", () => {
  const ids = [{ id: 3 }, { id: -98 }, { id: 1 }].sort(Model.deskOrder).map((d) => d.id)
  assert.deepEqual(ids, [-98, 1, 3])
})

test("windowOrder: left to right, then top to bottom", () => {
  const order = [win("c", 900, 0), win("b", 0, 500), win("a", 0, 0)].sort(Model.windowOrder).map((w) => w.address)
  assert.deepEqual(order, ["a", "b", "c"])
})

test("deskLayout: desks share the rail equally whatever their windows", () => {
  const layout = Model.deskLayout([
    { id: 1, windows: [win("a")] },
    { id: 2, windows: [win("b"), win("c"), win("d")] }
  ], 603, { gap: 3 })
  assert.equal(layout[0].height, 300)
  assert.equal(layout[1].height, 300)
  assert.equal(layout[1].y, 303)
  assert.equal(layout[1].cells.length, 3)
  assert.equal(layout[1].cells[2].y + layout[1].cells[2].height, 300)
})

test("deskLayout: a window opening only recuts its own desk", () => {
  const desks = (n) => [
    { id: 1, windows: [win("a")] },
    { id: 2, windows: Array.from({ length: n }, (_, i) => win("w" + i)) }
  ]
  const before = Model.deskLayout(desks(1), 600, {})
  const after = Model.deskLayout(desks(2), 600, {})
  assert.deepEqual(after[0], before[0])
  assert.equal(after[1].y, before[1].y)
})

test("deskLayout: too many windows end in a +n cell", () => {
  const windows = Array.from({ length: 6 }, (_, i) => win("w" + i))
  const [desk] = Model.deskLayout([{ id: 1, windows }], 69, { minCell: 22, cellGap: 1 })
  assert.equal(desk.cells.length, 3)
  const more = desk.cells[2]
  assert.equal(more.more, true)
  assert.equal(more.count, 4)
  assert.deepEqual(more.hidden, ["w2", "w3", "w4", "w5"])
})

test("deskLayout: an empty current desk has no cell, the scratchpad reads 0", () => {
  const layout = Model.deskLayout([{ id: -98, windows: [win("a")] }, { id: 2, current: true, windows: [] }], 200, {})
  assert.equal(layout[0].label, "0")
  assert.equal(layout[1].current, true)
  assert.deepEqual(layout[1].cells, [])
})

test("deskAt: finds the desk under a height, gaps go to the desk above", () => {
  const layout = [{ id: 1, y: 0 }, { id: 2, y: 303 }]
  assert.equal(Model.deskAt(layout, 10).id, 1)
  assert.equal(Model.deskAt(layout, 301).id, 1)
  assert.equal(Model.deskAt(layout, 303).id, 2)
})

test("windowStates: an urgent window reads as waiting", () => {
  assert.deepEqual(Model.windowStates({ a: "done", b: "working" }, { a: true }), { a: "waiting", b: "working" })
})

test("sweep: goes down then back up", () => {
  assert.equal(Model.sweep(0), 0)
  assert.equal(Model.sweep(1), 1)
  assert.equal(Model.sweep(1.5), 0.5)
  assert.equal(Model.sweep(2), 0)
})

test("agents: strongest state on a window, pinned window wins", () => {
  const windows = [{ address: "0xA", pid: 10 }, { address: "0xB", pid: 10 }]
  const agents = {
    s1: { state: "working", pids: [10], address: "b" },
    s2: { state: "waiting", pids: [10], address: "b" }
  }
  assert.deepEqual(Model.agentWindowStates(agents, windows), { b: "waiting" })
})

test("pruneDeadAgents: dead processes go, whatever their state", () => {
  const agents = { a: { state: "working", pids: [5] }, b: { state: "idle", pids: [6] }, c: { state: "done", pids: [7] } }
  assert.deepEqual(Object.keys(Model.pruneDeadAgents(agents, [7])), ["c"])
})

test("agentProcessIds: every agent, each process once", () => {
  const agents = { a: { state: "idle", pids: [9, 2] }, b: { state: "working", pids: [5] }, c: { state: "done", pids: [5] } }
  assert.deepEqual(Model.agentProcessIds(agents), [5, 9])
})

test("waitingSpan: from the first waiting window to the last, +n cells included", () => {
  const layout = [
    { y: 0, cells: [{ address: "a", y: 0, height: 100 }] },
    { y: 200, cells: [{ address: "b", y: 50, height: 50 }, { more: true, hidden: ["c", "d"], address: "", y: 101, height: 49 }] }
  ]
  assert.deepEqual(Model.waitingSpan(layout, { b: "waiting" }), { y: 250, height: 50 })
  assert.deepEqual(Model.waitingSpan(layout, { a: "waiting", d: "waiting" }), { y: 0, height: 350 })
  assert.equal(Model.waitingSpan(layout, { a: "working" }), null)
})

test("backgroundCandidates: only resting agents, first two pids", () => {
  const agents = {
    a: { state: "done", pids: [10, 11, 1081] },
    b: { state: "working", pids: [20, 21] },
    c: { state: "idle", pids: [11, 30] }
  }
  assert.deepEqual(Model.backgroundCandidates(agents), [10, 11, 30])
})

test("withBackground: a resting agent with a shell left running counts as working", () => {
  const agents = { a: { state: "done", pids: [10, 11], address: "x" }, b: { state: "done", pids: [20, 21] } }
  const out = Model.withBackground(agents, { 11: true })
  assert.equal(out.a.state, "working")
  assert.equal(out.a.address, "x")
  assert.equal(out.b.state, "done")
  assert.equal(agents.a.state, "done")
})

test("currentAddresses: the desks on screen, hidden windows and scratchpad included", () => {
  const layout = [
    { id: -98, current: true, cells: [{ address: "s" }] },
    { id: 1, current: false, cells: [{ address: "a" }] },
    { id: 2, current: true, cells: [{ address: "b" }, { more: true, hidden: ["c", "d"] }] }
  ]
  assert.deepEqual(Object.keys(Model.currentAddresses(layout)).sort(), ["b", "c", "d", "s"])
})

test("updateTags: five minutes from a state change, off screen", () => {
  const tags = Model.updateTags({}, { a: "done" }, {}, 1000, 300000)
  assert.deepEqual(tags, { a: { state: "done", until: 301000 } })
})

test("updateTags: no tag for a window on screen when it changes", () => {
  assert.equal(Model.updateTags({}, { a: "working" }, { a: true }, 1000, 300000).a.until, 0)
})

test("updateTags: opening the desk ends the tag for good", () => {
  const live = { a: { state: "done", until: 301000 } }
  const seen = Model.updateTags(live, { a: "done" }, { a: true }, 2000, 300000)
  assert.equal(seen.a.until, 0)
  assert.equal(Model.updateTags(seen, { a: "done" }, {}, 3000, 300000), seen)
})

test("isClaudeWindow: Claude Code, Local and Forge only", () => {
  for (const id of ["org.omarchy.agent.claude", "org.omarchy.agent.claude-local", "org.omarchy.agent.forge"])
    assert.equal(Model.isClaudeWindow(id), true)
  for (const id of ["org.omarchy.agent.cursor", "org.omarchy.agent", "foot", ""])
    assert.equal(Model.isClaudeWindow(id), false)
})

test("cleanTitle: drops the spinner, keeps the title", () => {
  assert.equal(Model.cleanTitle("✳ Widget HUD calendrier"), "Widget HUD calendrier")
  assert.equal(Model.cleanTitle("◑ Austraz.daybar, refonte"), "Austraz.daybar, refonte")
  assert.equal(Model.cleanTitle("⠐ Build"), "Build")
  assert.equal(Model.cleanTitle("Plain"), "Plain")
})

test("updateTags: leaving a desk does not bring back a seen done", () => {
  const seen = { a: { state: "done", until: 0 } }
  assert.equal(Model.updateTags(seen, { a: "done" }, {}, 1000, 300000), seen)
})

test("updateTags: a new state starts a new tag, a cleared one goes", () => {
  const live = { a: { state: "working", until: 5000 }, b: { state: "done", until: 5000 } }
  const next = Model.updateTags(live, { a: "done" }, {}, 9000, 300000)
  assert.deepEqual(next, { a: { state: "done", until: 309000 } })
})

test("updateTags: nothing changed, same object", () => {
  const live = { a: { state: "done", until: 5000 } }
  assert.equal(Model.updateTags(live, { a: "done" }, {}, 9000, 300000), live)
})

test("batteryGauge: charging, filled to the level, ticks in the empty part", () => {
  // 50 % at 400 px: 200 px empty for 2 h to full, one tick in the middle of it.
  const g = Model.batteryGauge({ mode: "charging", seconds: 7200, percent: 50 }, 400)
  assert.equal(g.filled, 200)
  assert.deepEqual(g.ticks, [300])
  assert.equal(g.onFilled, false)
})

test("batteryGauge: on battery, filled to the level, ticks in the filled part", () => {
  // 50 % at 600 px: 300 px filled for 3 h left.
  const g = Model.batteryGauge({ mode: "discharging", seconds: 10800, percent: 50 }, 600)
  assert.equal(g.filled, 300)
  assert.deepEqual(g.ticks, [100, 200])
  assert.equal(g.onFilled, true)
})

test("batteryGauge: plugged in, full, ticks for what it would last", () => {
  const g = Model.batteryGauge({ mode: "estimate", seconds: 21600, percent: 80 }, 600)
  assert.equal(g.filled, 600)
  assert.deepEqual(g.ticks, [100, 200, 300, 400, 500])
})

test("batteryGauge: no tick under an hour, nor without an estimate", () => {
  assert.deepEqual(Model.batteryGauge({ mode: "discharging", seconds: 720, percent: 5 }, 300).ticks, [])
  assert.deepEqual(Model.batteryGauge({ mode: "estimate", seconds: 0, percent: 100 }, 300).ticks, [])
})

test("median: the middle value, 0 for none", () => {
  assert.equal(Model.median([300, 100, 200]), 200)
  assert.equal(Model.median([]), 0)
})

test("dischargeRate: median of the discharging samples of the period", () => {
  const now = 1000000
  const text = "[(uint32 999000, 10.0, uint32 2), (999100, 20.0, 2), (999200, 90.0, 2), (999300, 50.0, 1), (10, 5.0, 2)]"
  assert.equal(Model.dischargeRate(text, now, 7), 20)
  assert.equal(Model.dischargeRate("", now, 7), 0)
})

test("durationText", () => {
  assert.equal(Model.durationText(0), "")
  assert.equal(Model.durationText(600), "10 min")
  assert.equal(Model.durationText(3900), "1 h 05")
})

test("usageGauges: week first, then Fable, read from the limits", () => {
  const limits = [
    { label: "Fable Weekly", percent: 0.96, resetsAt: "2026-11-11T20:00:00.348484+00:00", forecast: { mid: 1.2, capAt: "2026-11-10T03:10:53.819628+00:00" } },
    { label: "Weekly (7-day)", percent: 0.72, resetsAt: "2026-11-11T20:00:00.348312+00:00", forecast: { mid: 0.9476, capAt: "" } }
  ]
  const reset = Date.parse("2026-11-11T20:00:00.348Z") / 1000
  const [week, fable] = Model.usageGauges(limits, reset - 2 * 86400)
  assert.equal(week.key, "weekly")
  assert.equal(week.used, 0.72)
  assert.equal(week.risk, "ok")
  assert.ok(Math.abs(week.elapsed - 5 / 7) < 1e-6)
  assert.equal(fable.key, "fable")
  assert.equal(fable.risk, "full")
  assert.ok(fable.cap > 0)
})

test("usageGauges: a limit the file lacks is unknown", () => {
  assert.deepEqual(Model.usageGauges([], 0).map((g) => g.known), [false, false])
})

test("usageGauges: forecast never below what is used", () => {
  const [week] = Model.usageGauges([{ label: "Weekly", percent: 0.5, forecast: { mid: 0.2 } }], 0)
  assert.equal(week.forecast, 0.5)
  assert.equal(week.elapsed, -1)
})

test("gaugeHue: green up to a 70 % forecast, red at 100 % or when full", () => {
  assert.equal(Model.gaugeHue({ forecast: 0.6, risk: "ok" }), 1 / 3)
  assert.equal(Model.gaugeHue({ forecast: 0.99, risk: "full" }), 0)
})

test("deskDarkness: grey for 2 min, black at 1 h", () => {
  assert.equal(Model.deskDarkness(60), 0)
  assert.equal(Model.deskDarkness(3600), 1)
})

test("compactionPlan: closes the gaps", () => {
  const plan = Model.compactionPlan([{ id: 1, name: "1", windows: 1 }, { id: 4, name: "4", windows: 2 }])
  assert.deepEqual(plan, [{ from: 4, to: 2 }])
})

test("parseBatterySysfs reads the cycles and the health", () => {
  assert.deepStrictEqual(Model.parseBatterySysfs("156\n3200000\n3572000\n"), { cycles: "156", health: 90 })
})

test("parseBatterySysfs has no health without both capacities", () => {
  assert.deepStrictEqual(Model.parseBatterySysfs("156\n"), { cycles: "156", health: null })
  assert.deepStrictEqual(Model.parseBatterySysfs(""), { cycles: "", health: null })
})

test("parseTopCpu merges a process's instances and sorts them", () => {
  assert.deepStrictEqual(Model.parseTopCpu("10.0 12 brave\n5.0 13 brave\n20.5 14 foot\n", 5), [
    { name: "foot", cpu: 20.5, pid: "", pids: 1 },
    { name: "brave", cpu: 15, pid: "", pids: 2 }
  ])
})

test("parseTopCpu keeps the busiest and skips what it cannot read", () => {
  assert.deepStrictEqual(Model.parseTopCpu("1.0 1 a\n9.0 2 b\nnot a line\n", 1).map(p => p.name), ["b"])
  assert.deepStrictEqual(Model.parseTopCpu("", 5), [])
})

test("cpuBarSegments gives each its share and a colour", () => {
  const segments = Model.cpuBarSegments([{ name: "a", cpu: 30, pids: 1 }, { name: "b", cpu: 10, pids: 2 }], ["#111", "#222"])
  assert.deepStrictEqual(segments.map(s => s.share), [0.75, 0.25])
  assert.deepStrictEqual(segments.map(s => s.color), ["#111", "#222"])
  assert.deepStrictEqual(Model.cpuBarSegments(null), [])
})

test("parseWattHistory keeps valid points inside the window, oldest first", () => {
  const raw = JSON.stringify([{ t: 99000, watts: 7 }, { t: 95000, watts: 5 }, { t: 85000, watts: 9 }, { t: 96000, watts: "x" }])
  assert.deepStrictEqual(Model.parseWattHistory(raw, 10000, 100000), [{ t: 95000, watts: 5 }, { t: 99000, watts: 7 }])
})

test("parseWattHistory survives a bad file", () => {
  assert.deepStrictEqual(Model.parseWattHistory("{oops", 10000, 100000), [])
  assert.deepStrictEqual(Model.parseWattHistory("{}", 10000, 100000), [])
})

test("wattExtent rounds the axis up from the peak", () => {
  assert.deepStrictEqual(Model.wattExtent([{ watts: 12 }, { watts: 3 }]), { peak: 12, axis: 20 })
  assert.deepStrictEqual(Model.wattExtent([]), { peak: 0, axis: 0 })
})

test("trafficWindow ends now, or at a later last point", () => {
  assert.deepStrictEqual(Model.trafficWindow([], 10000, 50000), { t0: 40000, t1: 50000 })
  assert.deepStrictEqual(Model.trafficWindow([{ t: 52000 }], 10000, 50000), { t0: 40000, t1: 52000 })
})

test("formatWatts keeps one decimal only under 10 W", () => {
  assert.strictEqual(Model.formatWatts(12.4), "12W")
  assert.strictEqual(Model.formatWatts(9.14), "9.1W")
  assert.strictEqual(Model.formatWatts(-1), "0W")
})

test("tokenText shortens token counts", () => {
  assert.strictEqual(Model.tokenText(7.1e9), "7.1B")
  assert.strictEqual(Model.tokenText(216e6), "216M")
  assert.strictEqual(Model.tokenText(12345), "12K")
  assert.strictEqual(Model.tokenText(999), "999")
  assert.strictEqual(Model.tokenText(null), "0")
})

test("isoDay pads the month and the day", () => {
  assert.strictEqual(Model.isoDay(new Date(2026, 0, 5)), "2026-01-05")
})

test("historyBars has one bar a day, today last, missing days at zero", () => {
  const bars = Model.historyBars([{ date: "2026-11-09", tokens: 5 }, { date: "2026-11-07", tokens: 2 }], 3, new Date(2026, 10, 9, 12).getTime())
  assert.deepStrictEqual(bars, [
    { date: "2026-11-07", tokens: 2, today: false },
    { date: "2026-11-08", tokens: 0, today: false },
    { date: "2026-11-09", tokens: 5, today: true }
  ])
})

test("historyBars crosses a month", () => {
  assert.deepStrictEqual(Model.historyBars([], 2, new Date(2026, 2, 1, 12).getTime()).map(b => b.date), ["2026-02-28", "2026-03-01"])
})

test("the bar flies steadily, and flattens against the wall", () => {
  assert.equal(Model.bounce(0).at, 0)
  assert.equal(Model.bounce(0.375).at, 0.5)
  assert.equal(Model.bounce(0.1875).at, 0.25)
  assert.equal(Model.bounce(0.375).scale, 1)
  const press = Model.bounce(0.875)
  assert.equal(press.at, 1)
  assert.ok(Math.abs(press.scale - 0.3) < 1e-9)
  assert.ok(Math.abs(press.girth - 1) < 1e-9)
  assert.equal(Model.bounce(1.875).at, 0)
})

test("the bar's shape does not jump as it touches or leaves a wall", () => {
  assert.ok(Math.abs(Model.bounce(0.7499).scale - Model.bounce(0.7501).scale) < 0.01)
  assert.ok(Math.abs(Model.bounce(0.9999).scale - Model.bounce(1).scale) < 0.01)
  assert.ok(Math.abs(Model.bounce(0.9999).girth - Model.bounce(1).girth) < 0.01)
})

test("a tag ends its sweep by reaching the middle", () => {
  assert.equal(Model.tagSweepEnd(450, 5000), 5175)
  assert.equal(Model.tagSweep(0, 450, 5000), 0)
  assert.equal(Model.tagSweep(450, 450, 5000), 1)
  assert.ok(Math.abs(Model.tagSweep(5174, 450, 5000) - 0.5) < 0.01)
  assert.equal(Model.tagSweep(5175, 450, 5000), 0.5)
  assert.equal(Model.tagSweep(60000, 450, 5000), 0.5)
})

test("bounce wraps its clock", () => {
  assert.deepEqual(Model.bounce(2.5), Model.bounce(0.5))
  assert.deepEqual(Model.bounce(-0.5), Model.bounce(1.5))
})
