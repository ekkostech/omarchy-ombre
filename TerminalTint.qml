import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Palette.js" as Palette

// Terminal Tint: pick a background tint for any running terminal window.
// The tint is sent to the window's pty as OSC 11, so the program inside keeps
// running untouched; the window border can follow the same hue.
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
  property var known: ({})   // pty -> {pid, value} for tints set this session

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
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int pad: Style.spacing.panelPadding
  readonly property int gap: Style.space(12)
  readonly property int swatchSize: Style.space(20)
  readonly property int cardWidth: Style.space(280)
  readonly property int columns: Math.max(1, Math.min(terminals.length, 4))

  // ---- Shell lifecycle --------------------------------------------------
  function open(payloadJson) {
    root.opened = true
    root.focusOnScan = true
    root.scan()
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

  // Scripting entry point: omarchy-shell shell call <id> apply '<json>'
  //   {"value": "red" | "#203040" | "next" | "reset", "target": "focused" | "title:TEXT" | "pid:N" | "address:HEX" | "all"}
  // A bare string such as "red" tints the focused terminal.
  function apply(arg) {
    var req
    try { req = JSON.parse(arg) } catch (e) { req = { value: String(arg || "").trim() } }
    if (!req || typeof req !== "object") return "error: bad request"
    var value = String(req.value || "")
    if (value !== "next" && value !== "reset" && !Palette.isValue(value))
      return "error: unknown color " + value
    root.requests = root.requests.concat([{ value: value, target: String(req.target || "focused") }])
    root.scan()
    return "ok"
  }

  // The terminals from the latest scan, and starts a fresh one for next time.
  function state(arg) {
    root.scan()
    return JSON.stringify({
      opened: root.opened,
      current: root.current,
      borders: root.borders,
      terminals: root.terminals.map(function (t) {
        return { pty: t.pty, pid: t.pid, address: "0x" + t.address, workspace: t.workspace, title: t.title, tint: t.value }
      })
    })
  }

  function setBorders(enabled) {
    root.borders = enabled === true || enabled === "true"
    root.saveConfig()
    root.reapply()
    return "ok"
  }

  // ---- Scanning ---------------------------------------------------------
  function scan() {
    if (scanner.running) { root.rescan = true; return }
    scanner.running = true
  }

  // A scan that started before a tint was set must not bring back the old one,
  // so tints set this session win over what the scan read from disk.
  function parseScan(output) {
    var a = output.indexOf("\n@@PS@@\n")
    var b = output.indexOf("\n@@STATE@@\n")
    if (a < 0 || b < 0) return null
    var list = Palette.terminals(output.slice(0, a), output.slice(a + 8, b), output.slice(b + 11))
    for (var i = 0; i < list.length; i++) {
      var k = root.known[list[i].pty]
      if (k && k.pid === list[i].pid) list[i].value = k.value
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

    var queued = root.requests
    root.requests = []
    for (var i = 0; i < queued.length; i++) {
      var hits = Palette.match(list, queued[i].target)
      for (var j = 0; j < hits.length; j++) {
        var v = queued[i].value
        if (v === "next") v = root.nextValue(hits[j].value)
        root.commit(root.indexOf(hits[j].pty), v === "reset" ? "" : v)
      }
    }
    if (root.rescan) { root.rescan = false; root.scan() }
  }

  function indexOf(pty) {
    for (var i = 0; i < root.terminals.length; i++) if (root.terminals[i].pty === pty) return i
    return -1
  }

  function nextValue(value) {
    var i = Palette.hueIndex(value)
    return Palette.HUES[(i + 1) % Palette.HUES.length].id
  }

  // ---- Applying tints ---------------------------------------------------
  function send(line) {
    if (writer.running) writer.write(line + "\n")
  }

  function show(term, value) {
    var color = Palette.background(value, root.themeBackground)
    if (Palette.isHex(color)) root.send("show " + term.pty + " " + color)
    else root.send("default " + term.pty)
    root.paintBorder(term, value)
  }

  function paintBorder(term, value) {
    if (!term.address) return
    var hue = root.borders ? Palette.accent(value) : ""
    Hyprland.dispatch(Palette.borderCommand("active_border_color", term.address, hue, "ff"))
    Hyprland.dispatch(Palette.borderCommand("inactive_border_color", term.address, hue, "99"))
  }

  function commit(index, value) {
    if (index < 0 || index >= root.terminals.length) return
    var term = root.terminals[index]
    if (root.previewPty === term.pty) root.previewPty = ""
    var color = Palette.background(value, root.themeBackground)
    if (Palette.isHex(color)) root.send("set " + term.pty + " " + term.pid + " " + color + " " + value)
    else root.send("clear " + term.pty)
    root.paintBorder(term, value)

    var saved = Palette.isHex(color) ? value : ""
    var next = root.terminals.slice()
    next[index] = Object.assign({}, term, { value: saved })
    root.terminals = next
    var known = Object.assign({}, root.known)
    known[term.pty] = { pid: term.pid, value: saved }
    root.known = known
  }

  function preview(index, value) {
    if (index < 0 || index >= root.terminals.length) return
    previewEnd.stop()
    var term = root.terminals[index]
    if (root.previewPty && root.previewPty !== term.pty) root.endPreview()
    root.previewPty = term.pty
    root.show(term, value)
  }

  function endPreview() {
    previewEnd.stop()
    if (!root.previewPty) return
    var i = root.indexOf(root.previewPty)
    root.previewPty = ""
    if (i >= 0) root.show(root.terminals[i], root.terminals[i].value)
  }

  // Re-send every saved tint: after a theme change the tint is re-derived from
  // the new background, and a Hyprland reload drops per-window border props.
  function reapply() {
    reapplyScan.running = true
  }

  function onReapplyScan(output) {
    var list = root.parseScan(output)
    if (!list) return
    for (var i = 0; i < list.length; i++) {
      if (!list[i].value) continue
      root.show(list[i], list[i].value)
    }
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

  readonly property string scanScript:
    'hyprctl -j clients; printf "\\n@@PS@@\\n"; ps -e -o pid=,ppid=,tty=; printf "\\n@@STATE@@\\n"; '
    + 'for f in "$1"/pts-*; do [ -f "$f" ] && printf "%s %s\\n" "${f##*/}" "$(cat "$f")"; done; true'

  // One long-lived writer keeps escape sequences in order while the pointer
  // sweeps across swatches. Lines: show|set|default|clear PTY [PID] [COLOR] [VALUE].
  readonly property string writerScript:
    'mkdir -p "$1"; d="$1"\n'
    + 'while read -r op pty a b c; do\n'
    + '  case "$pty" in pts/[0-9]*) ;; *) continue ;; esac\n'
    + '  dev="/dev/$pty"; f="$d/pts-${pty#pts/}"\n'
    + '  case "$op" in\n'
    + "    show) printf '\\033]11;%s\\033\\\\' \"$a\" > \"$dev\" ;;\n"
    + "    set) printf '\\033]11;%s\\033\\\\' \"$b\" > \"$dev\" && printf '%s %s\\n' \"$a\" \"$c\" > \"$f\" ;;\n"
    + "    default) printf '\\033]111\\033\\\\' > \"$dev\" ;;\n"
    + "    clear) printf '\\033]111\\033\\\\' > \"$dev\"; rm -f \"$f\" ;;\n"
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

  Process { id: configWriter }

  Process {
    id: configReader
    running: true
    command: ["cat", root.configFile]
    stdout: StdioCollector { onStreamFinished: root.onConfig(text) }
  }

  Timer { id: reapplyLater; interval: 1500; onTriggered: root.reapply() }

  // Sliding between neighbouring swatches should not flash the saved tint.
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
      color: swatch.value ? Palette.accent(swatch.value) : root.themeBackground
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
      onEntered: { root.current = swatch.termIndex; root.preview(swatch.termIndex, swatch.value) }
      onExited: previewEnd.restart()
      onClicked: root.commit(swatch.termIndex, swatch.value)
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
          if (k === Qt.Key_Escape || k === Qt.Key_Return || k === Qt.Key_Enter) root.dismiss()
          else if (n === 0) return
          else if (k === Qt.Key_Right || k === Qt.Key_L || (k === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)))
            root.current = (root.current + 1) % n
          else if (k === Qt.Key_Left || k === Qt.Key_H || k === Qt.Key_Backtab)
            root.current = (root.current - 1 + n) % n
          else if (k === Qt.Key_Down || k === Qt.Key_J)
            root.current = Math.min(n - 1, root.current + root.columns)
          else if (k === Qt.Key_Up || k === Qt.Key_K)
            root.current = Math.max(0, root.current - root.columns)
          else if (k >= Qt.Key_1 && k <= Qt.Key_8)
            root.commit(root.current, Palette.HUES[k - Qt.Key_1].id)
          else if (k === Qt.Key_0 || k === Qt.Key_Backspace || k === Qt.Key_Delete)
            root.commit(root.current, "")
          else if (k === Qt.Key_Space || k === Qt.Key_N)
            root.commit(root.current, root.nextValue(root.terminals[root.current].value))
          else if (k === Qt.Key_B)
            root.setBorders(!root.borders)
          else return
          event.accepted = true
        }

        Column {
          id: content
          spacing: root.gap

          Item {
            width: Math.max(grid.implicitWidth, Style.space(420))
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
            width: Style.space(420)
            wrapMode: Text.WordWrap
            text: scanner.running ? "Looking for terminals…"
              : "No terminal windows found. Terminal Tint works with terminals that run one process per window (foot, Alacritty, Kitty)."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

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

                width: root.cardWidth
                height: tileColumn.implicitHeight + Style.space(10) * 2
                radius: Style.cornerRadius
                color: selected ? Color.menu.selectedBackground : "transparent"
                border.width: Math.max(1, Style.space(selected ? 2 : 1))
                border.color: selected ? root.accent : root.subtle

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
                    color: Palette.background(tile.modelData.value, root.themeBackground) || root.themeBackground
                    border.width: Math.max(1, Style.space(2))
                    border.color: Palette.accent(tile.modelData.value) || root.subtle
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

                  Text {
                    width: parent.width
                    text: tile.modelData.title
                    elide: Text.ElideRight
                    color: root.text
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Row {
                    spacing: Style.space(7)

                    Repeater {
                      model: Palette.HUES
                      delegate: Swatch {
                        required property var modelData
                        value: modelData.id
                        termIndex: tile.index
                        chosen: tile.modelData.value === modelData.id
                      }
                    }

                    Swatch {
                      value: ""
                      termIndex: tile.index
                      chosen: tile.modelData.value === ""
                    }
                  }
                }
              }
            }
          }

          Text {
            text: "Hover to preview · click to keep · 1–8 pick · 0 clear · arrows move · B borders · Esc closes"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
