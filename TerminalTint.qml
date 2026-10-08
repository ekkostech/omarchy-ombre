import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Palette.js" as Palette

// Terminal Tint: give any running terminal window its own look: a background
// tint, an Aether mood generated from a wallpaper, or a whole Omarchy theme.
// Looks are escape sequences written to the window's pty (OSC 4/10/11/12), so
// the program inside keeps running untouched; the window border can follow.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "ekkostech.terminal-tint"

  property bool opened: false
  property var terminals: []
  property int current: 0
  property string previewPty: ""
  property bool borders: true
  property bool focusOnScan: false
  property bool rescan: false
  property var requests: []
  property var known: ({})   // pty -> {pid, look} for looks set this session

  // Catalog of moods and themes, refreshed whenever the picker opens.
  property var catalog: ({ wallpaper: "", aether: false, modes: [], wallpapers: [], themes: [] })
  property bool catalogLoaded: false
  property string tab: "moods"
  property string moodSource: ""
  property var moodCache: ({})
  property var moodQueue: []
  property string moodRunning: ""
  property string hoverText: ""

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/terminal-tint"
  readonly property string configFile:
    (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/omarchy/terminal-tint.json"

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
  readonly property var moodSources: {
    var out = []
    if (catalog.wallpaper) out.push(catalog.wallpaper)
    for (var i = 0; i < catalog.wallpapers.length; i++)
      if (out.indexOf(catalog.wallpapers[i]) < 0) out.push(catalog.wallpapers[i])
    return out
  }
  readonly property string activeMoodSource: moodSource || catalog.wallpaper
  readonly property var moods: moodCache[moodKey(activeMoodSource)] || []
  readonly property bool moodsLoading: moodRunning !== "" || moodQueue.length > 0

  // ---- Shell lifecycle --------------------------------------------------
  function open(payloadJson) {
    root.opened = true
    root.focusOnScan = true
    root.hoverText = ""
    root.scan()
    root.loadCatalog()
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
  // apply '{"value": V, "target": T}', or a bare value for the focused terminal.
  //   V: red | #203040 | next | reset | mood:fire | mood:fire@/path/wall.jpg | theme:tokyo-night
  //   T: focused | title:TEXT | pid:N | address:HEX | all
  function apply(arg) {
    var req
    try { req = JSON.parse(arg) } catch (e) { req = { value: String(arg || "").trim() } }
    if (!req || typeof req !== "object") return "error: bad request"
    var value = String(req.value || "")
    if (!root.validSpec(value)) return "error: unknown look " + value
    root.requests = root.requests.concat([{ value: value, target: String(req.target || "focused") }])
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
                 title: t.title, kind: t.look ? t.look.kind : "", look: Palette.lookLabel(t.look) }
      })
    })
  }

  // Moods and themes available to `apply`.
  function looks(arg) {
    return JSON.stringify({
      moods: root.catalog.modes.map(function (m) { return m.id }),
      themes: root.catalog.themes.map(function (t) { return t.id }),
      wallpaper: root.catalog.wallpaper
    })
  }

  function setBorders(enabled) {
    root.borders = enabled === true || enabled === "true"
    root.saveConfig()
    root.reapply()
    return "ok"
  }

  function validSpec(v) {
    return v === "next" || v === "reset" || Palette.tintLook(v) !== null
      || /^mood:[a-z0-9-]+(@\/.+)?$/.test(v) || /^theme:[A-Za-z0-9._-]+$/.test(v)
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
      var r = root.resolveSpec(req.value)
      if (r.wait) { waiting.push(req); continue }
      if (r.error) { console.warn("terminal-tint:", r.error); continue }
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
    if (a < 0 || b < 0) return null
    var list = Palette.terminals(output.slice(0, a), output.slice(a + 8, b), output.slice(b + 11))
    for (var i = 0; i < list.length; i++) {
      var k = root.known[list[i].pty]
      if (k && k.pid === list[i].pid) list[i].look = k.look
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
    if (root.moodSource && root.moodSources.indexOf(root.moodSource) < 0) root.moodSource = ""
    if (!c.aether && root.tab === "moods") root.tab = "themes"
    if (root.opened && c.aether) root.ensureMoods(root.activeMoodSource)
    if (root.requests.length > 0) root.scan()
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
    Hyprland.dispatch(Palette.borderCommand("active_border_color", term.address, color, "ff"))
    Hyprland.dispatch(Palette.borderCommand("inactive_border_color", term.address, color, "99"))
  }

  function commit(index, look) {
    if (index < 0 || index >= root.terminals.length) return
    var term = root.terminals[index]
    look = Palette.normalizeLook(look)
    if (root.previewPty === term.pty) root.previewPty = ""
    root.show(term, look)
    if (look) root.send("save " + term.pty + " " + JSON.stringify({ pid: term.pid, look: look }))
    else root.send("forget " + term.pty)

    var next = root.terminals.slice()
    next[index] = Object.assign({}, term, { look: look })
    root.terminals = next
    var known = Object.assign({}, root.known)
    known[term.pty] = { pid: term.pid, look: look }
    root.known = known
  }

  function preview(index, look) {
    if (index < 0 || index >= root.terminals.length) return
    previewEnd.stop()
    var term = root.terminals[index]
    if (root.previewPty && root.previewPty !== term.pty) root.endPreview()
    root.previewPty = term.pty
    root.show(term, Palette.normalizeLook(look))
  }

  function endPreview() {
    previewEnd.stop()
    if (!root.previewPty) return
    var i = root.indexOf(root.previewPty)
    root.previewPty = ""
    if (i >= 0) root.show(root.terminals[i], root.terminals[i].look)
  }

  // Space and Shift+Space walk the list on the open tab for the selected terminal.
  function stepLook(delta) {
    var term = root.selectedTerm
    if (!term) return
    var list = root.tab === "moods" ? root.moods : root.catalog.themes
    if (list.length === 0) return
    var i = -1
    for (var k = 0; k < list.length; k++) if (Palette.sameLook(list[k], term.look)) i = k
    var next = i < 0 ? (delta > 0 ? 0 : list.length - 1) : (i + delta + list.length) % list.length
    root.commit(root.current, list[next])
    root.hoverText = root.describe(list[next])
  }

  function describe(look) {
    if (!look) return ""
    if (look.kind === "mood") return Palette.pretty(look.id) + " — " + (look.description || "")
    return Palette.pretty(look.id)
  }

  // Re-send every saved look: after a theme change tints are re-derived from
  // the new background, and a Hyprland reload drops per-window border props.
  function reapply() {
    reapplyScan.running = true
  }

  function onReapplyScan(output) {
    var list = root.parseScan(output)
    if (!list) return
    for (var i = 0; i < list.length; i++) if (list[i].look) root.show(list[i], list[i].look)
    if (root.opened) root.terminals = list
  }

  function toplevelFor(address) {
    var list = Hyprland.toplevels.values
    for (var i = 0; i < list.length; i++) if (list[i].address === address) return list[i].wayland
    return null
  }

  // ---- Config -----------------------------------------------------------
  function saveConfig() {
    configWriter.command = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1"',
      "sh", root.configFile, JSON.stringify({ borders: root.borders })]
    configWriter.running = true
  }

  function onConfig(text) {
    try {
      var cfg = JSON.parse(text)
      if (cfg && typeof cfg.borders === "boolean") root.borders = cfg.borders
    } catch (e) { }
  }

  // ---- Processes --------------------------------------------------------
  readonly property string scanScript:
    'hyprctl -j clients; printf "\\n@@PS@@\\n"; ps -e -o pid=,ppid=,tty=; printf "\\n@@STATE@@\\n"; '
    + 'for f in "$1"/pts-*; do [ -f "$f" ] && printf "%s %s\\n" "${f##*/}" "$(cat "$f")"; done; true'

  readonly property string catalogScript:
    'printf "@@WALLPAPER %s\\n" "$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null)"\n'
    + 'if command -v aether >/dev/null 2>&1; then\n'
    + '  printf "@@MODES\\n"; aether --list-modes 2>/dev/null\n'
    + '  printf "@@WALLPAPERS\\n"; aether --list-wallpapers --json 2>/dev/null\n'
    + 'fi\n'
    + 'for d in "${OMARCHY_PATH:-/usr/share/omarchy}"/themes/*/ "$HOME"/.config/omarchy/themes/*/; do\n'
    + '  [ -f "$d/colors.toml" ] || continue\n'
    + '  n=${d%/}; n=${n##*/}\n'
    + '  bg=$(ls -1 "$d"backgrounds/* 2>/dev/null | head -n 1)\n'
    + '  printf "@@THEME %s\\t%s\\n" "$n" "$bg"; cat "$d/colors.toml"; printf "\\n"\n'
    + 'done\n'
    + 'true\n'

  // Every mode at once, a few at a time; Aether takes ~80 ms per palette.
  readonly property string moodScript:
    'src=$1; light=$2; shift 2\n'
    + 'tmp=$(mktemp -d) || exit 1\n'
    + 'trap \'rm -rf "$tmp"\' EXIT\n'
    + 'printf "%s\\n" "$@" | xargs -P 6 -I{} sh -c \'aether --extract-palette "$1" --extract-mode "$2" --json $3 > "$4/$2" 2>/dev/null\' sh "$src" {} "$light" "$tmp"\n'
    + 'for m in "$@"; do printf "@@MODE %s\\n" "$m"; cat "$tmp/$m" 2>/dev/null; printf "\\n"; done\n'

  // One long-lived writer keeps escape sequences in order while the pointer
  // sweeps across swatches. Lines: "write PTY SEQUENCE", "save PTY JSON",
  // "forget PTY". Sequences are built only from validated hex colors.
  readonly property string writerScript:
    'mkdir -p "$1"; d=$1\n'
    + 'while IFS= read -r line; do\n'
    + '  op=${line%% *}; rest=${line#* }; pty=${rest%% *}; arg=${rest#* }\n'
    + '  case $pty in pts/[0-9]*) ;; *) continue ;; esac\n'
    + '  dev=/dev/$pty; f=$d/pts-${pty#pts/}\n'
    + '  case $op in\n'
    + '    write) printf "%s" "$arg" > "$dev" ;;\n'
    + '    save) printf "%s\\n" "$arg" > "$f" ;;\n'
    + '    forget) rm -f "$f" ;;\n'
    + '  esac\n'
    + 'done 2>/dev/null\n'

  Process {
    id: writer
    stdinEnabled: true
    running: true
    command: ["sh", "-c", root.writerScript, "sh", root.runtimeDir]
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

  Process { id: configWriter }

  Process {
    id: configReader
    running: true
    command: ["cat", root.configFile]
    stdout: StdioCollector { onStreamFinished: root.onConfig(text) }
  }

  Timer { id: reapplyLater; interval: 1500; onTriggered: root.reapply() }

  // Sliding between neighbouring swatches should not flash the saved look.
  Timer { id: previewEnd; interval: 80; onTriggered: root.endPreview() }

  Connections {
    target: Color
    function onBackgroundChanged() { reapplyLater.restart() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") reapplyLater.restart()
    }
  }

  Component.onCompleted: root.loadCatalog()

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
      onEntered: { root.current = swatch.termIndex; root.preview(swatch.termIndex, Palette.tintLook(swatch.value)) }
      onExited: previewEnd.restart()
      onClicked: root.commit(swatch.termIndex, Palette.tintLook(swatch.value))
    }
  }

  component TabButton: Text {
    id: tabButton
    property string name: ""
    property bool enabledTab: true
    color: root.tab === name ? root.text : tabArea.containsMouse ? root.text : root.muted
    opacity: enabledTab ? 1 : 0.4
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
      onClicked: if (tabButton.enabledTab) root.tab = tabButton.name
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
    WlrLayershell.namespace: "omarchy-terminal-tint"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }

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
          else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            if (root.catalog.aether) root.tab = root.tab === "moods" ? "themes" : "moods"
          }
          else if (k === Qt.Key_W && root.tab === "moods") root.stepSource(shift ? -1 : 1)
          else if (k === Qt.Key_B) root.setBorders(!root.borders)
          else if (n === 0) return
          else if (k === Qt.Key_Right || k === Qt.Key_L) root.current = (root.current + 1) % n
          else if (k === Qt.Key_Left || k === Qt.Key_H) root.current = (root.current - 1 + n) % n
          else if (k === Qt.Key_Down || k === Qt.Key_J) root.current = Math.min(n - 1, root.current + root.columns)
          else if (k === Qt.Key_Up || k === Qt.Key_K) root.current = Math.max(0, root.current - root.columns)
          else if (k >= Qt.Key_1 && k <= Qt.Key_8) root.commit(root.current, Palette.tintLook(Palette.HUES[k - Qt.Key_1].id))
          else if (k === Qt.Key_0 || k === Qt.Key_Backspace || k === Qt.Key_Delete) root.commit(root.current, null)
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
              text: "Terminal Tint"
              color: root.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
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

          Text {
            visible: root.terminals.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: scanner.running ? "Looking for terminals…"
              : "No terminal windows found. Terminal Tint works with terminals that run one process per window (foot, Alacritty, Kitty)."
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

                  MouseArea { anchors.fill: parent; onClicked: root.current = tile.index }

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
                        text: tile.look && tile.look.kind !== "tint" ? Palette.lookLabel(tile.look) : ""
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

          // Moods and themes apply to the selected terminal.
          Item {
            width: parent.width
            height: Math.max(moodsTab.implicitHeight, appliesText.implicitHeight) + Style.space(5)

            Row {
              spacing: Style.space(18)
              TabButton { id: moodsTab; name: "moods"; text: "Moods"; enabledTab: root.catalog.aether }
              TabButton { name: "themes"; text: "Themes" }
            }

            Text {
              id: appliesText
              anchors.right: parent.right
              width: Math.min(implicitWidth, parent.width * 0.6)
              text: root.selectedTerm ? "for " + root.selectedTerm.title : ""
              elide: Text.ElideRight
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Column {
            visible: root.tab === "moods"
            width: parent.width
            spacing: Style.space(10)

            Text {
              visible: !root.catalog.aether && root.catalogLoaded
              text: "Moods come from Aether, which isn't installed."
              color: root.muted
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
                  model: root.opened ? root.moodSources : []

                  delegate: Rectangle {
                    id: sourceTile
                    required property var modelData
                    required property int index
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

                    MouseArea {
                      id: sourceArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: root.hoverText = Palette.basename(sourceTile.modelData)
                      onExited: root.hoverText = ""
                      onClicked: root.pickSource(sourceTile.modelData)
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
                    onPicked: root.commit(root.current, modelData)
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
                  onPicked: root.commit(root.current, modelData)
                }
              }
            }
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: root.hoverText
              || "Hover to preview · click to keep · 1–8 tint · 0 clear · Space next look · Tab moods/themes · W wallpaper · B borders · Esc"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
