import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Palette.js" as Palette

// Ombre: give any running terminal window its own look: a background
// tint, an Aether mood generated from a wallpaper, or a whole Omarchy theme,
// plus, in Ghostty, its own wallpaper. Looks are escape sequences written to
// the window's pty (OSC 4/10/11/12), so the program inside keeps running
// untouched. Wallpapers are a per-window Ghostty config file that the window
// reloads on SIGUSR2. The window border can follow the look, and pulses when
// an agent in that terminal finishes and waits for you.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "ekkostech.ombre"

  property bool opened: false
  property var terminals: []
  property int current: 0
  property string previewPty: ""
  property string previewWallpaperPty: ""
  property bool focusOnScan: false
  property bool rescan: false
  property var requests: []
  property var known: ({})   // pty -> {pid, look, wallpaper} set this session

  // Settings kept in ~/.config/omarchy/ombre.json.
  property bool borders: true
  property bool pulse: true
  // Ghostty windows fully opaque, so Omarchy's slight transparency doesn't let the desktop
  // show through a terminal's wallpaper. solidOriginal keeps each window's own values.
  property bool solid: true
  property var solidOriginal: ({})
  property bool solidLoaded: false
  property bool textShadow: false
  property var hiddenSources: []     // wallpaper paths hidden from the strips (files untouched)
  property bool showHidden: false
  property bool reshadowAll: false
  property real strength: Palette.DEFAULT_STRENGTH
  property bool withWallpaper: true
  property bool welcomed: false
  property bool configLoaded: false

  // Catalog of moods, themes and wallpapers, refreshed whenever the picker opens.
  property var catalog: ({ wallpaper: "", aether: false, ghostty: false, launcher: false, modes: [], wallpapers: [], themes: [], own: [] })
  property bool catalogLoaded: false
  property real catalogAt: 0
  property string tab: "moods"
  property string moodSource: ""
  property var moodCache: ({})
  property var moodQueue: []
  property string moodRunning: ""
  property string hoverText: ""
  property string setupMessage: ""
  property var pendingWallpaper: null
  property var reshowPtys: []

  // Needs-you pulse: windows whose agent finished (title went from a spinner to
  // ✳) or rang the bell, pulsing until they get focus.
  property var pulses: ({})        // address -> {started, color, look}
  property var agentStates: ({})   // address -> working | idle | other
  property var pendingPulses: []
  property string activeAddress: Hyprland.activeToplevel ? Hyprland.activeToplevel.address : ""
  readonly property bool pulsing: Object.keys(pulses).length > 0
  // Hyprland animates border colour changes itself when its "border"
  // animation is on; then two updates per cycle are enough. Otherwise the
  // colour is stepped at 8 fps.
  property bool borderAnimated: false
  property bool pulsePhase: false

  readonly property string home: Quickshell.env("HOME") || ""
  // State lives in the user's private runtime dir, or under the state dir;
  // never in /tmp, where another local user could pre-create it.
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR")
    || (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state"))) + "/ombre"
  readonly property string configFile:
    (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/omarchy/ombre.json"
  readonly property string pluginDir:
    decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

  property string fontFamily: Style.font.menuFamily
  readonly property color surface: Color.menu.background
  readonly property color text: Color.menu.text
  readonly property color muted: Util.alpha(Color.menu.text, 0.6)
  readonly property color subtle: Util.alpha(Color.menu.text, 0.14)
  readonly property color accent: Color.accent
  readonly property string themeBackground: String(Color.background)
  readonly property bool lightTheme: Palette.isLight(themeBackground)
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int pad: Style.spacing.panelPadding
  readonly property int gap: Style.space(12)
  readonly property int swatchSize: Style.space(18)
  readonly property int cardWidth: Style.space(264)
  readonly property int columns: Math.max(1, Math.min(terminals.length, 4))
  readonly property int contentWidth: Math.max(columns * cardWidth + (columns - 1) * gap, Style.space(820))

  readonly property var selectedTerm: current >= 0 && current < terminals.length ? terminals[current] : null
  readonly property bool selectedTakesWallpaper: selectedTerm !== null && selectedTerm.wallpaperReady
  readonly property var tabs: ["moods", "themes", "wallpapers", "default"]

  // What a newly opened terminal gets: none, auto (the least-used tint), or a
  // saved look with an optional wallpaper. Terminals already open when the
  // plugin starts are left alone.
  property var newDefault: ({ mode: "none", look: null, wallpaper: null })

  // Project rules: a terminal whose working folder is inside a rule's folder
  // gets that rule's look and wallpaper when first seen, and again whenever
  // it moves to a different project's folder. Manual changes stick until then.
  property var projects: []
  property var appliedProject: ({})   // address -> rule path last applied
  property var seen: ({})          // address -> true for terminals already handled
  property bool seenReady: false
  property int newWindowTries: 0
  property var awaiting: ({})     // addresses of new windows not yet seen in a scan
  property bool tabChosen: false
  readonly property var allMoodSources: {
    var out = []
    if (catalog.wallpaper) out.push(catalog.wallpaper)
    for (var i = 0; i < catalog.wallpapers.length; i++)
      if (out.indexOf(catalog.wallpapers[i]) < 0) out.push(catalog.wallpapers[i])
    return out
  }
  readonly property var moodSources: showHidden ? allMoodSources
    : allMoodSources.filter(function (p) { return hiddenSources.indexOf(p) < 0 })
  readonly property int hiddenCount: hiddenSources.length
  // Wallpapers to pick from: the current one, Aether's library, then each theme's.
  readonly property var wallpaperChoices: {
    var out = catalog.own.filter(Palette.isImagePath)
    root.allMoodSources.forEach(function (w) { if (Palette.isImagePath(w) && out.indexOf(w) < 0) out.push(w) })
    for (var i = 0; i < catalog.themes.length; i++) {
      var img = catalog.themes[i].image
      if (Palette.isImagePath(img) && out.indexOf(img) < 0) out.push(img)
    }
    if (!showHidden) out = out.filter(function (p) { return hiddenSources.indexOf(p) < 0 })
    return out
  }
  readonly property string activeMoodSource: moodSource || catalog.wallpaper
  readonly property var moods: moodCache[moodKey(activeMoodSource)] || []
  readonly property bool moodsLoading: moodRunning !== "" || moodQueue.length > 0

  // Why moods are unavailable, or "" when Aether is ready.
  readonly property string aetherBlocker: {
    if (!catalogLoaded || catalog.aether) return ""
    if (!catalog.aetherInstalled) return "Moods come from Aether, Omarchy's theme maker, which isn't installed. Get it with: omarchy pkg add aether"
    return "Moods need Aether 4 or newer (found " + (catalog.aetherVersion || "an unknown version") + "). Update with: omarchy update"
  }

  // Why the selected terminal can't take a wallpaper, or "" when it can.
  readonly property string wallpaperBlocker: {
    if (!catalogLoaded) return ""
    if (!catalog.ghostty) return "Wallpapers need Ghostty. Install it and make it your terminal with: omarchy install terminal ghostty"
    if (!catalog.launcher) return "Wallpapers need Ghostty windows opened through Ombre's launcher."
    if (!selectedTerm) return ""
    if (!selectedTerm.ghostty) return "This window is " + (selectedTerm.cls || "not Ghostty") + ". Wallpapers work in Ghostty windows; open one with Super+Return."
    if (!selectedTerm.wallpaperReady) return "This Ghostty window opened before wallpapers were set up. New Ghostty windows can take one."
    return ""
  }

  // ---- Shell lifecycle --------------------------------------------------
  function open(payloadJson) {
    root.opened = true
    root.focusOnScan = true
    root.hoverText = ""
    root.setupMessage = ""
    root.scan()
    // The catalog is cheap but forks a process per theme, so refresh it at most
    // once a minute; a theme change refreshes it right away.
    if (!root.catalogLoaded || Date.now() - root.catalogAt > 60000) root.loadCatalog()
    else if (root.catalog.aether) root.ensureMoods(root.activeMoodSource)
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.endPreview()
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- Scripting (omarchy-shell shell call <id> <method> <arg>) ---------
  // apply '{"value": V, "target": T, "strength": S}', or a bare value for the focused terminal.
  //   V: red | #203040 | next | reset | mood:fire | mood:fire@/path/wall.jpg | theme:tokyo-night
  //      | wallpaper:/path/wall.jpg | wallpaper:none
  //   T: focused | title:TEXT | pid:N | address:HEX | all
  function apply(arg) {
    var req
    try { req = JSON.parse(arg) } catch (e) { req = { value: String(arg || "").trim() } }
    if (!req || typeof req !== "object") return "error: bad request"
    var value = String(req.value || "")
    if (!root.validSpec(value)) return "error: unknown look " + value
    root.requests = root.requests.concat([{ value: value, target: String(req.target || "focused"),
                                            strength: Number(req.strength) || root.strength }])
    root.scan()
    return "ok"
  }

  // The terminals from the latest scan; also starts a fresh scan.
  function state(arg) {
    root.scan()
    return JSON.stringify({
      opened: root.opened,
      current: root.current,
      borders: root.borders,
      terminals: root.terminals.map(function (t) {
        return { pty: t.pty, pid: t.pid, address: "0x" + t.address, workspace: t.workspace,
                 title: t.title, kind: t.look ? t.look.kind : "", look: Palette.lookLabel(t.look),
                 wallpaper: t.wallpaper ? t.wallpaper.path : "", wallpaperReady: t.wallpaperReady }
      })
    })
  }

  // Moods, themes and wallpapers available to `apply`, and what's installed.
  // Also refreshes the catalog for the next call.
  function looks(arg) {
    root.loadCatalog()
    return JSON.stringify({
      moods: root.catalog.modes.map(function (m) { return m.id }),
      themes: root.catalog.themes.map(function (t) { return t.id }),
      wallpapers: root.wallpaperChoices,
      projects: root.projects.map(function (r) { return { path: r.path, look: root.ruleLabel(r) } }),
      wallpaper: root.catalog.wallpaper,
      aether: root.catalog.aether,
      aetherInstalled: root.catalog.aetherInstalled,
      aetherVersion: root.catalog.aetherVersion,
      ghostty: root.catalog.ghostty,
      launcher: root.catalog.launcher
    })
  }

  function setBorders(enabled) {
    root.borders = enabled === true || enabled === "true"
    root.saveConfig()
    root.reapply()
    return "ok"
  }

  // Text shadow is a Ghostty shader, so it travels with the wallpaper config.
  function setTextShadow(enabled) {
    root.textShadow = enabled === true || enabled === "true"
    root.saveConfig()
    root.reshadowAll = true
    root.scan()
    return "ok"
  }

  function shadowVariant(term) {
    if (!root.textShadow) return "-"
    var bg = (term && Palette.lookBackground(term.look, root.themeBackground)) || root.themeBackground
    return Palette.isLight(bg) ? "light" : "dark"
  }

  // Omarchy dims every window a little (0.985 focused, 0.96 not), which lets the desktop
  // show through a terminal's wallpaper. Solid makes Ghostty windows fully opaque; each
  // window's own values are recorded first, so turning it off puts them back exactly.
  function setSolid(enabled) {
    root.solid = enabled === true || enabled === "true"
    root.saveConfig()
    if (root.solid) root.reapply()
    else root.unsolidAll()
    return "ok"
  }

  function applySolid(list) {
    if (!root.solid || !root.solidLoaded || !root.configLoaded || solidReader.running) return
    var fresh = []
    for (var i = 0; i < list.length; i++)
      if (list[i].ghostty && /^[0-9a-f]+$/.test(list[i].address || "") && !root.solidOriginal[list[i].address]) fresh.push(list[i].address)
    if (fresh.length === 0) return
    solidReader.command = ["sh", "-c", 'for a; do printf "%s %s %s\\n" "$a" "$(hyprctl getprop "address:0x$a" opacity 2>/dev/null | head -n1)" "$(hyprctl getprop "address:0x$a" opacity_inactive 2>/dev/null | head -n1)"; done', "sh"].concat(fresh)
    solidReader.running = true
  }

  function onSolidRead(text) {
    var originals = Object.assign({}, root.solidOriginal), lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].trim().split(/\s+/), active = parseFloat(p[1]), inactive = parseFloat(p[2])
      if (p.length !== 3 || !(active > 0 && active <= 1 && inactive > 0 && inactive <= 1)) continue
      originals[p[0]] = [active, inactive]
      if (root.solid) Hyprland.dispatch(Palette.opacityPair(p[0], 1, 1))
    }
    root.solidOriginal = originals
    root.saveSolid()
  }

  function unsolidAll() {
    for (var addr in root.solidOriginal) {
      var o = root.solidOriginal[addr]
      Hyprland.dispatch(Palette.opacityPair(addr, o[0], o[1]))
    }
    root.solidOriginal = ({})
    root.saveSolid()
  }

  function onSolidState(text) {
    try {
      var saved = JSON.parse(text), clean = {}
      for (var addr in saved)
        if (/^[0-9a-f]+$/.test(addr) && Array.isArray(saved[addr]) && saved[addr].length === 2) clean[addr] = saved[addr].map(Number)
      root.solidOriginal = clean
    } catch (e) { }
    root.solidLoaded = true
    if (root.configLoaded && root.solid) root.reapply()
  }

  function saveSolid() {
    solidWriter.command = ["sh", "-c", 'umask 077; mkdir -p "$1" 2>/dev/null; [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && printf "%s\\n" "$2" > "$1/solid.json"', "sh", root.runtimeDir, JSON.stringify(root.solidOriginal)]
    solidWriter.running = true
  }

  function setPulse(enabled) {
    root.pulse = enabled === true || enabled === "true"
    root.saveConfig()
    if (!root.pulse) for (var addr in root.pulses) root.stopPulse(addr)
    return "ok"
  }

  function validSpec(v) {
    return v === "next" || v === "reset" || Palette.tintLook(v) !== null
      || /^mood:[a-z0-9-]+(@\/.+)?$/.test(v) || /^theme:[A-Za-z0-9._-]+$/.test(v)
      || v === "wallpaper:none" || (v.indexOf("wallpaper:") === 0 && Palette.isImagePath(v.slice(10)))
      || v === "pulse:now" || v === "pulse:stop"
      || v === "default:from" || v === "project:from"
      || v.indexOf("project:remove:/") === 0
      || (v.indexOf("default:") === 0 && v !== "default:next" && v !== "default:reset" && root.validSpec(v.slice(8)))
  }

  // A look for a spec, { wait: true } while its data loads, or { error }.
  function resolveSpec(spec) {
    if (spec === "reset") return { look: null }
    var tint = Palette.tintLook(spec)
    if (tint) return { look: tint }
    if (!root.catalogLoaded) { root.loadCatalog(); return { wait: true } }

    var m = spec.match(/^mood:([a-z0-9-]+)(?:@(\/.+))?$/)
    if (m) {
      if (!root.catalog.aether) return { error: "Aether is not installed" }
      var source = m[2] || root.catalog.wallpaper
      var list = root.moodCache[root.moodKey(source)]
      if (!list) { root.ensureMoods(source); return { wait: true } }
      for (var i = 0; i < list.length; i++) if (list[i].id === m[1]) return { look: list[i] }
      return { error: "no mood " + m[1] }
    }

    var t = spec.match(/^theme:([A-Za-z0-9._-]+)$/)
    if (t) {
      for (var j = 0; j < root.catalog.themes.length; j++)
        if (root.catalog.themes[j].id === t[1]) return { look: root.catalog.themes[j] }
      return { error: "no theme " + t[1] }
    }
    return { error: "unknown look " + spec }
  }

  function runRequests(list) {
    var waiting = []
    for (var i = 0; i < root.requests.length; i++) {
      var req = root.requests[i]
      var hits = Palette.match(list, req.target)
      if (req.value === "next") {
        for (var j = 0; j < hits.length; j++)
          root.commit(root.indexOf(hits[j].pty), Palette.tintLook(root.nextHue(hits[j].look)))
        continue
      }
      if (req.value === "project:from") {
        if (hits.length > 0) root.saveProjectFrom(hits[0])
        continue
      }
      if (req.value.indexOf("project:remove:") === 0) { root.removeProject(req.value.slice(15)); continue }
      if (req.value === "default:from") {
        if (hits.length > 0) root.saveDefaultFrom(hits[0])
        continue
      }
      if (req.value.indexOf("default:") === 0) {
        var d = root.resolveSpec(req.value.slice(8))
        if (d.wait) { waiting.push(req); continue }
        if (d.error) { console.warn("ombre:", d.error); continue }
        root.setDefaultLook(d.look, null)
        continue
      }
      if (req.value === "pulse:now" || req.value === "pulse:stop") {
        for (var q = 0; q < hits.length; q++) {
          if (req.value === "pulse:now") root.startPulse(hits[q])
          else root.stopPulse(hits[q].address)
        }
        continue
      }
      if (req.value.indexOf("wallpaper:") === 0) {
        var path = req.value.slice(10)
        var wp = path === "none" ? null : { path: path, strength: req.strength }
        for (var w = 0; w < hits.length; w++) {
          if (hits[w].wallpaperReady) root.setWallpaper(root.indexOf(hits[w].pty), wp)
          else console.warn("ombre: " + hits[w].title + " can't take a wallpaper")
        }
        continue
      }
      var r = root.resolveSpec(req.value)
      if (r.wait) { waiting.push(req); continue }
      if (r.error) { console.warn("ombre:", r.error); continue }
      for (var k = 0; k < hits.length; k++) root.commit(root.indexOf(hits[k].pty), r.look)
    }
    root.requests = waiting
  }

  // ---- Scanning ---------------------------------------------------------
  function scan() {
    if (scanner.running) { root.rescan = true; return }
    scanner.running = true
  }

  // A scan that started before a look was set must not bring back the old one,
  // so looks set this session win over what the scan read from disk.
  function parseScan(output) {
    var a = output.indexOf("\n@@PS@@\n")
    var b = output.indexOf("\n@@STATE@@\n")
    var c = output.indexOf("\n@@GHOSTTY@@\n")
    var d = output.indexOf("\n@@MONITORS@@\n")
    var e = output.indexOf("\n@@CWD@@\n")
    if (a < 0 || b < 0 || c < 0 || d < 0 || e < 0) return null
    var list = Palette.terminals(output.slice(0, a), output.slice(a + 8, b), output.slice(b + 11, c),
                                 output.slice(c + 13, d), root.runtimeDir, output.slice(d + 14, e), output.slice(e + 9))
    for (var i = 0; i < list.length; i++) {
      var k = root.known[list[i].pty]
      if (k && k.pid === list[i].pid) {
        list[i].look = k.look
        list[i].wallpaper = k.wallpaper
      }
    }
    return list
  }

  function onScan(output) {
    var list = root.parseScan(output)
    if (!list) return
    root.terminals = list
    if (root.focusOnScan) {
      root.focusOnScan = false
      root.current = Palette.focusedIndex(list)
    }
    root.current = Math.max(0, Math.min(root.current, list.length - 1))
    var waiting = root.pendingPulses
    root.pendingPulses = []
    for (var w = 0; w < waiting.length; w++) {
      for (var t = 0; t < list.length; t++) if (list[t].address === waiting[w]) root.startPulse(list[t])
    }
    root.applyProjects(list)
    root.applyDefaults(list)
    root.applySolid(list)
    if (root.reshadowAll) {
      root.reshadowAll = false
      for (var r = 0; r < list.length; r++)
        if (list[r].wallpaperReady) root.sendWallpaper(list[r], list[r].wallpaper)
    }
    root.runRequests(list)
    if (root.rescan) { root.rescan = false; root.scan() }
  }

  function indexOf(pty) {
    for (var i = 0; i < root.terminals.length; i++) if (root.terminals[i].pty === pty) return i
    return -1
  }

  function nextHue(look) {
    var i = look && look.kind === "tint" ? Palette.hueIndex(look.id) : -1
    return Palette.HUES[(i + 1) % Palette.HUES.length].id
  }

  // ---- Catalog and moods ------------------------------------------------
  function loadCatalog() {
    if (!catalogProc.running) catalogProc.running = true
  }

  function onCatalog(output) {
    var c = Palette.parseCatalog(output)
    root.catalog = c
    root.catalogLoaded = true
    root.catalogAt = Date.now()
    if (root.moodSource && root.moodSources.indexOf(root.moodSource) < 0) root.moodSource = ""
    if (!root.tabChosen && !c.aether && root.tab === "moods") root.tab = "themes"
    if (root.opened && c.aether) root.ensureMoods(root.activeMoodSource)
    if (root.requests.length > 0) root.scan()
    root.maybeWelcome()
  }

  function moodKey(source) {
    return source + (root.lightTheme ? "|light" : "|dark")
  }

  function ensureMoods(source) {
    if (!source || !root.catalog.aether || root.moodCache[root.moodKey(source)]) return
    if (root.moodRunning === source || root.moodQueue.indexOf(source) >= 0) return
    root.moodQueue = root.moodQueue.concat([source])
    root.nextMoods()
  }

  function nextMoods() {
    if (moodProc.running || root.moodQueue.length === 0) return
    var source = root.moodQueue[0]
    root.moodQueue = root.moodQueue.slice(1)
    root.moodRunning = source
    var modes = root.catalog.modes.map(function (m) { return m.id })
      .filter(function (id) { return /^[a-z0-9-]+$/.test(id) })
    moodProc.command = ["sh", "-c", root.moodScript, "sh", source, root.lightTheme ? "--light-mode" : ""].concat(modes)
    moodProc.running = true
  }

  function onMoods(output) {
    var source = root.moodRunning
    var cache = Object.assign({}, root.moodCache)
    cache[root.moodKey(source)] = Palette.parseMoods(output, root.catalog.modes, source)
    root.moodCache = cache
    root.moodRunning = ""
    root.nextMoods()
    if (root.requests.length > 0) root.scan()
  }

  // Hide a wallpaper from the strips. Only the entry goes; the file stays.
  function hideSource(path) {
    if (!path || root.hiddenSources.indexOf(path) >= 0) return "ok"
    root.hiddenSources = root.hiddenSources.concat([path])
    if (root.moodSource === path) root.moodSource = ""
    root.saveConfig()
    root.hoverText = "Hidden " + Palette.basename(path) + " (file untouched). Press H to show hidden ones."
    return "ok"
  }

  function unhideSource(path) {
    root.hiddenSources = path === "*" ? [] : root.hiddenSources.filter(function (p) { return p !== path })
    root.saveConfig()
    return "ok"
  }

  function pickSource(path) {
    root.moodSource = path
    root.ensureMoods(path)
  }

  function stepSource(delta) {
    var list = root.moodSources
    if (list.length === 0) return
    var i = list.indexOf(root.activeMoodSource)
    root.pickSource(list[(i + delta + list.length) % list.length])
  }

  // ---- Applying looks ---------------------------------------------------
  function send(line) {
    if (writer.running) writer.write(line + "\n")
  }

  function show(term, look) {
    root.send("write " + term.pty + " " + Palette.sequence(look, root.themeBackground))
    root.paintBorder(term, look)
  }

  function paintBorder(term, look) {
    if (!term.address) return
    var color = root.borders ? Palette.lookAccent(look) : ""
    Hyprland.dispatch(Palette.borderPair(term.address, color, "ff",
      Palette.inactiveAccent(color, root.themeBackground), "ff"))
  }

  function persist(term) {
    if (term.look || term.wallpaper)
      root.send("save " + term.pty + " " + JSON.stringify({ pid: term.pid, look: term.look, wallpaper: term.wallpaper }))
    else root.send("forget " + term.pty)
    var known = Object.assign({}, root.known)
    known[term.pty] = { pid: term.pid, look: term.look, wallpaper: term.wallpaper }
    root.known = known
  }

  function update(index, patch) {
    var next = root.terminals.slice()
    next[index] = Object.assign({}, root.terminals[index], patch)
    root.terminals = next
    return next[index]
  }

  function commit(index, look) {
    if (index < 0 || index >= root.terminals.length) return
    look = Palette.normalizeLook(look)
    if (root.previewPty === root.terminals[index].pty) root.previewPty = ""
    var term = root.update(index, { look: look })
    root.show(term, look)
    root.persist(term)
    if (root.textShadow && term.wallpaperReady) root.sendWallpaper(term, term.wallpaper)
    if (root.pulses[term.address]) {
      var pulses = Object.assign({}, root.pulses)
      pulses[term.address] = Object.assign({}, pulses[term.address],
        { look: look, color: Palette.lookAccent(look) || root.accentHex })
      root.pulses = pulses
    }
  }

  // A mood or theme, with its wallpaper too when the window can take one.
  function commitWithWallpaper(index, look) {
    root.commit(index, look)
    var term = root.terminals[index]
    var image = look ? (look.kind === "mood" ? look.source : look.image) : ""
    if (root.withWallpaper && term && term.wallpaperReady && Palette.isImagePath(image))
      root.setWallpaper(index, { path: image, strength: root.strength })
  }

  // Ghostty reloads the window's config file on SIGUSR2. The writer checks the
  // pid really is Ghostty before signalling it.
  function sendWallpaper(term, wallpaper) {
    var w = Palette.normalizeWallpaper(wallpaper)
    root.send("ghostty " + term.pid + " " + (term.confDir || root.runtimeDir + "/ghostty/") + " "
      + root.shadowVariant(term) + " " + (w ? w.strength + " " + w.path : "- -"))
    // Re-send the look once the reload settles, in case it reset the colors.
    if (root.reshowPtys.indexOf(term.pty) < 0) root.reshowPtys = root.reshowPtys.concat([term.pty])
    reshowLater.restart()
  }

  function setWallpaper(index, wallpaper) {
    if (index < 0 || index >= root.terminals.length || !root.terminals[index].wallpaperReady) return
    var w = Palette.normalizeWallpaper(wallpaper)
    if (root.previewWallpaperPty === root.terminals[index].pty) root.previewWallpaperPty = ""
    var term = root.update(index, { wallpaper: w })
    root.sendWallpaper(term, w)
    root.persist(term)
  }

  function preview(index, look) {
    if (index < 0 || index >= root.terminals.length) return
    previewEnd.stop()
    var term = root.terminals[index]
    if (root.previewPty && root.previewPty !== term.pty) root.endPreview()
    root.previewPty = term.pty
    root.show(term, Palette.normalizeLook(look))
  }

  // Wallpaper previews reload Ghostty, so they wait until the pointer rests.
  function previewWallpaper(index, wallpaper) {
    if (index < 0 || index >= root.terminals.length || !root.terminals[index].wallpaperReady) return
    previewEnd.stop()
    root.pendingWallpaper = { pty: root.terminals[index].pty, wallpaper: Palette.normalizeWallpaper(wallpaper) }
    wallpaperPreview.restart()
  }

  function onWallpaperPreview() {
    var p = root.pendingWallpaper
    root.pendingWallpaper = null
    if (!p) return
    var i = root.indexOf(p.pty)
    if (i < 0) return
    if (root.previewWallpaperPty && root.previewWallpaperPty !== p.pty) root.endPreview()
    root.previewWallpaperPty = p.pty
    root.sendWallpaper(root.terminals[i], p.wallpaper)
  }

  function endPreview() {
    previewEnd.stop()
    wallpaperPreview.stop()
    root.pendingWallpaper = null
    if (root.previewPty) {
      var i = root.indexOf(root.previewPty)
      root.previewPty = ""
      if (i >= 0) root.show(root.terminals[i], root.terminals[i].look)
    }
    if (root.previewWallpaperPty) {
      var j = root.indexOf(root.previewWallpaperPty)
      root.previewWallpaperPty = ""
      if (j >= 0) root.sendWallpaper(root.terminals[j], root.terminals[j].wallpaper)
    }
  }

  function onReshow() {
    var ptys = root.reshowPtys
    root.reshowPtys = []
    for (var i = 0; i < ptys.length; i++) {
      var k = root.indexOf(ptys[i])
      if (k < 0) continue
      var t = root.terminals[k]
      root.show(t, root.previewPty === t.pty ? null : t.look)
    }
  }

  function setStrength(value) {
    root.strength = value
    root.saveConfig()
    var term = root.selectedTerm
    if (term && term.wallpaper) root.setWallpaper(root.current, { path: term.wallpaper.path, strength: value })
  }

  // ---- Project rules --------------------------------------------------------
  function applyProjects(list) {
    if (root.projects.length === 0) return
    var applied = Object.assign({}, root.appliedProject)
    var changed = false
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      var rule = Palette.projectFor(root.projects, t.cwd)
      var key = rule ? rule.path : ""
      if (applied[t.address] === key) continue
      applied[t.address] = key
      changed = true
      if (!rule) continue
      var index = root.indexOf(t.pty)
      if (rule.look) root.commit(index, rule.look)
      if (t.wallpaperReady) root.setWallpaper(index, rule.wallpaper || null)
      if (!root.seen[t.address]) root.markSeen([t])
    }
    if (changed) root.appliedProject = applied
  }

  // Save the selected terminal's look for its project folder (git root, else cwd).
  function saveProjectFrom(term) {
    if (!term) return
    var path = term.root || term.cwd
    if (!path) { root.hoverText = "Can't tell this terminal's folder."; return }
    if (!term.look && !term.wallpaper) { root.hoverText = "Give this terminal a look first."; return }
    root.setProject(path, term.look, term.wallpaper)
    root.hoverText = Palette.basename(path) + " terminals will open as " + root.ruleLabel(root.projectRule(path))
  }

  // IPC: define a rule from JSON {path, look: <look value>, wallpaper, strength}.
  function defineProject(arg) {
    var req
    try { req = JSON.parse(arg) } catch (e) { return "error: bad request" }
    if (!req || typeof req.path !== "string" || req.path.charAt(0) !== "/") return "error: path must be absolute"
    var look = null
    if (req.look) {
      if (!root.validSpec(String(req.look))) return "error: unknown look " + req.look
      var r = root.resolveSpec(String(req.look))
      if (r.wait) return "error: still loading looks, try again"
      if (r.error) return "error: " + r.error
      look = r.look
    }
    var wp = Palette.isImagePath(req.wallpaper) ? { path: req.wallpaper, strength: Number(req.strength) || root.strength } : null
    return root.setProject(req.path, look, wp)
  }

  function projectRule(path) {
    for (var i = 0; i < root.projects.length; i++) if (root.projects[i].path === path) return root.projects[i]
    return null
  }

  function setProject(path, look, wallpaper) {
    path = String(path || "").replace(/\/+$/, "")
    if (path.charAt(0) !== "/") return "error: path must be absolute"
    var rule = { path: path, look: Palette.normalizeLook(look), wallpaper: Palette.normalizeWallpaper(wallpaper) }
    var next = root.projects.filter(function (r) { return r.path !== path })
    next.push(rule)
    next.sort(function (a, b) { return a.path < b.path ? -1 : a.path > b.path ? 1 : 0 })
    root.projects = next
    root.appliedProject = ({})
    root.saveConfig()
    root.scan()
    return "ok"
  }

  function removeProject(path) {
    path = String(path || "").replace(/\/+$/, "")
    root.projects = root.projects.filter(function (r) { return r.path !== path })
    root.appliedProject = ({})
    root.saveConfig()
    return "ok"
  }

  function ruleLabel(rule) {
    if (!rule) return ""
    var parts = []
    if (rule.look) parts.push(rule.look.kind === "tint" ? Palette.lookLabel(rule.look) : Palette.pretty(rule.look.id))
    if (rule.wallpaper) parts.push(Palette.basename(rule.wallpaper.path) + " wallpaper")
    return parts.join(" with ") || "their own colors"
  }

  // ---- Default look for new terminals -----------------------------------
  function markSeen(list) {
    var seen = Object.assign({}, root.seen)
    for (var i = 0; i < list.length; i++) seen[list[i].address] = true
    root.seen = seen
    root.seenReady = true
  }

  function applyDefaults(list) {
    if (!root.seenReady) return
    var fresh = list.filter(function (t) { return !root.seen[t.address] })
    if (fresh.length === 0) return
    root.markSeen(fresh)
    var aw = Object.assign({}, root.awaiting)
    for (var f = 0; f < fresh.length; f++) delete aw[fresh[f].address]
    root.awaiting = aw
    if (root.newDefault.mode === "none" && !root.textShadow) return
    for (var i = 0; i < fresh.length; i++) {
      var t = fresh[i]
      var index = root.indexOf(t.pty)
      if (root.textShadow && t.wallpaperReady && !t.wallpaper) root.sendWallpaper(t, null)
      if (t.look || t.wallpaper) continue
      if (root.newDefault.mode === "none") continue
      if (root.newDefault.mode === "auto") {
        root.commit(index, Palette.tintLook(root.leastUsedHue()))
      } else if (root.newDefault.mode === "look") {
        if (root.newDefault.look) root.commit(index, root.newDefault.look)
        if (root.newDefault.wallpaper && t.wallpaperReady) root.setWallpaper(index, root.newDefault.wallpaper)
      }
    }
  }

  // The tint fewest open terminals wear, first in palette order on a tie.
  function leastUsedHue() {
    var counts = {}
    for (var i = 0; i < root.terminals.length; i++) {
      var l = root.terminals[i].look
      if (l && l.kind === "tint" && Palette.hue(l.id)) counts[l.id] = (counts[l.id] || 0) + 1
    }
    var best = Palette.HUES[0].id
    for (var h = 0; h < Palette.HUES.length; h++)
      if ((counts[Palette.HUES[h].id] || 0) < (counts[best] || 0)) best = Palette.HUES[h].id
    return best
  }

  function setDefaultMode(mode) {
    if (mode === "look" && !root.newDefault.look && !root.newDefault.wallpaper) {
      if (root.selectedTerm) root.saveDefaultFrom(root.selectedTerm)
      return "ok"
    }
    if (mode !== "none" && mode !== "auto" && mode !== "look") return "error: mode is none, auto or look"
    root.newDefault = Object.assign({}, root.newDefault, { mode: mode })
    root.saveConfig()
    return "ok"
  }

  function setDefaultLook(look, wallpaper) {
    root.newDefault = { mode: "look", look: Palette.normalizeLook(look), wallpaper: Palette.normalizeWallpaper(wallpaper) }
    root.saveConfig()
  }

  function saveDefaultFrom(term) {
    if (!term || (!term.look && !term.wallpaper)) {
      root.hoverText = "Give this terminal a look first, then save it as the default."
      return
    }
    root.setDefaultLook(term.look, term.wallpaper)
    root.hoverText = "New terminals will open as " + root.defaultLabel
  }

  readonly property string defaultLabel: {
    var d = root.newDefault
    if (d.mode === "auto") return "a different tint each"
    if (d.mode !== "look") return "their own colors"
    var parts = []
    if (d.look) parts.push(d.look.kind === "tint" ? Palette.lookLabel(d.look) : Palette.pretty(d.look.id))
    if (d.wallpaper) parts.push(Palette.basename(d.wallpaper.path) + " wallpaper")
    return parts.join(" with ") || "their own colors"
  }

  // Space and Shift+Space walk the list on the open tab for the selected terminal.
  function stepLook(delta) {
    var term = root.selectedTerm
    if (!term) return
    if (root.tab === "wallpapers") {
      if (!term.wallpaperReady || root.wallpaperChoices.length === 0) return
      var choices = root.wallpaperChoices
      var w = term.wallpaper ? choices.indexOf(term.wallpaper.path) : -1
      var wn = w < 0 ? (delta > 0 ? 0 : choices.length - 1) : (w + delta + choices.length) % choices.length
      root.setWallpaper(root.current, { path: choices[wn], strength: root.strength })
      root.hoverText = Palette.basename(choices[wn])
      return
    }
    var list = root.tab === "moods" ? root.moods : root.catalog.themes
    if (list.length === 0) return
    var i = -1
    for (var k = 0; k < list.length; k++) if (Palette.sameLook(list[k], term.look)) i = k
    var next = i < 0 ? (delta > 0 ? 0 : list.length - 1) : (i + delta + list.length) % list.length
    root.commitWithWallpaper(root.current, list[next])
    root.hoverText = root.describe(list[next])
  }

  function describe(look) {
    if (!look) return ""
    if (look.kind === "mood") return Palette.pretty(look.id) + " — " + (look.description || "")
    return Palette.pretty(look.id)
  }

  function nextTab(delta) {
    var i = root.tabs.indexOf(root.tab)
    root.tab = root.tabs[(i + delta + root.tabs.length) % root.tabs.length]
    root.tabChosen = true
  }

  function runSetup() {
    if (setupProc.running) return
    root.setupMessage = "Setting up Ghostty…"
    setupProc.command = ["bash", root.pluginDir + "/bin/ombre-setup-ghostty"]
    setupProc.running = true
  }

  // Re-send every saved look: after a theme change tints are re-derived from
  // the new background, and a Hyprland reload drops per-window border props.
  // Wallpapers live in each window's config file, so they survive reloads.
  // At startup every terminal's border is repainted, which also clears a pulse
  // color left behind if the shell stopped mid-pulse.
  property bool repaintAll: false

  function reapply() {
    reapplyScan.running = true
  }

  function onReapplyScan(output) {
    var list = root.parseScan(output)
    if (!list) return
    for (var i = 0; i < list.length; i++) {
      if (list[i].look) root.show(list[i], list[i].look)
      else if (root.repaintAll) root.paintBorder(list[i], null)
    }
    root.repaintAll = false
    root.applySolid(list)
    root.markSeen(list)
    if (root.opened) root.terminals = list
  }

  function toplevelFor(address) {
    var list = Hyprland.toplevels.values
    for (var i = 0; i < list.length; i++) if (list[i].address === address) return list[i].wayland
    return null
  }

  // ---- Needs-you pulse ---------------------------------------------------
  readonly property string accentHex: "#" + String(Color.accent).replace(/^#/, "").slice(-6)

  // Only terminals pulse, so check the window against a fresh scan first.
  function requestPulse(address) {
    if (!root.pulse || !address || address === root.activeAddress || root.pulses[address]) return
    if (root.pendingPulses.indexOf(address) < 0) root.pendingPulses = root.pendingPulses.concat([address])
    root.scan()
  }

  function startPulse(term) {
    if (!term || !term.address || root.pulses[term.address]) return
    var pulses = Object.assign({}, root.pulses)
    pulses[term.address] = { started: Date.now(), look: term.look,
                             color: Palette.lookAccent(term.look) || root.accentHex }
    root.pulses = pulses
  }

  // Stop pulsing and give the window its usual border back, then once more a
  // moment later in case a last pulse frame lands after the first restore.
  property var restoreQueue: []

  function stopPulse(address) {
    var p = root.pulses[address]
    if (!p) return
    root.dropPulse(address)
    root.paintBorder({ address: address }, p.look)
    root.restoreQueue = root.restoreQueue.concat([{ address: address, look: p.look }])
    restoreAgain.restart()
  }

  function onRestoreAgain() {
    var queue = root.restoreQueue
    root.restoreQueue = []
    for (var i = 0; i < queue.length; i++)
      if (!root.pulses[queue[i].address]) root.paintBorder({ address: queue[i].address }, queue[i].look)
  }

  function dropPulse(address) {
    if (!root.pulses[address]) return
    var pulses = Object.assign({}, root.pulses)
    delete pulses[address]
    root.pulses = pulses
  }

  function onPulseTick() {
    var now = Date.now()
    root.pulsePhase = !root.pulsePhase
    for (var addr in root.pulses) {
      var p = root.pulses[addr]
      var c
      if (root.borderAnimated) {
        var ends = Palette.pulseEnds(p.color, root.themeBackground)
        c = root.pulsePhase ? ends.bright : ends.dim
      } else c = Palette.pulseColor(p.color, root.themeBackground, now - p.started)
      Hyprland.dispatch(Palette.borderPair(addr, c, "ff", c, "ff"))
    }
  }

  function onAgentTitle(data) {
    var comma = data.indexOf(",")
    if (comma < 0) return
    var addr = data.slice(0, comma)
    var state = Palette.agentState(data.slice(comma + 1))
    var prev = root.agentStates[addr]
    if (prev !== state) {
      var states = Object.assign({}, root.agentStates)
      states[addr] = state
      root.agentStates = states
    }
    if (prev === "working" && state === "idle") root.requestPulse(addr)
    else if (state === "working") root.stopPulse(addr)
  }

  // ---- Config and first run ---------------------------------------------
  function saveConfig() {
    configWriter.command = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1"',
      "sh", root.configFile, JSON.stringify({
        borders: root.borders, pulse: root.pulse, solid: root.solid, textShadow: root.textShadow, strength: root.strength,
        hiddenSources: root.hiddenSources,
        withWallpaper: root.withWallpaper, welcomed: root.welcomed, newTerminals: root.newDefault,
        projects: root.projects
      })]
    configWriter.running = true
  }

  function onConfig(text) {
    try {
      var cfg = JSON.parse(text)
      if (cfg && typeof cfg.borders === "boolean") root.borders = cfg.borders
      if (cfg && typeof cfg.pulse === "boolean") root.pulse = cfg.pulse
      if (cfg && typeof cfg.solid === "boolean") root.solid = cfg.solid
      if (cfg && typeof cfg.textShadow === "boolean") root.textShadow = cfg.textShadow
      if (cfg && Array.isArray(cfg.hiddenSources)) root.hiddenSources = cfg.hiddenSources.filter(Palette.isImagePath)
      if (cfg && typeof cfg.strength === "number") root.strength = Palette.normalizeWallpaper({ path: "/x.png", strength: cfg.strength }).strength
      if (cfg && typeof cfg.withWallpaper === "boolean") root.withWallpaper = cfg.withWallpaper
      if (cfg && cfg.welcomed === true) root.welcomed = true
      if (cfg && Array.isArray(cfg.projects)) {
        root.projects = cfg.projects.map(function (r) {
          return r && typeof r.path === "string" && r.path.charAt(0) === "/"
            ? { path: r.path.replace(/\/+$/, ""), look: Palette.normalizeLook(r.look), wallpaper: Palette.normalizeWallpaper(r.wallpaper) }
            : null
        }).filter(function (r) { return r !== null })
      }
      if (cfg && cfg.newTerminals && typeof cfg.newTerminals === "object") {
        var mode = cfg.newTerminals.mode
        root.newDefault = {
          mode: mode === "auto" || mode === "look" ? mode : "none",
          look: Palette.normalizeLook(cfg.newTerminals.look),
          wallpaper: Palette.normalizeWallpaper(cfg.newTerminals.wallpaper)
        }
      }
    } catch (e) { }
    if (!root.configLoaded) {
      root.repaintAll = true
      root.reapply()
    }
    root.configLoaded = true
    root.maybeWelcome()
  }

  // The first time the plugin loads, say what it does and what wallpapers need.
  // Plugin installs never run plugin code, so this is the earliest moment.
  function maybeWelcome() {
    if (root.welcomed || !root.configLoaded || !root.catalogLoaded) return
    root.welcomed = true
    root.saveConfig()
    var notes = ["Give each terminal its own tint, mood, theme or wallpaper."]
    if (!root.catalog.aether)
      notes.push(root.catalog.aetherInstalled
        ? "Moods need Aether 4 or newer: run 'omarchy update'."
        : "Moods need Aether: run 'omarchy pkg add aether'.")
    if (!root.catalog.ghostty)
      notes.push("Wallpapers require Ghostty: run 'omarchy install terminal ghostty', then set it up in the picker's Wallpapers tab.")
    else if (!root.catalog.launcher)
      notes.push("Wallpapers require Ghostty windows opened through Ombre: set that up in the picker's Wallpapers tab.")
    notes.push("Click to open the picker.")
    var body = notes.join(" ")
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send", "--app-name", "Ombre",
      "-g", "\uDB80\uDFD8", "Ombre is installed", body,
      "--exec", "omarchy-shell", "shell", "toggle", root.pluginId, "{}"])
  }

  // ---- Processes --------------------------------------------------------
  readonly property string scanScript:
    'hyprctl -j clients; printf "\\n@@PS@@\\n"; ps -e -o pid=,ppid=,tty=; printf "\\n@@STATE@@\\n"; '
    + 'for f in "$1"/pts-*; do [ -f "$f" ] && printf "%s %s\\n" "${f##*/}" "$(cat "$f")"; done; '
    + 'printf "\\n@@GHOSTTY@@\\n"; '
    + 'for p in $(pgrep -x ghostty); do printf "%s\\t%s\\n" "$p" "$(tr "\\0" " " < /proc/$p/cmdline 2>/dev/null)"; done; '
    + 'printf "\\n@@MONITORS@@\\n"; hyprctl -j monitors; printf "\\n@@CWD@@\\n"; '
    // Working folder and git root of every process on a pty, with no forks
    // beyond one readlink each.
    + 'for p in $(ps -e -o pid=,tty= | awk \'$2 ~ /^pts/ {print $1}\'); do d=$(readlink /proc/$p/cwd 2>/dev/null) || continue; '
    + 'r=$d; while [ -n "$r" ] && [ "$r" != / ] && [ ! -e "$r/.git" ]; do r=${r%/*}; done; [ -e "$r/.git" ] || r=; '
    + 'printf "%s\\t%s\\t%s\\n" "$p" "$d" "$r"; done; true'

  readonly property string catalogScript:
    'printf "@@WALLPAPER %s\\n" "$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null)"\n'
    + 'for f in "$HOME"/Wallpapers/Ombre/*; do [ -f "$f" ] && printf "@@OMBRE %s\\n" "$f"; done\n'
    + 'command -v ghostty >/dev/null 2>&1 && printf "@@GHOSTTY\\n"\n'
    + 'desktop="${XDG_DATA_HOME:-$HOME/.local/share}/applications/com.mitchellh.ghostty.desktop"\n'
    + '[ -x "$HOME/.local/bin/ombre-ghostty" ] && grep -qx "# Written by Ombre" "$desktop" 2>/dev/null && printf "@@LAUNCHER\\n"\n'
    // Aether's CLI arrived in 4.x; never call it on an older build, which might
    // open its window instead. Timeouts keep a stuck call from holding the picker.
    + 'if command -v aether >/dev/null 2>&1; then\n'
    + '  v=$(timeout 3 aether --version </dev/null 2>/dev/null | head -n 1)\n'
    + '  printf "@@AETHER %s\\n" "${v:-unknown}"\n'
    + '  case $v in\n'
    + '    "aether "[4-9].*|"aether "[1-9][0-9]*)\n'
    + '      printf "@@MODES\\n"; timeout 5 aether --list-modes --json </dev/null 2>/dev/null; printf "\\n"\n'
    + '      printf "@@WALLPAPERS\\n"; timeout 5 aether --list-wallpapers --json </dev/null 2>/dev/null; printf "\\n" ;;\n'
    + '  esac\n'
    + 'fi\n'
    + 'for d in "${OMARCHY_PATH:-/usr/share/omarchy}"/themes/*/ "$HOME"/.config/omarchy/themes/*/; do\n'
    + '  [ -f "$d/colors.toml" ] || continue\n'
    + '  n=${d%/}; n=${n##*/}; bg=\n'
    + '  for f in "$d"backgrounds/*; do [ -f "$f" ] && { bg=$f; break; }; done\n'
    + '  printf "@@THEME %s\\t%s\\n" "$n" "$bg"; cat "$d/colors.toml"; printf "\\n"\n'
    + 'done\n'
    + 'true\n'

  // Every mode at once, a few at a time; Aether takes ~80 ms per palette.
  readonly property string moodScript:
    'src=$1; light=$2; shift 2\n'
    + 'tmp=$(mktemp -d) || exit 1\n'
    + 'trap \'rm -rf "$tmp"\' EXIT\n'
    + 'printf "%s\\n" "$@" | xargs -P 6 -I{} sh -c \'timeout 10 aether --extract-palette "$1" --extract-mode "$2" --json $3 > "$4/$2" 2>/dev/null </dev/null\' sh "$src" {} "$light" "$tmp"\n'
    + 'for m in "$@"; do printf "@@MODE %s\\n" "$m"; cat "$tmp/$m" 2>/dev/null; printf "\\n"; done\n'

  // One long-lived writer keeps escape sequences in order while the pointer
  // sweeps across swatches. Lines:
  //   write PTY SEQUENCE     escape sequence for the terminal (validated hex colors only)
  //   save PTY JSON          remember the look for the picker
  //   forget PTY
  //   ghostty PID CONFDIR SHADOW STRENGTH PATH   per-window wallpaper and text shadow, then SIGUSR2
  //     SHADOW is dark, light or -; STRENGTH PATH are "- -" for no wallpaper
  readonly property string writerScript:
    'umask 077; d=$1; plug=$2; mkdir -p "$d/ghostty" 2>/dev/null\n'
    + 'if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then echo "ombre: $d is not a private directory owned by you" >&2; exit 1; fi\n'
    + 'chmod 700 "$d"\n'
    + 'while IFS= read -r line; do\n'
    + '  op=${line%% *}; rest=${line#* }; key=${rest%% *}; arg=${rest#* }\n'
    + '  case $op in\n'
    + '    write|save|forget)\n'
    + '      case $key in pts/[0-9]*) ;; *) continue ;; esac\n'
    + '      dev=/dev/$key; f=$d/pts-${key#pts/}\n'
    + '      case $op in\n'
    + '        write) printf "%s" "$arg" > "$dev" ;;\n'
    + '        save) printf "%s\\n" "$arg" > "$f" ;;\n'
    + '        forget) rm -f "$f" ;;\n'
    + '      esac ;;\n'
    + '    ghostty)\n'
    + '      case $key in ""|*[!0-9]*) continue ;; esac\n'
    + '      [ "$(cat /proc/$key/comm 2>/dev/null)" = ghostty ] || continue\n'
    + '      cdir=${arg%% *}; rest=${arg#* }; shadow=${rest%% *}; rest=${rest#* }; strength=${rest%% *}; path=${rest#* }\n'
    + '      case $cdir in /*/ghostty/) ;; *) continue ;; esac\n'
    + '      [ -d "$cdir" ] && [ ! -L "${cdir%/}" ] && [ -O "$cdir" ] || continue\n'
    + '      {\n'
    + '        echo "app-notifications = no-config-reload"\n'
    + '        case $shadow in dark|light)\n'
    + '          printf "custom-shader = \\"%s/shaders/text-shadow-%s.glsl\\"\\n" "$plug" "$shadow"\n'
    + '          echo "custom-shader-animation = false" ;;\n'
    + '        esac\n'
    + '        if [ "$strength" != "-" ]; then\n'
    + '          printf "background-image = \\"%s\\"\\n" "$path"\n'
    + '          echo "background-image-fit = cover"\n'
    + '          printf "background-image-opacity = %s\\n" "$strength"\n'
    + '        fi\n'
    + '      } > "$cdir$key.conf" && kill -USR2 "$key" ;;\n'
    + '  esac\n'
    + 'done 2>/dev/null\n'

  Process {
    id: writer
    stdinEnabled: true
    running: true
    command: ["sh", "-c", root.writerScript, "sh", root.runtimeDir, root.pluginDir]
    onExited: restartWriter.start()
  }

  Timer { id: restartWriter; interval: 1000; onTriggered: writer.running = true }

  Process {
    id: scanner
    command: ["sh", "-c", root.scanScript, "sh", root.runtimeDir]
    stdout: StdioCollector { onStreamFinished: root.onScan(text) }
  }

  Process {
    id: reapplyScan
    command: ["sh", "-c", root.scanScript, "sh", root.runtimeDir]
    stdout: StdioCollector { onStreamFinished: root.onReapplyScan(text) }
  }

  Process {
    id: catalogProc
    command: ["sh", "-c", root.catalogScript]
    stdout: StdioCollector { onStreamFinished: root.onCatalog(text) }
  }

  Process {
    id: moodProc
    stdout: StdioCollector { onStreamFinished: root.onMoods(text) }
  }

  Process {
    id: setupProc
    stdout: StdioCollector { id: setupOut }
    stderr: StdioCollector { id: setupErr }
    onExited: function (code) {
      root.setupMessage = code === 0 ? "" : (String(setupErr.text).trim() || "Setup failed.")
      root.loadCatalog()
    }
  }

  Process { id: configWriter }
  Process { id: solidWriter }
  Process {
    id: solidReader
    stdout: StdioCollector { onStreamFinished: root.onSolidRead(text) }
  }
  Process {
    id: solidState
    running: true
    command: ["sh", "-c", 'cat "$1/solid.json" 2>/dev/null; true', "sh", root.runtimeDir]
    stdout: StdioCollector { onStreamFinished: root.onSolidState(text) }
  }

  Process {
    id: configReader
    running: true
    command: ["sh", "-c", 'cat "$1" 2>/dev/null || cat "${1%/*}/terminal-tint.json" 2>/dev/null; true', "sh", root.configFile]
    stdout: StdioCollector { onStreamFinished: root.onConfig(text) }
  }

  Timer { id: reapplyLater; interval: 1500; onTriggered: root.reapply() }

  // Sliding between neighbouring swatches should not flash the saved look.
  Timer { id: previewEnd; interval: 80; onTriggered: root.endPreview() }
  Timer { id: wallpaperPreview; interval: 250; onTriggered: root.onWallpaperPreview() }
  Timer { id: reshowLater; interval: 400; onTriggered: root.onReshow() }
  Timer { interval: root.borderAnimated ? Palette.PULSE_PERIOD_MS / 2 : 125; repeat: true; running: root.pulsing; triggeredOnStart: true; onTriggered: root.onPulseTick() }

  Process {
    id: animProbe
    running: true
    command: ["sh", "-c", "hyprctl animations -j 2>/dev/null | jq -r '.[0][] | select(.name==\"border\") | .enabled' 2>/dev/null"]
    stdout: StdioCollector { onStreamFinished: root.borderAnimated = String(text).trim() === "true" }
  }
  Timer { id: restoreAgain; interval: 250; onTriggered: root.onRestoreAgain() }
  // A title change often means an agent just started in some folder.
  Timer { id: projectScan; interval: 10000; onTriggered: root.scan() }
  Timer {
    id: newWindowScan
    interval: 600
    repeat: true
    onTriggered: {
      root.scan()
      if (--root.newWindowTries <= 0 || Object.keys(root.awaiting).length === 0) { root.awaiting = ({}); stop() }
    }
  }

  Connections {
    target: Color
    function onBackgroundChanged() { reapplyLater.restart(); root.loadCatalog() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var data = String(event.data || "").trim()
      switch (event.name) {
      case "configreloaded": reapplyLater.restart(); break
      case "activewindowv2": root.activeAddress = data; root.stopPulse(data); break
      case "closewindow":
        root.dropPulse(data)
        if (root.solidOriginal[data]) {
          var kept = Object.assign({}, root.solidOriginal)
          delete kept[data]
          root.solidOriginal = kept
          root.saveSolid()
        }
        if (root.agentStates[data]) {
          var states = Object.assign({}, root.agentStates)
          delete states[data]
          root.agentStates = states
        }
        break
      case "urgent": root.requestPulse(data); break
      case "openwindow":
        // A window can take seconds to start its shell; keep looking until it
        // shows up in a scan.
        if (root.newDefault.mode !== "none" || root.textShadow || root.solid || root.projects.length > 0) {
          var aw = Object.assign({}, root.awaiting)
          aw[data.split(",")[0]] = true
          root.awaiting = aw
          root.newWindowTries = 25
          newWindowScan.restart()
        }
        break
      case "windowtitlev2":
        root.onAgentTitle(data)
        if (root.projects.length > 0 && !projectScan.running) projectScan.start()
        break
      }
    }
  }

  Component.onCompleted: root.loadCatalog()

  // Shutting down mid-pulse would leave a pulse color on the border.
  Component.onDestruction: {
    for (var addr in root.pulses) root.paintBorder({ address: addr }, root.pulses[addr].look)
  }

  // ---- UI ---------------------------------------------------------------
  component Swatch: Item {
    id: swatch
    property string value: ""
    property bool chosen: false
    property int termIndex: -1
    readonly property bool hot: hover.containsMouse

    width: root.swatchSize
    height: root.swatchSize

    Rectangle {
      anchors.centerIn: parent
      width: parent.width + Style.space(6)
      height: width
      radius: width / 2
      color: "transparent"
      border.width: Math.max(1, Style.space(2))
      border.color: root.text
      visible: swatch.chosen
    }

    Rectangle {
      anchors.centerIn: parent
      width: parent.width
      height: width
      radius: width / 2
      scale: swatch.hot ? 1.18 : 1.0
      color: swatch.value ? Palette.hue(swatch.value).hex : root.themeBackground
      border.width: swatch.value ? 0 : Math.max(1, Style.space(1))
      border.color: root.muted
      Behavior on scale { NumberAnimation { duration: 90 } }

      // "None" is drawn as a slashed circle.
      Rectangle {
        visible: !swatch.value
        anchors.centerIn: parent
        width: parent.width * 0.9
        height: Math.max(1, Style.space(2))
        rotation: -45
        color: root.muted
      }
    }

    MouseArea {
      id: hover
      anchors.fill: parent
      anchors.margins: -Style.space(3)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.preview(swatch.termIndex, Palette.tintLook(swatch.value))
      onExited: previewEnd.restart()
      onClicked: { root.current = swatch.termIndex; root.commit(swatch.termIndex, Palette.tintLook(swatch.value)) }
    }
  }

  component TabButton: Text {
    id: tabButton
    property string name: ""
    color: root.tab === name ? root.text : tabArea.containsMouse ? root.text : root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: root.tab === name

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.bottom
      anchors.topMargin: Style.space(3)
      height: Math.max(1, Style.space(2))
      color: root.accent
      visible: root.tab === tabButton.name
    }

    MouseArea {
      id: tabArea
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { root.tab = tabButton.name; root.tabChosen = true }
    }
  }

  component TextButton: Rectangle {
    id: textButton
    property string label: ""
    property bool chosen: false
    signal activated()
    width: buttonText.implicitWidth + Style.space(16)
    height: buttonText.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: chosen ? Color.menu.selectedBackground : "transparent"
    border.width: Math.max(1, Style.space(1))
    border.color: chosen ? root.accent : buttonArea.containsMouse ? root.text : root.subtle

    Text {
      id: buttonText
      anchors.centerIn: parent
      text: textButton.label
      color: textButton.chosen || buttonArea.containsMouse ? root.text : root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: textButton.activated()
    }
  }

  // While the picker is open every monitor dims, except a cut-out around the
  // selected terminal with a ring and its name, so you can see which real
  // window a card is. It sits on the Top layer, under the picker's Overlay.
  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: spot
      required property var modelData
      screen: modelData
      visible: root.opened
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-ombre-spotlight"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      readonly property var term: root.selectedTerm
      readonly property bool here: term !== null && term.visible === true && term.monitor === modelData.name
      readonly property int gap: Style.space(5)
      readonly property color scrim: Color.menu.scrim
      readonly property color ring: (term && Palette.lookAccent(term.look)) || root.accent

      // The cut-out, in whole pixels; it closes to the middle of the screen when
      // the selection is elsewhere.
      readonly property rect target: here
        ? Qt.rect(Math.round(term.lx - gap), Math.round(term.ly - gap), Math.round(term.w + gap * 2), Math.round(term.h + gap * 2))
        : Qt.rect(Math.round(width / 2), Math.round(height / 2), 0, 0)

      // One rectangle whose very thick border is the dimmed area and whose empty
      // middle is the cut-out, so it moves as a single piece with the ring.
      Item {
        id: hole
        x: spot.target.x
        y: spot.target.y
        width: spot.target.width
        height: spot.target.height
        Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        readonly property real reach: Math.max(spot.width, spot.height) * 2

        Rectangle {
          x: -hole.reach
          y: -hole.reach
          width: hole.width + hole.reach * 2
          height: hole.height + hole.reach * 2
          color: "transparent"
          border.width: hole.reach
          border.color: spot.scrim
        }

        Rectangle {
          anchors.fill: parent
          color: "transparent"
          radius: Style.cornerRadius
          border.width: Math.max(2, Style.space(3))
          border.color: spot.ring
          opacity: spot.here ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160 } }
          Behavior on border.color { ColorAnimation { duration: 220 } }

          Rectangle {
            x: Style.space(10)
            y: Style.space(10)
            width: Math.min(nameText.implicitWidth + Style.space(16), parent.width - Style.space(20))
            height: nameText.implicitHeight + Style.space(8)
            radius: height / 2
            color: spot.ring
            visible: parent.width > Style.space(60)
            Behavior on color { ColorAnimation { duration: 220 } }

            Text {
              id: nameText
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              horizontalAlignment: Text.AlignHCenter
              text: spot.term ? spot.term.title : ""
              elide: Text.ElideRight
              color: Palette.isLight(String(spot.ring)) ? "#000000" : "#ffffff"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
        }
      }

      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: {
      var mon = Hyprland.focusedMonitor
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) if (mon && screens[i].name === mon.name) return screens[i]
      return screens.length > 0 ? screens[0] : null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-ombre"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(content.implicitWidth + root.pad * 2, panel.width - Style.gapsOut * 4)
      height: Math.min(content.implicitHeight + root.pad * 2, panel.height - Style.gapsOut * 4)
      radius: Style.cornerRadius
      color: root.surface
      borderSpec: root.borderSpec

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: root.pad
        focus: true

        Keys.onPressed: function (event) {
          var n = root.terminals.length
          var k = event.key
          var shift = (event.modifiers & Qt.ShiftModifier) !== 0
          if (k === Qt.Key_Escape || k === Qt.Key_Return || k === Qt.Key_Enter) root.dismiss()
          else if (k === Qt.Key_Tab) root.nextTab(1)
          else if (k === Qt.Key_Backtab) root.nextTab(-1)
          else if (k === Qt.Key_W && root.tab === "moods") root.stepSource(shift ? -1 : 1)
          else if (k === Qt.Key_X && root.tab === "moods" && root.activeMoodSource) {
            if (root.hiddenSources.indexOf(root.activeMoodSource) >= 0) root.unhideSource(root.activeMoodSource)
            else root.hideSource(root.activeMoodSource)
          }
          else if (k === Qt.Key_H && (root.tab === "moods" || root.tab === "wallpapers")) root.showHidden = !root.showHidden
          else if (k === Qt.Key_B) root.setBorders(!root.borders)
          else if (k === Qt.Key_P) root.setPulse(!root.pulse)
          else if (k === Qt.Key_O) root.setSolid(!root.solid)
          else if (k === Qt.Key_T) root.setTextShadow(!root.textShadow)
          else if (k === Qt.Key_D && root.selectedTerm) root.saveDefaultFrom(root.selectedTerm)
          else if (k === Qt.Key_F && root.selectedTerm) root.saveProjectFrom(root.selectedTerm)
          else if (n === 0) return
          else if (k === Qt.Key_Right || k === Qt.Key_L) root.current = (root.current + 1) % n
          else if (k === Qt.Key_Left || k === Qt.Key_H) root.current = (root.current - 1 + n) % n
          else if (k === Qt.Key_Down || k === Qt.Key_J) root.current = Math.min(n - 1, root.current + root.columns)
          else if (k === Qt.Key_Up || k === Qt.Key_K) root.current = Math.max(0, root.current - root.columns)
          else if (k >= Qt.Key_1 && k <= Qt.Key_8) root.commit(root.current, Palette.tintLook(Palette.HUES[k - Qt.Key_1].id))
          else if (k === Qt.Key_0 || k === Qt.Key_Backspace || k === Qt.Key_Delete) {
            if (root.tab === "wallpapers") root.setWallpaper(root.current, null)
            else root.commit(root.current, null)
          }
          else if (k === Qt.Key_Space) root.stepLook(shift ? -1 : 1)
          else if (k === Qt.Key_N) root.commit(root.current, Palette.tintLook(root.nextHue(root.selectedTerm.look)))
          else return
          event.accepted = true
        }

        Column {
          id: content
          width: root.contentWidth
          spacing: root.gap

          Item {
            width: parent.width
            height: titleText.implicitHeight

            Text {
              id: titleText
              anchors.left: parent.left
              text: "Ombre"
              color: root.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              Text {
                visible: root.catalog.launcher
                text: root.textShadow ? "Text shadow on" : "Text shadow off"
                color: shadowHover.containsMouse ? root.text : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: shadowHover
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setTextShadow(!root.textShadow)
                }
              }

              Text {
                visible: root.catalog.ghostty
                text: root.solid ? "Solid Ghostty on" : "Solid Ghostty off"
                color: solidHover.containsMouse ? root.text : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: solidHover
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setSolid(!root.solid)
                }
              }

              Text {
                text: root.pulse ? "Pulse when done on" : "Pulse when done off"
                color: pulseHover.containsMouse ? root.text : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: pulseHover
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setPulse(!root.pulse)
                }
              }

              Text {
                text: root.borders ? "Borders on" : "Borders off"
                color: bordersHover.containsMouse ? root.text : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: bordersHover
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setBorders(!root.borders)
                }
              }
            }
          }

          Text {
            visible: root.terminals.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: scanner.running ? "Looking for terminals…"
              : "No terminal windows found. Ombre works with terminals that run one process per window (Ghostty through Ombre's launcher, foot, Alacritty, Kitty)."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // Terminal cards scroll when there are more than fit.
          Flickable {
            id: cardsView
            width: grid.width
            height: Math.min(grid.implicitHeight, Math.max(Style.space(240), panel.height * 0.42))
            contentWidth: grid.width
            contentHeight: grid.implicitHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Grid {
              id: grid
              columns: root.columns
              spacing: root.gap

              Repeater {
                model: root.opened ? root.terminals : []

                delegate: Rectangle {
                  id: tile
                  required property var modelData
                  required property int index
                  readonly property bool selected: index === root.current
                  readonly property real aspect: Math.max(0.2, Math.min(5, modelData.h / Math.max(1, modelData.w)))
                  readonly property var look: modelData.look

                  width: root.cardWidth
                  height: tileColumn.implicitHeight + Style.space(10) * 2
                  radius: Style.cornerRadius
                  color: selected ? Color.menu.selectedBackground : "transparent"
                  border.width: Math.max(1, Style.space(selected ? 2 : 1))
                  border.color: selected ? root.accent : root.subtle

                  onSelectedChanged: if (selected) {
                    if (y < cardsView.contentY) cardsView.contentY = y
                    else if (y + height > cardsView.contentY + cardsView.height)
                      cardsView.contentY = y + height - cardsView.height
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.current = tile.index; keyCatcher.forceActiveFocus() }
                  }

                  Column {
                    id: tileColumn
                    x: Style.space(10)
                    y: Style.space(10)
                    width: parent.width - Style.space(20)
                    spacing: Style.space(8)

                    Rectangle {
                      id: frame
                      readonly property real innerWidth: width - border.width * 2
                      readonly property real innerHeight: height - border.width * 2

                      width: parent.width
                      height: Math.round(width * 0.6)
                      color: Palette.lookBackground(tile.look, root.themeBackground) || root.themeBackground
                      border.width: Math.max(1, Style.space(2))
                      border.color: Palette.lookAccent(tile.look) || root.subtle
                      clip: true

                      // Letterboxed so every card is the same size whatever the window shape.
                      ScreencopyView {
                        anchors.centerIn: parent
                        width: Math.min(frame.innerWidth, frame.innerHeight / tile.aspect)
                        height: Math.min(frame.innerHeight, frame.innerWidth * tile.aspect)
                        captureSource: root.toplevelFor(tile.modelData.address)
                        live: root.opened
                      }

                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: Style.space(6)
                        width: wsText.implicitWidth + Style.space(10)
                        height: wsText.implicitHeight + Style.space(4)
                        radius: height / 2
                        color: Util.alpha(root.surface, 0.85)
                        visible: tile.modelData.workspace !== ""

                        Text {
                          id: wsText
                          anchors.centerIn: parent
                          text: tile.modelData.workspace
                          color: root.text
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }

                    Item {
                      width: parent.width
                      height: titleLabel.implicitHeight

                      Text {
                        id: titleLabel
                        anchors.left: parent.left
                        width: parent.width - (lookLabel.text ? lookLabel.width + Style.space(8) : 0)
                        text: tile.modelData.title
                        elide: Text.ElideRight
                        color: root.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        id: lookLabel
                        anchors.right: parent.right
                        anchors.baseline: titleLabel.baseline
                        width: Math.min(implicitWidth, parent.width * 0.5)
                        text: {
                          var parts = []
                          if (tile.look && tile.look.kind !== "tint") parts.push(Palette.pretty(tile.look.id))
                          if (tile.modelData.wallpaper) parts.push("\uDB80\uDEE9 " + Palette.basename(tile.modelData.wallpaper.path))
                          return parts.join(" · ")
                        }
                        elide: Text.ElideMiddle
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Row {
                      spacing: Style.space(7)

                      Repeater {
                        model: Palette.HUES
                        delegate: Swatch {
                          required property var modelData
                          value: modelData.id
                          termIndex: tile.index
                          chosen: tile.look !== null && tile.look.kind === "tint" && tile.look.id === modelData.id
                        }
                      }

                      Swatch {
                        value: ""
                        termIndex: tile.index
                        chosen: tile.look === null
                      }
                    }
                  }
                }
              }
            }
          }

          Rectangle { width: parent.width; height: Math.max(1, Style.space(1)); color: root.subtle }

          // Moods, themes and wallpapers apply to the selected terminal.
          Item {
            width: parent.width
            height: Math.max(tabRow.implicitHeight, appliesText.implicitHeight) + Style.space(5)

            Row {
              id: tabRow
              spacing: Style.space(18)
              Repeater {
                model: root.tabs
                delegate: TabButton {
                  required property var modelData
                  name: modelData
                  text: modelData === "default" ? "Projects & new terminals" : Palette.pretty(modelData)
                }
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(14)

              Text {
                visible: root.hiddenCount > 0 && (root.tab === "moods" || root.tab === "wallpapers")
                text: (root.showHidden ? "Hide hidden (" : "Show hidden (") + root.hiddenCount + ")"
                color: hiddenArea.containsMouse ? root.text : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                MouseArea {
                  id: hiddenArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showHidden = !root.showHidden
                }
              }

              Text {
                visible: (root.tab === "moods" || root.tab === "themes") && root.selectedTakesWallpaper
                text: (root.withWallpaper ? "\uDB80\uDD32" : "\uDB80\uDD31") + " with its wallpaper"
                color: withArea.containsMouse ? root.text : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: withArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.withWallpaper = !root.withWallpaper; root.saveConfig() }
                }
              }

              Text {
                id: appliesText
                width: Math.min(implicitWidth, root.contentWidth * 0.45)
                text: !root.selectedTerm ? ""
                : "for " + root.selectedTerm.title + (root.selectedTerm.visible ? ""
                  : " · on workspace " + root.selectedTerm.workspace + ", not on screen")
                elide: Text.ElideRight
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Column {
            visible: root.tab === "moods"
            width: parent.width
            spacing: Style.space(10)

            Text {
              visible: root.aetherBlocker !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.aetherBlocker
              color: root.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // Wallpapers to draw moods from; the current one comes first.
            Flickable {
              visible: root.catalog.aether
              width: parent.width
              height: Style.space(54)
              contentWidth: sourceRow.implicitWidth
              contentHeight: height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Row {
                id: sourceRow
                spacing: Style.space(8)

                Repeater {
                  model: root.opened && root.tab === "moods" ? root.moodSources : []

                  delegate: Rectangle {
                    id: sourceTile
                    required property var modelData
                    readonly property bool chosen: modelData === root.activeMoodSource
                    width: Style.space(96)
                    height: Style.space(54)
                    radius: Style.cornerRadius
                    color: root.themeBackground
                    border.width: Math.max(1, Style.space(chosen ? 2 : 1))
                    border.color: chosen ? root.accent : sourceArea.containsMouse ? root.text : root.subtle
                    clip: true

                    Image {
                      anchors.fill: parent
                      anchors.margins: parent.border.width
                      source: Palette.fileUrl(sourceTile.modelData)
                      sourceSize.width: Style.space(192)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                    }

                    Rectangle {
                      visible: sourceTile.modelData === root.catalog.wallpaper
                      anchors.left: parent.left
                      anchors.bottom: parent.bottom
                      anchors.margins: Style.space(4)
                      width: nowText.implicitWidth + Style.space(8)
                      height: nowText.implicitHeight + Style.space(2)
                      radius: height / 2
                      color: Util.alpha(root.surface, 0.85)

                      Text {
                        id: nowText
                        anchors.centerIn: parent
                        text: "Current"
                        color: root.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    opacity: root.hiddenSources.indexOf(modelData) >= 0 ? 0.35 : 1

                    MouseArea {
                      id: sourceArea
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.RightButton
                      cursorShape: Qt.PointingHandCursor
                      onEntered: root.hoverText = Palette.basename(sourceTile.modelData) + " · right-click to hide"
                      onExited: root.hoverText = ""
                      onClicked: function (mouse) {
                        if (mouse.button === Qt.RightButton) {
                          if (root.hiddenSources.indexOf(sourceTile.modelData) >= 0) root.unhideSource(sourceTile.modelData)
                          else root.hideSource(sourceTile.modelData)
                        } else root.pickSource(sourceTile.modelData)
                      }
                    }
                  }
                }
              }
            }

            Text {
              visible: root.catalog.aether && root.moods.length === 0
              text: root.moodsLoading ? "Mixing moods from " + Palette.basename(root.activeMoodSource) + "…"
                : "No moods for this wallpaper."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Flickable {
              visible: root.moods.length > 0
              width: parent.width
              height: Math.min(moodFlow.implicitHeight, Style.space(220))
              contentWidth: width
              contentHeight: moodFlow.implicitHeight
              clip: true
              interactive: contentHeight > height
              boundsBehavior: Flickable.StopAtBounds

              Flow {
                id: moodFlow
                width: parent.width
                spacing: Style.space(8)

                Repeater {
                  model: root.opened && root.tab === "moods" ? root.moods : []
                  delegate: LookChip {
                    required property var modelData
                    look: modelData
                    label: Palette.pretty(modelData.id)
                    chosen: root.selectedTerm !== null && Palette.sameLook(modelData, root.selectedTerm.look)
                    ring: root.accent
                    fontFamily: root.fontFamily
                    onHoverStarted: { root.hoverText = root.describe(modelData); root.preview(root.current, modelData) }
                    onHoverEnded: { root.hoverText = ""; previewEnd.restart() }
                    onPicked: root.commitWithWallpaper(root.current, modelData)
                  }
                }
              }
            }
          }

          Flickable {
            visible: root.tab === "themes"
            width: parent.width
            height: Math.min(themeFlow.implicitHeight, Style.space(260))
            contentWidth: width
            contentHeight: themeFlow.implicitHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Flow {
              id: themeFlow
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.opened && root.tab === "themes" ? root.catalog.themes : []
                delegate: LookChip {
                  required property var modelData
                  look: modelData
                  label: Palette.pretty(modelData.id)
                  image: modelData.image || ""
                  chosen: root.selectedTerm !== null && Palette.sameLook(modelData, root.selectedTerm.look)
                  ring: root.accent
                  fontFamily: root.fontFamily
                  onHoverStarted: { root.hoverText = root.describe(modelData); root.preview(root.current, modelData) }
                  onHoverEnded: { root.hoverText = ""; previewEnd.restart() }
                  onPicked: root.commitWithWallpaper(root.current, modelData)
                }
              }
            }
          }

          // Wallpapers: Ghostty only, one config file per window.
          Column {
            visible: root.tab === "wallpapers"
            width: parent.width
            spacing: Style.space(10)

            Column {
              visible: root.wallpaperBlocker !== ""
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.wallpaperBlocker
                color: root.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              TextButton {
                visible: root.catalog.ghostty && !root.catalog.launcher
                label: setupProc.running ? "Setting up…" : "Set up Ghostty for wallpapers"
                onActivated: root.runSetup()
              }

              Text {
                visible: root.setupMessage !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.setupMessage
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Row {
              spacing: Style.space(8)
              opacity: root.selectedTakesWallpaper ? 1 : 0.4

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Strength"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: Palette.STRENGTHS
                delegate: TextButton {
                  required property var modelData
                  label: modelData.name
                  chosen: root.strength === modelData.value
                  onActivated: root.setStrength(modelData.value)
                }
              }
            }

            Flickable {
              width: parent.width
              height: Math.min(wallFlow.implicitHeight, Style.space(250))
              contentWidth: width
              contentHeight: wallFlow.implicitHeight
              clip: true
              interactive: contentHeight > height
              boundsBehavior: Flickable.StopAtBounds
              opacity: root.selectedTakesWallpaper ? 1 : 0.4

              Flow {
                id: wallFlow
                width: parent.width
                spacing: Style.space(8)

                Repeater {
                  model: root.opened && root.tab === "wallpapers" ? [""].concat(root.wallpaperChoices) : []

                  delegate: Rectangle {
                    id: wallTile
                    required property var modelData
                    readonly property bool chosen: root.selectedTerm !== null
                      && (root.selectedTerm.wallpaper ? root.selectedTerm.wallpaper.path === modelData : modelData === "")
                    width: Style.space(128)
                    height: Style.space(72)
                    radius: Style.cornerRadius
                    color: root.themeBackground
                    border.width: Math.max(1, Style.space(chosen ? 2 : 1))
                    border.color: chosen ? root.accent : wallArea.containsMouse ? root.text : root.subtle
                    clip: true

                    Image {
                      visible: wallTile.modelData !== ""
                      anchors.fill: parent
                      anchors.margins: parent.border.width
                      source: wallTile.modelData ? Palette.fileUrl(wallTile.modelData) : ""
                      sourceSize.width: Style.space(256)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                    }

                    Text {
                      visible: wallTile.modelData === ""
                      anchors.centerIn: parent
                      text: "None"
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    opacity: wallTile.modelData && root.hiddenSources.indexOf(wallTile.modelData) >= 0 ? 0.35 : 1

                    MouseArea {
                      id: wallArea
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.RightButton
                      cursorShape: root.selectedTakesWallpaper ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onEntered: {
                        root.hoverText = wallTile.modelData ? Palette.basename(wallTile.modelData) : "No wallpaper"
                        if (root.selectedTakesWallpaper)
                          root.previewWallpaper(root.current, wallTile.modelData ? { path: wallTile.modelData, strength: root.strength } : null)
                      }
                      onExited: { root.hoverText = ""; previewEnd.restart() }
                      onClicked: function (mouse) {
                        if (mouse.button === Qt.RightButton && wallTile.modelData) {
                          if (root.hiddenSources.indexOf(wallTile.modelData) >= 0) root.unhideSource(wallTile.modelData)
                          else root.hideSource(wallTile.modelData)
                        } else if (root.selectedTakesWallpaper)
                          root.setWallpaper(root.current, wallTile.modelData ? { path: wallTile.modelData, strength: root.strength } : null)
                      }
                    }
                  }
                }
              }
            }
          }

          // What newly opened terminals get.
          Column {
            visible: root.tab === "default"
            width: parent.width
            spacing: Style.space(10)

            Text {
              text: "By project folder"
              color: root.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "A terminal working inside one of these folders gets that project's look. "
                + (root.selectedTerm && (root.selectedTerm.root || root.selectedTerm.cwd)
                  ? "The selected terminal is in " + (root.selectedTerm.root || root.selectedTerm.cwd) + "." : "")
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              spacing: Style.space(10)
              TextButton {
                label: root.selectedTerm && (root.selectedTerm.root || root.selectedTerm.cwd)
                  ? "Use this look for " + Palette.basename(root.selectedTerm.root || root.selectedTerm.cwd) : "Use this look for its folder"
                opacity: root.selectedTerm && (root.selectedTerm.look || root.selectedTerm.wallpaper) && (root.selectedTerm.root || root.selectedTerm.cwd) ? 1 : 0.4
                onActivated: root.saveProjectFrom(root.selectedTerm)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "or press F"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(8)
              Repeater {
                model: root.opened && root.tab === "default" ? root.projects : []
                delegate: Rectangle {
                  id: ruleChip
                  required property var modelData
                  readonly property string accentHex: Palette.lookAccent(modelData.look) || root.accentHex
                  width: ruleRow.implicitWidth + Style.space(16)
                  height: ruleRow.implicitHeight + Style.space(8)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(accentHex, 0.7)

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.hoverText = ruleChip.modelData.path
                    onExited: root.hoverText = ""
                  }

                  Row {
                    id: ruleRow
                    anchors.centerIn: parent
                    spacing: Style.space(8)
                    Rectangle { width: Style.space(10); height: width; radius: width / 2; color: ruleChip.accentHex; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                      text: Palette.basename(ruleChip.modelData.path) + "  " + root.ruleLabel(ruleChip.modelData)
                      color: root.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      text: "\u00d7"
                      color: removeArea.containsMouse ? root.text : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      MouseArea {
                        id: removeArea
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.removeProject(ruleChip.modelData.path)
                      }
                    }
                  }
                }
              }
            }

            Rectangle { width: parent.width; height: Math.max(1, Style.space(1)); color: root.subtle }

            Text {
              text: "When a new terminal opens, give it:"
              color: root.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              spacing: Style.space(8)

              TextButton {
                label: "Its own colors"
                chosen: root.newDefault.mode === "none"
                onActivated: root.setDefaultMode("none")
              }
              TextButton {
                label: "A different tint each"
                chosen: root.newDefault.mode === "auto"
                onActivated: root.setDefaultMode("auto")
              }
              TextButton {
                label: "A saved look"
                chosen: root.newDefault.mode === "look"
                onActivated: root.setDefaultMode("look")
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.newDefault.mode === "auto"
                ? "Each new terminal gets the tint the fewest open terminals have, so new agents never look alike."
                : root.newDefault.mode === "look"
                  ? "New terminals open as " + root.defaultLabel + "."
                  : "New terminals keep their usual colors."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              spacing: Style.space(10)

              TextButton {
                label: root.selectedTerm ? "Save the look of \u201c" + root.selectedTerm.title.slice(0, 40) + "\u201d as the default" : "Save as default"
                opacity: root.selectedTerm && (root.selectedTerm.look || root.selectedTerm.wallpaper) ? 1 : 0.4
                onActivated: if (root.selectedTerm) root.saveDefaultFrom(root.selectedTerm)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "or press D"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: root.hoverText
              || "Click a card to select · hover to preview · click to keep · 1–8 tint · 0 clear · Space next · Tab switch tabs · W mood wallpaper · X hide it · H show hidden · D default · F folder · B borders · P pulse · T text shadow · Esc"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
