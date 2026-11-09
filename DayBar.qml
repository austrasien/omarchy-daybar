import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.UPower
import qs.Commons
import "Model.js" as Model

// A HUD rail along the right edge of the screen, the mirror of the day tape:
// the left edge shows the time, this one the space. The rail is cut in equal
// parts between the open desks, each desk in equal parts between its windows,
// and every window shows what its coding agent is doing. Hovering deploys
// the icons; a click goes there, a drag sends a window to another desk. The
// desk numbers show while Super is held.
//
// Settings are in ~/.config/omarchy/daybar.json (see the README).
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string configPath: home + "/.config/omarchy/daybar.json"
  function binPath(name) { return Qt.resolvedUrl("bin/" + name).toString().replace(/^[a-z]+:\/\//, "") }

  // ------------------------------------------------------------ config

  property var rawConfig: ({})
  readonly property var cfg: Model.normalizeConfig(rawConfig)
  onCfgChanged: {
    iconCache = ({})
    revision++
    if (cfg.autoCompact) compactDebounce.restart()
    if (cfg.leds) { ledSync.restart(); writeAgentsLive() }
  }

  function saveConfig(patch) {
    var next = Object.assign({}, rawConfig, patch)
    rawConfig = next
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.rawConfig = JSON.parse(text() || "{}") } catch (e) { console.warn("daybar: bad config", e) }
    }
  }

  // --------------------------------------------------------------- geometry

  // At rest only the rail shows, as wide as the gap beside the windows; the
  // numbers and icons slide out to stripWidth while the pointer is on it.
  readonly property int railWidth: cfg.railWidth || Math.max(8, Style.gapsOut * 2)
  // Wider only while tags show: their titles need the room, and the surface
  // is redrawn whole.
  readonly property int stripWidth: anyTagLive || deploy > 0 ? 360 : 84
  // The gauges start level with the top of the windows' top border and end
  // level with the bottom of their bottom one: the corners line up.
  readonly property real railInset: 0.8
  readonly property real railBottomInset: 0
  // The rail, top to bottom: battery 20 %, desks 60 %, Claude's limits 20 %.
  readonly property int zoneHeight: Math.round(strip.height * 0.2)
  readonly property real deskTop: railInset + zoneHeight + deskGap
  readonly property int deskGap: 6
  readonly property int railX: stripWidth - railWidth
  // The strip keeps its width for the warning tag and the numbers, but only
  // what the icons need deploys: edge, icon, rail.
  readonly property int deployWidth: 3 + 22 + 2 + railWidth
  readonly property int deployX: stripWidth - deployWidth
  readonly property int iconX: deployX + 3
  readonly property real backingWidth: railWidth + (deployWidth - railWidth) * deploySeg(0, 0.35)
  // The windows' cells grow with it, inside its edge, the icons in them.
  readonly property real cellWidth: backingWidth - 1 - 3 * deploySeg(0, 0.35)
  readonly property real iconCenterX: stripWidth - 1 - cellWidth / 2 - 11
  readonly property int edgeGap: Style.gapsOut * 2 + 2
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  function barSizeOn(name) { return shell && shell.bar && !shell.bar.barHidden ? shell.bar.barSizeFor(name) : 0 }
  readonly property int barSize: barSizeOn(targetScreen ? targetScreen.name : "")

  // [left, top, right, bottom] the bar and the like keep from the windows.
  // Read on each refresh, not bound: a binding on the monitors loops.
  property var reserved: [0, 0, 0, 0]
  // The scratchpad's state comes from there too, for after a shell restart:
  // Hyprland only sends an event when it changes.
  function syncMonitors() {
    var mons = Hyprland.monitors.values
    var special = false, known = false
    for (var i = 0; i < mons.length; i++) {
      var ipc = mons[i].lastIpcObject
      if (!ipc || !ipc.specialWorkspace) continue
      known = true
      if (String(ipc.specialWorkspace.name).indexOf("special:scratchpad") !== -1) special = true
      if (!targetScreen || mons[i].name !== targetScreen.name) continue
      var r = ipc.reserved
      if (r && r.length === 4 && JSON.stringify(r) !== JSON.stringify(reserved)) reserved = r
    }
    if (known && special !== scratchpadShown) scratchpadShown = special
  }

  readonly property var targetScreen: {
    var screens = Quickshell.screens
    var want = cfg.monitor || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    for (var i = 0; i < screens.length; i++) if (screens[i].name === want) return screens[i]
    return screens.length ? screens[0] : null
  }

  // ------------------------------------------------------------- motion

  // Markers and the deploy hold still when animations are off, but not for
  // call mode: the blinks must still show during a call (bin/callmode keeps
  // this file while it is the one holding animations off).
  property bool callModeHolds: false
  FileView {
    id: callModeFile
    path: root.home + "/.local/state/austraz-callmode/animations"
    printErrors: false
    onLoaded: root.callModeHolds = true
    onLoadFailed: root.callModeHolds = false
  }
  Timer {
    interval: 5000
    running: Style.reduceMotion
    repeat: true
    triggeredOnStart: true
    onTriggered: callModeFile.reload()
  }
  readonly property bool animate: !Style.reduceMotion || callModeHolds
  function dur(ms) { return animate ? ms : 0 }

  readonly property color hud: Color.accent
  // A real red whatever the theme: some themes' red is nearly white.
  readonly property color alarm: "#FF3030"
  readonly property color bright: Qt.tint(hud, Qt.alpha("#ffffff", 0.45))
  readonly property color dim: Qt.tint(Color.background, Qt.alpha(hud, 0.45))
  readonly property color hudBlack: Qt.darker(Color.background, 1.6)
  readonly property color nowColor: Color.background.hslLightness < 0.5 ? "#ffffff" : "#000000"
  readonly property color grey: Qt.tint(Qt.darker(Color.background, 1.15), Qt.alpha(Color.foreground, 0.3))

  function mixColor(a, b, k) {
    return Qt.rgba(a.r + (b.r - a.r) * k, a.g + (b.g - a.g) * k, a.b + (b.b - a.b) * k, a.a + (b.a - a.a) * k)
  }

  // ------------------------------------------------------------- windows

  property int revision: 0
  property var now: new Date()
  readonly property real nowSec: now.getTime() / 1000
  readonly property real startedAt: Date.now() / 1000
  Timer { interval: 15000; running: true; repeat: true; onTriggered: root.now = new Date() }

  // ------------------------------------------------------------- battery
  //
  // As on the minimap's rim. On battery: one stripe from now to the
  // estimated empty time. Charging: orange to full, then green for how long
  // a full charge would last. Plugged in and full: green for how long it
  // would last from now. The green runtimes use the median discharge rate of
  // the last week (UPower's rate history).

  readonly property var battery: UPower.displayDevice
  readonly property int batteryPercent: battery && battery.isPresent ? Math.round(Number(battery.percentage || 0) * 100) : -1
  readonly property bool charging: !!battery && battery.isPresent && !UPower.onBattery
    && battery.state === UPowerDeviceState.Charging
  readonly property string batteryMode: !battery || !battery.isPresent ? ""
    : UPower.onBattery ? "discharging" : charging ? "charging" : "estimate"
  readonly property real batterySeconds: batteryMode === "discharging" ? Number(battery.timeToEmpty || 0)
    : batteryMode === "charging" ? Number(battery.timeToFull || 0) : 0
  property real dischargeWatts: 0
  readonly property real batteryAfterSeconds: {
    if (dischargeWatts <= 0) return 0
    if (batteryMode === "charging") return Number(battery.energyCapacity || battery.energy || 0) / dischargeWatts * 3600
    if (batteryMode === "estimate") return Number(battery.energy || 0) / dischargeWatts * 3600
    return 0
  }
  readonly property bool batteryLow: batteryMode === "discharging" && batteryPercent >= 0 && batteryPercent < 10
  readonly property color batteryColor: batteryMode === "charging" ? "#ff9f43"
    : Qt.hsla(Math.min(Math.max(batteryPercent, 0), 100) / 100 / 3, 0.75, 0.5, 1)
  readonly property color runtimeColor: "#7fd88f"
  readonly property string batteryText: {
    if (batteryPercent < 0) return ""
    var parts = [batteryPercent + " %"]
    if (batteryMode === "discharging" && batterySeconds > 0) parts.push(Model.durationText(batterySeconds))
    if (batteryMode === "charging" && batterySeconds > 0) parts.push("plein " + Model.durationText(batterySeconds))
    if (batteryMode === "estimate" && batteryAfterSeconds > 0) parts.push(Model.durationText(batteryAfterSeconds))
    var watts = battery ? Math.abs(Number(battery.changeRate || 0)) : 0
    if (watts > 0.5) parts.push(Math.round(watts) + " W")
    return parts.join(" · ")
  }
  Process {
    id: rateProc
    command: ["sh", "-c", "gdbus call --system --dest org.freedesktop.UPower"
      + " --object-path \"$(upower -e | grep -m1 /battery_)\""
      + " --method org.freedesktop.UPower.Device.GetHistory rate 604800 4000"]
    stdout: StdioCollector {
      onStreamFinished: {
        var w = Model.dischargeRate(text, Date.now() / 1000, 7)
        if (w > 0) root.dischargeWatts = w
      }
    }
  }
  Timer {
    interval: 600000
    running: root.batteryMode === "estimate" || root.batteryMode === "charging"
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!rateProc.running) rateProc.running = true
  }
  property bool batteryBlinkOn: true
  Timer {
    interval: 500
    running: root.batteryLow && root.animate && win.visible
    repeat: true
    onRunningChanged: root.batteryBlinkOn = true
    onTriggered: root.batteryBlinkOn = !root.batteryBlinkOn
  }

  // ---------------------------------------------------------- AI limits
  //
  // Claude's two weekly limits, from what My Agents writes (usage/claude.json,
  // its `limits` and their `forecast`); nothing is fetched here. Data older
  // than 15 minutes fades the gauges and sends no alert.

  property var usageLimits: []
  property real usageUpdatedAt: 0
  readonly property bool usageStale: usageUpdatedAt > 0 && nowSec - usageUpdatedAt > 900
  readonly property var gauges: Model.usageGauges(usageLimits, nowSec)
  FileView {
    id: usageFile
    path: (Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state") + "/omarchy/agents/usage/claude.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var d = JSON.parse(String(text() || "{}"))
        root.usageLimits = Array.isArray(d.limits) ? d.limits : []
        root.usageUpdatedAt = Model.isoEpoch(d.updatedAt)
      } catch (e) {}
    }
  }
  // The file is replaced on every refresh, which can drop the watch.
  Timer { interval: 60000; running: true; repeat: true; onTriggered: usageFile.reload() }

  readonly property var weekDays: ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]
  function clockText(sec) {
    var d = new Date(sec * 1000)
    var hm = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
    return d.toDateString() === now.toDateString() ? hm : weekDays[d.getDay()] + " " + hm
  }
  function gaugeText(g) {
    if (!g || !g.known) return ""
    var head = g.label + " " + Math.round(g.used * 100) + " % → "
      + (g.risk === "full" && g.cap > 0 ? "plein " + clockText(g.cap) : Math.round(g.forecast * 100) + " %")
    return g.reset > 0 ? head + "\nreset " + clockText(g.reset) : head
  }

  // A gauge turning red blinks, once per window. Those already red when the
  // bar starts (a shell restart) stay quiet.
  property var gaugesTold: ({})
  property bool gaugesPrimed: false
  property int gaugeBlinkIndex: -1
  property real gaugeBlinkLevel: 1
  onGaugesChanged: {
    if (usageStale || !usageLimits.length) return
    var next = null
    for (var i = 0; i < gauges.length; i++) {
      var g = gauges[i]
      if (!g.known || g.risk !== "full" || gaugesTold[g.window]) continue
      if (!next) next = Object.assign({}, gaugesTold)
      next[g.window] = true
      if (gaugesPrimed && animate) { gaugeBlinkIndex = i; gaugeBlink.restart() }
    }
    if (next) gaugesTold = next
    gaugesPrimed = true
  }
  SequentialAnimation {
    id: gaugeBlink
    loops: 4
    NumberAnimation { target: root; property: "gaugeBlinkLevel"; to: 0.2; duration: 260 }
    NumberAnimation { target: root; property: "gaugeBlinkLevel"; to: 1; duration: 260 }
    onFinished: root.gaugeBlinkIndex = -1
  }

  property var lastFocus: ({})
  // { session: { state, pids, address } }, fed by the `agent` IPC call.
  property var agents: ({})
  property var urgentAddresses: ({})
  property bool scratchpadShown: false
  onScratchpadShownChanged: Qt.callLater(acknowledgeAgents)
  property bool numbersShown: false
  property string lastActiveEvent: ""

  function normalizeAddress(a) { return Model.normalizeAddress(a) }

  function ipcWindow(tl) {
    var ipc = tl.lastIpcObject || {}
    return {
      address: normalizeAddress(tl.address),
      appId: tl.wayland && tl.wayland.appId ? tl.wayland.appId : String(ipc["class"] || ""),
      fullscreen: Number(ipc.fullscreen) || 0,
      contentType: String(ipc.contentType || ""),
      at: ipc.at && ipc.at.length === 2 ? ipc.at : null,
      pid: Number(ipc.pid) || 0,
      workspace: ipc.workspace ? Number(ipc.workspace.id) : (tl.workspace ? tl.workspace.id : 0),
      scratchpad: !!(ipc.workspace && ipc.workspace.name === "special:scratchpad")
    }
  }

  readonly property var allWindows: {
    root.revision
    // Quickshell can keep a toplevel after its window is gone from the
    // desks: skip unmapped windows and windows whose workspace no longer
    // exists, or a ghost desk shows.
    var live = ({})
    var spaces = Hyprland.workspaces.values
    for (var s = 0; s < spaces.length; s++) live[spaces[s].id] = true
    var out = []
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var ipc = values[i].lastIpcObject || {}
      if (ipc.mapped === false) continue
      var w = ipcWindow(values[i])
      if (spaces.length && w.workspace !== 0 && !live[w.workspace]) continue
      out.push(w)
    }
    return out
  }

  readonly property int currentWorkspace: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  readonly property string focusedAddress: Hyprland.activeToplevel ? normalizeAddress(Hyprland.activeToplevel.address) : ""

  // A game in fullscreen on the current desk hides the bar, and so does
  // Omarchy's screensaver; other fullscreen windows keep it on top.
  readonly property bool gameHere: allWindows.some(function(w) {
    return w.workspace === root.currentWorkspace && Model.hidesBar(w, root.cfg.hideFullscreen)
  })
  readonly property bool screensaverUp: allWindows.some(function(w) { return w.appId === "org.omarchy.screensaver" })

  // When each desk was last left, kept across shell restarts.
  property var deskVisits: ({})
  property int previousWorkspace: -1
  onCurrentWorkspaceChanged: {
    var next = Object.assign({}, deskVisits)
    var t = Date.now() / 1000
    if (previousWorkspace !== -1) next[previousWorkspace] = t
    next[currentWorkspace] = t
    deskVisits = next
    previousWorkspace = currentWorkspace
    if (deskVisitsFile.loaded) deskVisitsFile.setText(JSON.stringify(next) + "\n")
    Qt.callLater(acknowledgeAgents)
  }
  FileView {
    id: deskVisitsFile
    property bool loaded: false
    path: root.home + "/.local/state/austraz-daybar/desks.json"
    printErrors: false
    atomicWrites: true
    onLoaded: {
      var saved = ({})
      try { saved = JSON.parse(text() || "{}") || ({}) } catch (e) {}
      root.deskVisits = Object.assign(saved, root.deskVisits)
      loaded = true
    }
    onLoadFailed: loaded = true
  }

  // --------------------------------------------------------------- icons
  //
  // Resolved as in the minimap and Spaces: desktop entry by id candidates,
  // by StartupWMClass, by Exec address for web apps, then Quickshell's
  // heuristic; the name goes through an index of the icon files on disk.

  property var iconCache: ({})
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property var faviconMap: ({})
  property int faviconMisses: 0

  function desktopEntryFor(appId) {
    var ids = Model.appIdCandidates(appId)
    for (var c = 0; c < ids.length; c++) {
      var byId = DesktopEntries.byId(ids[c])
      if (byId) return byId
    }
    var apps = DesktopEntries.applications.values
    for (var i = 0; i < apps.length; i++)
      if (String(apps[i].startupClass || "") === appId) return apps[i]
    var hint = Model.webAppHint(appId)
    if (hint) {
      var execs = []
      for (var j = 0; j < apps.length; j++) {
        var cmd = apps[j].command || []
        execs.push([String(apps[j].execString || "")].concat(Array.prototype.slice.call(cmd).map(String)).join(" "))
      }
      var at = Model.bestWebAppExecIndex(execs, hint)
      return at >= 0 ? apps[at] : null
    }
    return DesktopEntries.heuristicLookup(appId)
  }

  function iconUrl(name) {
    var value = String(name || "")
    if (value === "") return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    if (iconIndex[value]) return "file://" + iconIndex[value]
    return Quickshell.iconPath(value, true)
  }

  function appIcon(appId) {
    if (!appId) return ""
    if (iconCache[appId] !== undefined) return iconCache[appId]
    var forced = cfg.iconOverrides[appId]
    if (forced) return iconCache[appId] = iconUrl(forced)
    var entry = desktopEntryFor(appId)
    var url = iconUrl(entry && entry.icon ? entry.icon : appId)
    if (!url) url = iconUrl(appId.split(".").pop().toLowerCase())
    iconCache[appId] = url || ""
    return iconCache[appId]
  }

  readonly property string genericWindowIcon: {
    root.revision
    return iconUrl("application-x-executable") || iconUrl("utilities-terminal")
  }

  function windowIcon(win) {
    if (Model.isBrowserWindow(win.appId)) {
      var fav = faviconMap[win.address]
      if (fav && fav.source) return iconUrl(fav.source)
    }
    return appIcon(win.appId) || genericWindowIcon
  }

  Process {
    id: iconScan
    command: ["bash", "-c", [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for base in $dirs; do [[ -d $base ]] && find "$base" -path "*/apps/*" \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null; done;',
      'find /usr/share/pixmaps -maxdepth 1 \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null'
    ].join(" ")]
    stdout: SplitParser {
      onRead: function(line) {
        var path = String(line || "").trim()
        if (!path) return
        var name = Model.iconNameFromPath(path)
        var have = root.pendingIconIndex[name]
        if (!have || Model.iconPathScore(path) > Model.iconPathScore(have)) root.pendingIconIndex[name] = path
      }
    }
    onStarted: root.pendingIconIndex = ({})
    onExited: {
      root.iconIndex = root.pendingIconIndex
      root.iconCache = ({})
      root.revision++
    }
  }

  // Browser windows show their current tab's favicon (bin/favicons.py).
  Process {
    id: faviconQuery
    command: ["python3", root.binPath("favicons.py")]
    stdout: StdioCollector {
      onStreamFinished: {
        var data = ({})
        try { data = JSON.parse(String(text || "{}")) || ({}) } catch (e) {}
        root.faviconMap = data
        root.revision++
        // Chromium writes the favicon a moment after the title.
        var expected = 0, got = 0
        for (var i = 0; i < root.allWindows.length; i++) if (Model.isBrowserWindow(root.allWindows[i].appId)) expected++
        for (var k in data) if (data[k] && data[k].source) got++
        if (got < expected && root.faviconMisses < 3) { root.faviconMisses++; faviconRetry.restart() }
        else root.faviconMisses = 0
      }
    }
  }
  function isBrowserAddress(address) {
    var key = normalizeAddress(address)
    for (var i = 0; i < allWindows.length; i++)
      if (allWindows[i].address === key) return Model.isBrowserWindow(allWindows[i].appId)
    return false
  }
  function startFaviconQuery() { if (!faviconQuery.running) faviconQuery.running = true }
  Timer { id: faviconDebounce; interval: 180; onTriggered: { root.faviconMisses = 0; root.startFaviconQuery() } }
  Timer { id: faviconRetry; interval: 2000; onTriggered: root.startFaviconQuery() }
  Timer { interval: 400; running: true; onTriggered: root.startFaviconQuery() }
  Timer { id: iconRescan; interval: 1500; onTriggered: if (!iconScan.running) iconScan.running = true }
  Connections {
    target: DesktopEntries
    function onApplicationsChanged() { iconRescan.restart() }
  }
  Component.onCompleted: {
    iconScan.running = true
    syncLayout()
  }

  // -------------------------------------------------------------- agents

  // Kept across shell restarts, until the next boot: no reporter re-sends
  // a state that has not changed.
  onAgentsChanged: if (agentsFile.loaded) agentsFile.setText(JSON.stringify(agents) + "\n")
  FileView {
    id: agentsFile
    property bool loaded: false
    path: root.runtimeDir + "/austraz-daybar-agents.json"
    printErrors: false
    atomicWrites: true
    onLoaded: {
      var saved = ({})
      try { saved = JSON.parse(text() || "{}") || ({}) } catch (e) {}
      root.agents = Object.assign(saved, root.agents)
      loaded = true
    }
    onLoadFailed: loaded = true
  }

  // Claude Code shells still running once a turn has ended: children of
  // the agent, started from its shell snapshots.
  property var backgroundPids: ({})
  property var pendingBackground: ({})
  readonly property var backgroundWatch: Model.backgroundCandidates(agents)
  readonly property var effectiveAgents: Model.withBackground(agents, backgroundPids)
  Timer {
    interval: 3000
    running: root.backgroundWatch.length > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (backgroundProbe.running) return
      root.pendingBackground = ({})
      // Shell builtins for the children, one grep per agent that has some.
      backgroundProbe.command = ["sh", "-c", 'for p in "$@"; do f=""; for t in /proc/$p/task/*/children; do x=""; '
        + 'read -r x <"$t" 2>/dev/null; for k in $x; do f="$f /proc/$k/cmdline"; done; done; '
        + '[ -n "$f" ] && grep -qas shell-snapshots/snapshot- $f && echo $p; done; echo probed', "sh"].concat(root.backgroundWatch.map(String))
      backgroundProbe.running = true
    }
  }
  Process {
    id: backgroundProbe
    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text !== "probed") { if (Number(text) > 1) root.pendingBackground[text] = true; return }
        if (JSON.stringify(root.pendingBackground) !== JSON.stringify(root.backgroundPids))
          root.backgroundPids = root.pendingBackground
      }
    }
  }

  readonly property var markers: {
    var m = Model.agentWindowStates(effectiveAgents, allWindows)
    // A finished turn always blinks a few times, even when seen at once.
    var t = flashClock
    for (var address in doneFlashes)
      if (doneFlashes[address] > t && !m[address]) m[address] = "done"
    return m
  }
  readonly property var states: Model.windowStates(markers, urgentAddresses)

  readonly property int doneFlashMs: 3 * 700
  property var doneFlashes: ({})
  property real flashClock: Date.now()
  readonly property bool flashing: Object.keys(doneFlashes).length > 0
  Timer {
    interval: 250
    running: root.flashing
    repeat: true
    onTriggered: {
      root.flashClock = Date.now()
      var next = ({})
      for (var a in root.doneFlashes) if (root.doneFlashes[a] > root.flashClock) next[a] = root.doneFlashes[a]
      if (Object.keys(next).length !== Object.keys(root.doneFlashes).length) root.doneFlashes = next
    }
  }
  function flashDone(agent) {
    var addresses = Model.agentAddresses(agent, Model.agentWindowsByPid(allWindows))
    if (!addresses.length) return
    var next = Object.assign({}, doneFlashes)
    var until = Date.now() + doneFlashMs
    for (var i = 0; i < addresses.length; i++) next[addresses[i]] = until
    flashClock = Date.now()
    doneFlashes = next
  }

  function agentInView(agent) {
    var addresses = Model.agentAddresses(agent, Model.agentWindowsByPid(allWindows))
    for (var i = 0; i < addresses.length; i++) {
      if (addresses[i] === focusedAddress) return true
      for (var w = 0; w < allWindows.length; w++) {
        var win = allWindows[w]
        if (win.address !== addresses[i]) continue
        if (win.workspace === currentWorkspace || (win.scratchpad && scratchpadShown)) return true
      }
    }
    return false
  }

  // Desk of an agent's window: the smallest numbered one, the scratchpad
  // only if nothing else.
  function smallerDesk(a, b) {
    if (!a) return b
    if (!b) return a
    if (a > 0 && b > 0) return a < b ? a : b
    if (a > 0) return a
    if (b > 0) return b
    return a > b ? a : b
  }
  function deskForAgent(agent) {
    var addresses = Model.agentAddresses(agent, Model.agentWindowsByPid(allWindows))
    var best = 0
    for (var i = 0; i < addresses.length; i++)
      for (var w = 0; w < allWindows.length; w++)
        if (allWindows[w].address === addresses[i] && allWindows[w].workspace !== 0) best = smallerDesk(best, allWindows[w].workspace)
    return best
  }

  // Alerts not in view: waiting first, then done.
  function alertDesk() {
    var waiting = 0, done = 0
    for (var k in effectiveAgents) {
      var agent = effectiveAgents[k]
      if (!agent || agentInView(agent)) continue
      var ws = deskForAgent(agent)
      if (!ws) continue
      if (agent.state === "waiting") waiting = smallerDesk(waiting, ws)
      else if (agent.state === "done") done = smallerDesk(done, ws)
    }
    return waiting || done
  }
  function focusAlert() {
    var id = alertDesk()
    if (!id) return false
    focusWorkspace(id)
    return true
  }

  // Caps Lock and the fingerprint ring (only with "leds": true).
  readonly property string ledMode: {
    root.revision
    var waiting = false, done = false
    for (var k in effectiveAgents) {
      var agent = effectiveAgents[k]
      if (!agent) continue
      if (!Model.agentAddresses(agent, Model.agentWindowsByPid(allWindows)).length) continue
      if (agentInView(agent)) continue
      if (agent.state === "waiting") waiting = true
      else if (agent.state === "done") done = true
    }
    return waiting ? "blink" : (done ? "on" : "off")
  }
  onLedModeChanged: if (cfg.leds) ledSync.restart()
  Timer {
    id: ledSync
    interval: 150
    onTriggered: Quickshell.execDetached([root.binPath("alert-leds"), root.ledMode])
  }

  // Read by framework-side-leds; the name is the minimap's on purpose.
  readonly property bool agentsLive: {
    root.revision
    for (var k in effectiveAgents) {
      var agent = effectiveAgents[k]
      if (agent && Model.AGENT_LIVE_STATES[agent.state] && deskForAgent(agent)) return true
    }
    return false
  }
  onAgentsLiveChanged: writeAgentsLive()
  function writeAgentsLive() { if (cfg.leds) agentsLiveFile.setText(agentsLive ? "1\n" : "0\n") }
  FileView {
    id: agentsLiveFile
    path: root.runtimeDir + "/austraz-minimap-agents-live"
    printErrors: false
    atomicWrites: true
  }

  function applyAgent(session, state, pidsCsv) {
    var next = ({})
    for (var k in agents) if (k !== session) next[k] = agents[k]
    if (state === "end") { agents = next; return }
    var reported = Model.normalizeAgentState(state)
    if (!reported) return
    var pids = Model.parsePids(pidsCsv)
    var prev = agents[session]
    // Keep the window the agent was pinned to while it still exists.
    var address = prev && prev.address ? prev.address : ""
    if (address && !allWindows.some(function(w) { return w.address === address })) address = ""
    if (!address) address = Model.agentPinAddress(pids, allWindows, focusedAddress)
    var agent = { state: reported, pids: pids, address: address }
    if (reported === "done" && !(prev && prev.state === "done")) flashDone(agent)
    if (reported === "done" && agentInView(agent)) agent.state = "idle"
    next[session] = agent
    agents = next
  }

  function acknowledgeAgents() {
    var changed = false, next = ({})
    for (var k in agents) {
      var agent = agents[k]
      if (agent.state === "done" && agentInView(agent)) {
        agent = { state: "idle", pids: agent.pids, address: agent.address }
        changed = true
      }
      next[k] = agent
    }
    if (changed) agents = next
  }

  function setUrgent(address, urgent) {
    var key = normalizeAddress(address)
    if (key === "" || (!!urgentAddresses[key]) === urgent) return
    var next = ({})
    for (var k in urgentAddresses) if (k !== key) next[k] = true
    if (urgent) next[key] = true
    urgentAddresses = next
  }

  // A crashed reporter never sends "end": once a minute, drop working or
  // waiting claims whose agent process is gone.
  property var liveAgentPids: ({})
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: {
      var pids = Model.agentProcessIds(root.agents)
      if (!pids.length || agentProbe.running) return
      root.liveAgentPids = ({})
      agentProbe.command = ["sh", "-c", "for p in \"$@\"; do [ -d /proc/$p ] && echo $p; done; echo probed", "sh"].concat(pids.map(String))
      agentProbe.running = true
    }
  }
  Process {
    id: agentProbe
    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text === "probed") root.agents = Model.pruneDeadAgents(root.agents, Object.keys(root.liveAgentPids))
        else if (Number(text) > 1) root.liveAgentPids[text] = true
      }
    }
  }

  // Blinks, on timers that only run while something blinks.
  readonly property bool anyWaiting: Object.keys(states).some(function(a) { return root.states[a] === "waiting" })
  readonly property bool anyDone: Object.keys(states).some(function(a) { return root.states[a] === "done" })
  property bool fastOn: true
  property bool slowOn: true
  Timer {
    interval: 220
    running: root.anyWaiting && root.animate
    repeat: true
    onRunningChanged: root.fastOn = true
    onTriggered: root.fastOn = !root.fastOn
  }
  Timer {
    interval: root.flashing ? 350 : 800
    running: root.anyDone && root.animate
    repeat: true
    onRunningChanged: root.slowOn = true
    onTriggered: root.slowOn = !root.slowOn
  }
  // A working agent shows by its white bar; with animations off its window
  // is filled in the dim green instead, so it still shows.
  readonly property bool anyWorking: Object.keys(states).some(function(a) { return root.states[a] === "working" })
  // State tags: five minutes from a window's change of state, until its
  // desk (or the scratchpad) is opened. Kept across shell restarts, and not
  // touched just after a start, while the windows and agents come back.
  readonly property int tagMs: 5 * 60000
  property var tags: ({})
  property real tagNow: Date.now()
  property bool tagsReady: false
  Timer { interval: 4000; running: true; onTriggered: { root.tagsReady = true; root.syncTags() } }
  readonly property bool anyTagLive: Object.keys(tags).some(function(a) { return root.tags[a].state !== "working" && root.tags[a].until > root.tagNow })
  // The toplevel's title is live, unlike the windows read on each refresh.
  function titleOf(address) {
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++)
      if (normalizeAddress(values[i].address) === address) return String(values[i].title || "")
    return ""
  }
  function tagOn(address) { var t = tags[address]; return !!t && t.until > tagNow }
  // A tag sweeps its window for its first seconds, then holds still to be read.
  readonly property int tagSweepMs: 5000
  function tagMoves(address) {
    var t = tags[address]
    return !!t && t.state !== "working" && t.until > 0 && tagNow < t.until - tagMs + tagSweepMs
  }
  readonly property bool anyTagMoving: Object.keys(tags).some(function(a) { return root.tagMoves(a) })
  function syncTags() {
    if (!tagsReady || !tagsFile.loaded) return
    var next = Model.updateTags(tags, states, Model.currentAddresses(layout), Date.now(), tagMs)
    if (next === tags) return
    tags = next
    tagNow = Date.now()
    tagsFile.setText(JSON.stringify(next) + "\n")
  }
  onStatesChanged: Qt.callLater(syncTags)
  onLayoutChanged: Qt.callLater(syncTags)
  Timer {
    interval: root.anyTagMoving ? 500 : 5000
    running: root.anyTagLive
    repeat: true
    onTriggered: root.tagNow = Date.now()
  }
  FileView {
    id: tagsFile
    property bool loaded: false
    path: root.runtimeDir + "/austraz-daybar-tags.json"
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try { root.tags = JSON.parse(text() || "{}") || ({}) } catch (e) {}
      loaded = true
    }
    onLoadFailed: loaded = true
  }

  // One clock for the white bars and the state tags, in steps: on a thin
  // rail 20 a second look smooth and cost far fewer redraws than an
  // animation at the display's rate. It runs 0 to 2: a bar goes down and
  // back up once.
  property real workClock: 0
  Timer {
    id: workTimer
    interval: 50
    running: (root.anyWorking || root.anyWaiting || root.anyTagMoving) && root.animate && win.visible
    repeat: true
    onTriggered: root.workClock = (Date.now() % 2400) / 1200
  }

  // ------------------------------------------------------------- actions

  function focusWorkspace(id) {
    // Hyprland here takes Lua dispatches (hl.dsp.*).
    var target = id < 0 ? "special:scratchpad" : String(id)
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + target + '" })')
  }
  function focusWindow(address) {
    Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + normalizeAddress(address) + '" })')
  }
  // Sends a window to another desk without following it.
  function moveWindow(address, workspace) {
    var target = workspace < 0 ? '"special:scratchpad"' : String(workspace)
    Hyprland.dispatch("hl.dsp.window.move({ workspace = " + target + ', window = "address:0x'
      + normalizeAddress(address) + '", follow = false })')
    refreshDebounce.restart()
  }

  function noteFocus() {
    var active = Hyprland.activeToplevel
    if (!active) return
    var next = Object.assign({}, lastFocus)
    next[normalizeAddress(active.address)] = Date.now() / 1000
    lastFocus = next
  }

  Timer {
    id: refreshDebounce
    interval: 120
    onTriggered: {
      Hyprland.refreshToplevels()
      Hyprland.refreshMonitors()
      root.revision++
      root.syncMonitors()
    }
  }
  // Windows move without a dedicated event (a neighbour opens, a split moves).
  Timer {
    interval: 10000
    running: win.visible
    repeat: true
    triggeredOnStart: true
    onTriggered: refreshDebounce.restart()
  }

  // Renumbers the desks 1..n (only with "autoCompact": true). Two passes
  // through temporary ids so no change hits a used id.
  Timer {
    id: compactDebounce
    interval: 400
    onTriggered: if (root.cfg.autoCompact && !compactQuery.running) compactQuery.running = true
  }
  Process {
    id: compactQuery
    command: ["hyprctl", "workspaces", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var list = []
        try { list = JSON.parse(String(text || "[]")) } catch (e) { return }
        if (!root.cfg.autoCompact) return
        var plan = Model.compactionPlan(list)
        if (!plan.length) return
        var i
        for (i = 0; i < plan.length; i++)
          Hyprland.dispatch("hl.dsp.workspace.change_id({ workspace = " + plan[i].from + ", id = " + (10000 + plan[i].from) + " })")
        for (i = 0; i < plan.length; i++)
          Hyprland.dispatch("hl.dsp.workspace.change_id({ workspace = " + (10000 + plan[i].from) + ", id = " + plan[i].to + " })")
        // Visit times follow their desk to its new number.
        var visits = Object.assign({}, root.deskVisits)
        for (i = 0; i < plan.length; i++) delete visits[plan[i].to]
        for (i = 0; i < plan.length; i++)
          if (root.deskVisits[plan[i].from] !== undefined) visits[plan[i].to] = root.deskVisits[plan[i].from]
        root.deskVisits = visits
        refreshDebounce.restart()
        compactSettle.restart()
      }
    }
  }
  // Hyprland sends no event when a workspace changes id.
  Timer {
    id: compactSettle
    interval: 350
    onTriggered: {
      Hyprland.refreshWorkspaces()
      refreshDebounce.restart()
    }
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.noteFocus(); Qt.callLater(root.acknowledgeAgents) }
    function onRawEvent(event) {
      if (root.cfg.autoCompact && ["closewindow", "movewindow", "movewindowv2", "destroyworkspace",
          "destroyworkspacev2", "workspace", "workspacev2"].indexOf(event.name) !== -1)
        compactDebounce.restart()
      switch (event.name) {
      case "urgent":
        root.setUrgent(event.data, true)
        break
      case "activewindowv2":
        // Re-sent on every title change: only a real focus change counts.
        if (event.data !== root.lastActiveEvent) root.keepSuperOpen()
        root.lastActiveEvent = event.data
        root.setUrgent(event.data, false)
        refreshDebounce.restart()
        break
      case "activespecial":
      case "activespecialv2":
        root.scratchpadShown = String(event.data).indexOf("special:scratchpad") !== -1
        refreshDebounce.restart()
        break
      case "closewindow":
        root.numbersShown = false
        root.setUrgent(event.data, false)
        refreshDebounce.restart()
        faviconDebounce.restart()
        break
      case "windowtitle":
      case "windowtitlev2":
        if (root.isBrowserAddress(String(event.data).split(",")[0])) faviconDebounce.restart()
        break
      case "openwindow":
        root.numbersShown = false
        faviconDebounce.restart()
        refreshDebounce.restart()
        break
      case "openlayer":
        // The Super release may never reach us after a Super+key chord.
        root.numbersShown = false
        break
      case "fullscreen":
        Hyprland.refreshWorkspaces()
        refreshDebounce.restart()
        break
      case "workspace":
      case "workspacev2":
        root.keepSuperOpen()
        refreshDebounce.restart()
        break
      case "movewindow":
      case "movewindowv2":
      case "changefloatingmode":
      case "focusedmon":
        refreshDebounce.restart()
        break
      }
    }
  }

  // -------------------------------------------------------------- layout

  // What a waiting window's frame draws past the rail.
  readonly property var warningZone: {
    var span = Model.waitingSpan(layout, states)
    return span ? { x: railX - 7, y: span.y + deskTop - 1, width: 7, height: span.height + 2 } : { x: 0, y: 0, width: 0, height: 0 }
  }

  readonly property var layoutNow: {
    root.revision
    var byId = ({})
    function desk(id) {
      if (!byId[id]) byId[id] = { id: id, current: id < 0 ? root.scratchpadShown : id === root.currentWorkspace, windows: [] }
      return byId[id]
    }
    for (var i = 0; i < allWindows.length; i++) {
      var w = allWindows[i]
      if (w.workspace === 0) continue
      if (w.workspace < 0 && !w.scratchpad) continue
      desk(w.workspace).windows.push({ address: w.address, appId: w.appId, at: w.at, icon: windowIcon(w) })
    }
    // The current desk shows even while it is empty.
    if (currentWorkspace > 0) desk(currentWorkspace)
    var list = Object.keys(byId).map(function(k) { return byId[k] }).sort(Model.deskOrder)
    list.forEach(function(d) { d.windows.sort(Model.windowOrder) })
    return Model.deskLayout(list, strip.height - 2 * deskTop, { gap: deskGap, cellGap: 2, minCell: 24, maxCells: 12 })
  }

  // Reassigned only when what the rail draws changed: the windows are
  // re-read every 2 s and on every title change. The delegates live in
  // slots that follow the index, so a desk reflowing slides instead of
  // being rebuilt, and a drag or a hover survives a change elsewhere.
  property var layout: []
  property string layoutKey: ""
  onLayoutNowChanged: syncLayout()
  function syncLayout() {
    var key = JSON.stringify(layoutNow)
    if (key === layoutKey) return
    layoutKey = key
    layout = layoutNow
    while (deskSlots.count < layout.length) deskSlots.append({ slot: deskSlots.count })
    while (deskSlots.count > layout.length) deskSlots.remove(deskSlots.count - 1)
  }
  ListModel { id: deskSlots }

  // -------------------------------------------------------------- deploy

  property bool dragged: false
  property string dragAddress: ""
  property string dragIcon: ""
  property int dragFrom: 0
  property point dragPoint: Qt.point(0, 0)
  readonly property var dragOver: dragAddress !== "" ? Model.deskAt(layout, dragPoint.y - deskTop) : null

  function startDrag(cell, deskId, point) {
    dragged = true
    dragAddress = cell.address
    dragIcon = cell.icon
    dragFrom = deskId
    dragPoint = point
  }
  function finishDrag() {
    var target = dragOver
    if (target && target.id !== dragFrom) moveWindow(dragAddress, target.id)
    dragAddress = ""
  }

  property bool peeking: false
  // Held Super deploys it too, after a moment: every Super+key shortcut
  // starts by pressing Super, and those must not make it flash.
  property bool superOpen: false
  onNumbersShownChanged: {
    if (numbersShown) { superDelay.restart(); superSafety.restart(); return }
    superDelay.stop()
    superSafety.stop()
    superOpen = false
  }
  // It stays open until Super is released, across moves between desks. A
  // lost release must not leave it open for good: it closes after a while
  // without a move.
  function keepSuperOpen() { if (numbersShown) superSafety.restart() }
  Timer { id: superSafety; interval: 30000; onTriggered: root.numbersShown = false }
  Timer { id: superDelay; interval: 180; onTriggered: root.superOpen = root.numbersShown }
  readonly property bool open: stripHover.hovered || dragAddress !== "" || peeking || superOpen

  // The numbers and icons deploy on one timeline, 0 to 1: the strip slides
  // out, then a wave leaves the pointer up and down the rail.
  property real deploy: 0
  property bool deployed: false
  property real originY: 0
  onOpenChanged: {
    if (!open) { closeDelay.restart(); return }
    closeDelay.stop()
    if (deployed) return
    deployed = true
    originY = stripHover.hovered ? stripHover.point.position.y : strip.height / 2
    retracting.stop()
    deploying.restart()
  }
  Timer {
    id: closeDelay
    interval: 150
    onTriggered: {
      root.deployed = false
      deploying.stop()
      retracting.restart()
    }
  }
  NumberAnimation { id: deploying; target: root; property: "deploy"; to: 1; duration: root.dur(520) }
  NumberAnimation { id: retracting; target: root; property: "deploy"; to: 0; duration: root.dur(420) }

  function deploySeg(a, b) {
    var p = Math.max(0, Math.min(1, (deploy - a) / (b - a)))
    return 1 - Math.pow(1 - p, 3)
  }
  function wave(y) {
    var a = 0.1 + Math.abs(y - originY) / Math.max(1, strip.height) * 0.5
    return deploySeg(a, a + 0.25)
  }

  // --------------------------------------------------------------- window

  PanelWindow {
    id: win
    screen: root.targetScreen
    visible: root.cfg.visible && root.targetScreen !== null && !root.gameHere && !root.screensaverUp
    color: "transparent"
    implicitWidth: root.stripWidth

    anchors { top: true; bottom: true; right: true }
    margins {
      // From the windows' top border to their bottom one, wherever the
      // reserved zones put them, so the strip's edge meets those borders.
      // One pixel more at the top: at a fractional scale, a row of the
      // border would otherwise show above the strip.
      top: root.reserved[1] + root.edgeGap - 3
      bottom: root.reserved[3] + root.edgeGap - 2
      right: root.barPosition === "right" ? root.barSize : 0
    }

    WlrLayershell.namespace: "austraz-daybar"
    // Stays on top of fullscreen windows, as the minimap did.
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: 0

    // At rest only the rail takes the pointer, with a warning's frame; its
    // tag leaves it to the windows underneath.
    mask: Region {
      item: root.deployed ? deployZone : rail
      Region { x: root.warningZone.x; y: root.warningZone.y; width: root.warningZone.width; height: root.warningZone.height }
    }

    Item {
      id: strip
      width: root.stripWidth
      height: parent.height

      HoverHandler { id: stripHover }

      Item { id: rail; x: root.railX; width: root.railWidth; height: parent.height }
      Item { id: deployZone; x: root.deployX; width: root.deployWidth; height: parent.height }

      Rectangle {
        anchors.right: parent.right
        width: root.backingWidth
        height: parent.height
        color: Color.background

        // Stands in for the window border it covers once deployed.
        Rectangle {
          visible: root.deploy > 0
          anchors.left: parent.left
          y: 1
          width: 2
          height: parent.height - 1
          color: root.deploy < 0.4 ? root.bright : root.hud
        }
      }

      Repeater {
        model: deskSlots

        delegate: Item {
          id: desk
          required property int index
          readonly property var info: root.layout[index] || null
          readonly property int deskId: info ? info.id : 0
          readonly property bool current: !!info && info.current
          readonly property real darkness: current ? 0
            : Model.deskDarkness(root.nowSec - (root.deskVisits[deskId] || root.startedAt))
          readonly property bool dropTarget: !!root.dragOver && root.dragOver.id === deskId && deskId !== root.dragFrom

          width: root.stripWidth
          y: info ? info.y + root.deskTop : 0
          height: info ? info.height : 0
          Behavior on y { NumberAnimation { duration: root.dur(260); easing.type: Easing.OutBack } }
          Behavior on height { NumberAnimation { duration: root.dur(260); easing.type: Easing.OutBack } }

          ListModel { id: cellSlots }
          function syncCells() {
            var n = info ? info.cells.length : 0
            while (cellSlots.count < n) cellSlots.append({ slot: cellSlots.count })
            while (cellSlots.count > n) cellSlots.remove(cellSlots.count - 1)
          }
          onInfoChanged: syncCells()
          Component.onCompleted: syncCells()

          // The tick between this desk and the one above, in the gap, across
          // the rail or the deployed strip.
          Rectangle {
            visible: desk.index > 0
            x: root.stripWidth - root.backingWidth
            y: -(root.deskGap + height) / 2
            width: root.backingWidth
            height: 2
            color: root.hud
          }

          // Held Super: the numbers beside the bar, opening with it.
          Rectangle {
            visible: root.superOpen
            x: root.stripWidth - root.backingWidth - width - 3
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            height: 18
            radius: 2
            color: root.hudBlack
            border.width: 1
            border.color: desk.current ? root.bright : root.hud

            Text {
              anchors.centerIn: parent
              text: desk.info ? desk.info.label : ""
              textFormat: Text.PlainText
              color: desk.current ? root.bright : root.hud
              font.family: Style.fontFamily
              font.pixelSize: 11
              font.bold: true
            }
          }

          // The current desk while it holds no window.
          Rectangle {
            visible: !!desk.info && desk.info.count === 0
            x: root.stripWidth - 1 - root.cellWidth
            width: root.cellWidth
            height: parent.height
            radius: 2
            color: "transparent"
            border.width: 1
            border.color: root.hud
          }

          // A window being dragged over this desk.
          Rectangle {
            visible: desk.dropTarget
            z: 3
            x: root.iconX - 1
            width: root.stripWidth - x
            height: parent.height
            color: Qt.alpha(root.hud, 0.18)
            border.width: 1
            border.color: root.bright
          }

          Repeater {
            model: cellSlots

            delegate: Item {
              id: cell
              required property int index
              readonly property var info: desk.info && desk.info.cells[index] ? desk.info.cells[index] : null
              readonly property bool more: !!info && info.more
              readonly property string agentState: !info ? ""
                : more ? Model.strongestState(info.hidden, root.states)
                : (root.states[info.address] || "")
              readonly property bool waiting: agentState === "waiting"
              readonly property bool done: agentState === "done"
              readonly property bool working: agentState === "working"
              readonly property string tagWord: waiting ? "WAIT" : done ? "DONE" : ""
              readonly property bool tagMoving: !!info
                && (more ? info.hidden.some(function(a) { return root.tagMoves(a) }) : root.tagMoves(info.address))
              readonly property string tagTitle: tagLive && tagWord !== "" && !more && Model.isClaudeWindow(info.appId)
                ? Model.cleanTitle(root.titleOf(info.address)) : ""
              readonly property bool tagLive: !desk.current && !!info
                && (more ? info.hidden.some(function(a) { return root.tagOn(a) }) : root.tagOn(info.address))
              // Where the white bar is on the clock, drawn anew at each start.
              property real barPhase: Math.random() * 2
              onWorkingChanged: if (working) barPhase = Math.random() * 2
              readonly property bool warning: waiting && root.deploy === 0
              readonly property bool hovered: pointer.containsMouse && root.dragAddress === ""
              readonly property real fog: desk.current && info && !more
                ? Model.fogOpacity(root.lastFocus[info.address] || root.startedAt, root.nowSec, 0.45) : 1

              width: root.stripWidth
              y: info ? info.y : 0
              height: info ? info.height : 0
              z: warning ? 2 : 1
              Behavior on y { NumberAnimation { duration: root.dur(260); easing.type: Easing.OutCubic } }
              Behavior on height { NumberAnimation { duration: root.dur(260); easing.type: Easing.OutCubic } }

              Rectangle {
                id: block
                anchors.right: parent.right
                anchors.rightMargin: 1
                width: cell.warning ? root.railWidth + 4 : root.cellWidth
                height: parent.height
                radius: 1
                clip: true
                color: cell.waiting ? (root.fastOn ? root.alarm : Qt.darker(root.alarm, 2.2))
                  : cell.done && !desk.current ? (root.slowOn ? root.hud : root.dim)
                  : cell.hovered ? root.dim
                  : cell.working && !desk.current && !workTimer.running ? root.dim
                  : desk.current ? root.dim
                  : "transparent"
                // The other desks are outlines, darkening as they age but
                // never down to the background, or they would vanish.
                border.width: cell.waiting || cell.done || cell.hovered || desk.current ? 0 : 1
                border.color: root.mixColor(root.grey, Qt.rgba(0, 0, 0, 1), desk.darkness * 0.6)

                // For a warning only: the deploy already moves it frame by frame.
                Behavior on width {
                  enabled: root.deploy === 0
                  NumberAnimation { duration: root.dur(120); easing.type: Easing.OutCubic }
                }

                // An agent at work: a white bar going up and down the cell,
                // from a random place.
                Rectangle {
                  visible: cell.working && workTimer.running
                  y: Model.sweep(root.workClock + cell.barPhase) * (block.height - height)
                  width: parent.width
                  height: 10
                  color: root.nowColor
                  opacity: 0.8
                }
              }

              // A waiting agent: a target frame and a tag sweeping the cell,
              // like the day tape's master caution.
              Rectangle {
                visible: cell.warning
                x: block.x - 2
                y: -1
                width: block.width + 3
                height: parent.height + 2
                radius: 2
                color: "transparent"
                border.width: 1
                border.color: root.fastOn ? root.alarm : root.nowColor
              }
              Rectangle {
                visible: cell.tagLive && cell.tagWord !== ""
                // Left of the desk's number when it shows, never over it.
                x: Math.max(0, Math.min(block.x, root.superOpen ? root.stripWidth - root.backingWidth - 21 : block.x) - width - 3)
                y: Math.max(0, cell.height - height) * (cell.tagMoving ? Model.sweep(root.workClock) : 0.5)
                width: tagText.width + 8
                height: Math.max(20, tagText.height + 4)
                radius: 2
                color: root.hudBlack
                border.width: 1
                border.color: cell.waiting ? root.alarm : root.hud

                Text {
                  id: tagText
                  anchors.centerIn: parent
                  width: Math.min(implicitWidth, 280)
                  wrapMode: Text.Wrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                  text: cell.tagTitle !== "" ? cell.tagTitle : (desk.info ? desk.info.label : "") + " " + cell.tagWord
                  textFormat: Text.PlainText
                  color: cell.waiting ? (cell.tagTitle !== "" || root.fastOn ? root.alarm : root.nowColor) : root.hud
                  font.family: Style.fontFamily
                  font.pixelSize: 13
                  font.bold: true
                }
              }

              Image {
                visible: root.deploy > 0 && !cell.more && cell.info !== null && cell.info.icon !== ""
                x: root.iconCenterX + (1 - opacity) * 8
                anchors.verticalCenter: parent.verticalCenter
                width: 22
                height: 22
                sourceSize: Qt.size(44, 44)
                asynchronous: true
                source: visible && cell.info ? cell.info.icon : ""
                opacity: root.wave(desk.y + cell.y + cell.height / 2) * Math.max(cell.fog, 0.6)
              }
              Text {
                visible: root.deploy > 0 && cell.more
                x: root.iconCenterX
                width: 22
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                opacity: root.wave(desk.y + cell.y + cell.height / 2)
                text: cell.more ? "+" + cell.info.count : ""
                textFormat: Text.PlainText
                color: root.bright
                font.family: Style.fontFamily
                font.pixelSize: 12
                font.bold: true
              }

              // A click goes to the window, a drag sends it to another desk.
              MouseArea {
                id: pointer
                property point pressedAt: Qt.point(0, 0)
                anchors.right: parent.right
                width: root.deployed ? root.stripWidth - root.iconX + 1 : cell.warning ? root.railWidth + 7 : root.railWidth
                height: parent.height
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.PointingHandCursor
                onPressed: function(mouse) {
                  root.dragged = false
                  pressedAt = Qt.point(mouse.x, mouse.y)
                }
                onPositionChanged: function(mouse) {
                  if (!pressed || !cell.info || cell.more) return
                  var point = mapToItem(strip, mouse.x, mouse.y)
                  if (root.dragAddress !== "") { root.dragPoint = point; return }
                  if (Math.hypot(mouse.x - pressedAt.x, mouse.y - pressedAt.y) >= 6)
                    root.startDrag(cell.info, desk.deskId, point)
                }
                onReleased: if (root.dragAddress !== "") root.finishDrag()
                onCanceled: root.dragAddress = ""
                onClicked: {
                  if (root.dragged || !cell.info) return
                  if (cell.more || desk.deskId < 0) root.focusWorkspace(desk.deskId)
                  else root.focusWindow(cell.info.address)
                }
              }
            }
          }
        }
      }

      // The battery, at the top: now is its top edge, its height a day.
      Item {
        id: batteryZone
        readonly property var stripes: Model.batteryStripes(root.batterySeconds, root.batteryAfterSeconds, height)
        visible: root.batteryMode !== ""
        y: root.railInset
        width: root.stripWidth
        height: root.zoneHeight

        ZoneTrack {}
        Rectangle {
          x: root.stripWidth - 1 - root.cellWidth
          width: root.cellWidth
          height: batteryZone.stripes.solid
          color: root.batteryColor
          opacity: root.batteryLow && !root.batteryBlinkOn ? 0.2 : 1
        }
        Rectangle {
          x: root.stripWidth - 1 - root.cellWidth
          y: batteryZone.stripes.solid
          width: root.cellWidth
          height: batteryZone.stripes.after
          color: root.runtimeColor
        }
        ZoneTag {
          text: root.batteryText
          ink: root.batteryMode === "charging" ? root.batteryColor : root.bright
          zoneY: batteryZone.y
          zoneHeight: batteryZone.height
        }
        ZoneClick { command: ["omarchy-shell", "austraz.power", "toggle"] }
      }

      // The ticks around the desks.
      Rectangle {
        x: root.stripWidth - root.backingWidth
        y: root.deskTop - (root.deskGap + height) / 2
        width: root.backingWidth
        height: 2
        color: root.hud
      }
      Rectangle {
        x: root.stripWidth - root.backingWidth
        y: strip.height - root.deskTop + (root.deskGap - height) / 2
        width: root.backingWidth
        height: 2
        color: root.hud
      }

      // Claude's limits, at the bottom: the week below, filling from its
      // bottom up, and Fable above it, filling from its top down.
      Item {
        id: aiZone
        readonly property real gaugeHeight: (height - root.deskGap) / 2
        visible: root.usageLimits.length > 0
        opacity: root.usageStale ? 0.4 : 1
        y: strip.height - root.railBottomInset - height
        width: root.stripWidth
        height: root.zoneHeight

        Repeater {
          model: 2
          delegate: Item {
            id: gauge
            required property int index
            readonly property var g: root.gauges[index] || ({ known: false })
            readonly property color ink: g.known ? Qt.hsla(Model.gaugeHue(g), 0.75, 0.5, 1) : root.dim
            readonly property real used: g.known ? Math.min(1, g.used) * height : 0
            readonly property real forecast: g.known ? Math.max(0, Math.min(1, g.forecast) - Math.min(1, g.used)) * height : 0
            readonly property bool fromTop: index === 1

            y: index === 0 ? aiZone.height - height : 0
            width: root.stripWidth
            height: aiZone.gaugeHeight
            opacity: root.gaugeBlinkIndex === index ? root.gaugeBlinkLevel : 1

            ZoneTrack {}
            // The forecast, pale, from the share used on.
            Rectangle {
              x: root.stripWidth - 1 - root.cellWidth
              y: gauge.fromTop ? gauge.used : gauge.height - gauge.used - gauge.forecast
              width: root.cellWidth
              height: gauge.forecast
              color: Qt.alpha(gauge.ink, 0.35)
            }
            Rectangle {
              x: root.stripWidth - 1 - root.cellWidth
              y: gauge.fromTop ? 0 : gauge.height - gauge.used
              width: root.cellWidth
              height: gauge.used
              color: Qt.alpha(gauge.ink, 0.85)
            }
            // How much of the window has gone by.
            Rectangle {
              visible: gauge.g.known && gauge.g.elapsed >= 0
              x: root.stripWidth - 1 - root.cellWidth
              y: (gauge.fromTop ? gauge.height * (gauge.g.elapsed || 0) : gauge.height - gauge.height * (gauge.g.elapsed || 0)) - 1
              width: root.cellWidth
              height: 2
              color: Color.foreground
            }
            ZoneTag {
              text: root.gaugeText(gauge.g)
              ink: gauge.ink
              zoneY: aiZone.y + gauge.y
              zoneHeight: gauge.height
            }
            ZoneClick { command: ["omarchy-shell", "omarchy.agents", "toggle"] }
          }
        }
        // The tick between the two limits.
        Rectangle {
          x: root.stripWidth - root.backingWidth
          y: aiZone.gaugeHeight + (root.deskGap - height) / 2
          width: root.backingWidth
          height: 2
          color: root.hud
        }
      }

      // The window being dragged, under the pointer.
      Image {
        visible: root.dragAddress !== ""
        z: 4
        x: Math.max(0, Math.min(root.stripWidth - width, root.dragPoint.x - width / 2))
        y: root.dragPoint.y - height / 2
        width: 26
        height: 26
        sourceSize: Qt.size(52, 52)
        source: root.dragIcon
      }
    }
  }

  // The empty part of a battery or limit gauge.
  component ZoneTrack: Rectangle {
    x: root.stripWidth - 1 - root.cellWidth
    width: root.cellWidth
    height: parent.height
    color: Qt.alpha(Color.foreground, 0.1)
  }

  // A gauge's values, beside the open bar.
  component ZoneTag: Rectangle {
    property string text: ""
    property color ink: root.bright
    property real zoneY: 0
    property real zoneHeight: 0
    visible: root.deploy > 0 && text !== ""
    opacity: root.wave(zoneY + zoneHeight / 2)
    x: root.stripWidth - root.backingWidth - width - 3
    y: (zoneHeight - height) / 2
    width: zoneText.implicitWidth + 10
    height: zoneText.implicitHeight + 6
    radius: 2
    color: root.hudBlack
    border.width: 1
    border.color: ink

    Text {
      id: zoneText
      anchors.centerIn: parent
      text: parent.text
      textFormat: Text.PlainText
      color: parent.ink
      font.family: Style.fontFamily
      font.pixelSize: 13
      font.bold: true
    }
  }

  // A click on a gauge opens its panel.
  component ZoneClick: MouseArea {
    property var command: []
    anchors.right: parent.right
    width: root.deployed ? root.deployWidth : root.railWidth
    height: parent.height
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached(command)
  }

  IpcHandler {
    target: "austraz.daybar"

    function show(): void { root.saveConfig({ visible: true }) }
    function hide(): void { root.saveConfig({ visible: false }) }
    function toggle(): void { root.saveConfig({ visible: !root.cfg.visible }) }
    function focusAlert(): string { return root.focusAlert() ? "ok" : "none" }
    function alerts(): string { return JSON.stringify({ leds: root.ledMode, desk: root.alertDesk(), agents: root.agents }) }
    function showNumbers(): void { root.numbersShown = true }
    function hideNumbers(): void { root.numbersShown = false }
    function agent(session: string, state: string, pids: string): void { root.applyAgent(session, state, pids) }
    function peek(on: string): void { root.peeking = on === "on" }
    function state(): string { return JSON.stringify({ layout: root.layout, states: root.states }) }
    function snapshot(path: string): void { strip.grabToImage(function(r) { r.saveToFile(path) }) }
  }
}
