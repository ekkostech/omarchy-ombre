import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Palette.js" as Palette
import "Workspace.js" as Workspace

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
  readonly property string pluginVersion: (manifest && manifest.version) || ""

  property bool opened: false
  property var terminals: []
  property var sessionLabels: ({})
  property string sessionMessage: ""
  property int current: 0
  property string previewPty: ""
  property var previewLook: null
  property string applyScope: "all"
  property var savedLooks: []
  property bool favoritesOnly: false
  property string libraryMessage: ""
  property string editingSavedName: ""
  property string pendingDeleteName: ""
  property var histories: ({})
  property bool historyMuted: false
  property string searchText: ""
  property bool workspaceOnly: false
  property string openingWorkspace: ""
  property var markedKeys: []
  readonly property var filteredTerminals: Workspace.filtered(terminals, searchText, workspaceOnly ? openingWorkspace : "")
  readonly property var sortedLooks: Workspace.sorted(savedLooks, favoritesOnly)
  readonly property var favoriteLooks: Workspace.sorted(savedLooks, true)
  readonly property var actionTargets: Workspace.targets(terminals, filteredTerminals, markedKeys, current)
  readonly property bool targetTakesWallpaper: actionTargets.some(function (i) { return terminals[i] && terminals[i].wallpaperReady })
  readonly property var selectedHistory: selectedTerm ? histories[Workspace.key(selectedTerm)] || {past: [], future: []} : ({past: [], future: []})
  onSearchTextChanged: resetFilterSelection()
  onWorkspaceOnlyChanged: resetFilterSelection()
  property string previewWallpaperPty: ""
  property bool focusOnScan: false
  property bool rescan: false
  property var requests: []
  property var known: ({})   // pty -> {pid, look, wallpaper} set this session

  // Settings kept in ~/.config/omarchy/ombre.json.
  property bool borders: true
  // The theme's own border colors, put back on a window when it has no look (see Palette.borderCommand).
  property var themeBorders: ({ active: "", inactive: "" })
  property bool pulse: true
  // Ghostty windows fully opaque, so Omarchy's slight transparency doesn't let the desktop
  // show through a terminal's wallpaper. solidOriginal keeps each window's own values.
  property bool solid: true
  property var solidOriginal: ({})
  property bool solidLoaded: false
  property var agentThemeStatus: ({ linked: false, canUnlink: false, errors: [] })
  property string agentThemeMessage: ""
  property string agentThemeAction: "status"
  property bool textShadow: false
  property bool glass: false           // coloured cell backgrounds as frosted glass (Ghostty wallpaper windows)
  property string glassColor: "auto"   // "auto" follows each terminal's look, or #rrggbb
  property int glassTint: Palette.GLASS_TINT
  property int glassBlur: Palette.GLASS_BLUR
  property bool focusMode: false
  function setFocusMode(on) {focusMode=on===true || on==="true";scan();return "ok"}
  property bool followSessions: true
  property var privacyKeys: []
  property var scenes: []
  property var batchPast: []
  property var batchFuture: []
  property bool batchMuted: false
  property var followSeen: ({})
  property string studioMessage: ""
  property var signalStates: ({})
  function signalFor(t) {
    var explicit=signalStates[Workspace.key(t)] || t.signal
    if(explicit)return explicit
    if(/[◐◓◑◒⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/.test(t.paneTitle || t.title))return "working"
    if(/✳/.test(t.paneTitle || t.title))return "done"
    return t.command || "terminal"
  }
  function selectSession(t) {
    for(var i=0;i<terminals.length;i++)if(Workspace.key(terminals[i])===Workspace.key(t)){current=i;searchText="";break}
    if(t.sessionId && !t.attached)sessionAction({op:"attach",sessionId:t.sessionId});else jumpSession()
  }
  function jumpSignal() {
    for(var i=1;i<=terminals.length;i++){
      var n=(current+i)%terminals.length, status=signalFor(terminals[n])
      if(status==="done" || status==="input" || status==="error"){current=n;searchText="";jumpSession();return}
    }
    studioMessage="No sessions are waiting."
  }
  function signal(json) {
    var req;try{req=JSON.parse(json)}catch(e){return "error: invalid signal"}
    if(["working","done","input","error"].indexOf(req.status)<0)return "error: unknown status"
    var found=false,next=Object.assign({},signalStates)
    for(var i=0;i<terminals.length;i++){
      var t=terminals[i]
      if(String(t.pid)===String(req.pid) || (req.sessionId && t.sessionId===req.sessionId)){
        next[Workspace.key(t)]=req.status;found=true
        if(t.sessionId)sessionAction({op:"signal",sessionId:t.sessionId,status:req.status})
        var address=t.hostAddress || t.address
        if(address && req.status!=="working")startPulse(Object.assign({},t,{address:address}))
      }
    }
    signalStates=next
    return found?"ok":"error: session not found"
  }
  function refreshEffects(before) {
    var list=terminals.slice()
    for(var i=0;i<list.length;i++){
      list[i]=Object.assign({},list[i],{glass:glassFor(list[i]),matrix:matrixFor(list[i])})
      if(!historyMuted && before && before[i])histories=Workspace.record(histories,list[i],before[i])
    }
    terminals=list
  }
  property var comparisonState: null
  function comparePrevious(on) {
    if(on){
      if(comparisonState || !batchPast.length)return
      comparisonState=terminals.filter(function(t){return batchPast[batchPast.length-1].some(function(p){return p.key===Workspace.key(t)})}).map(function(t){return {key:Workspace.key(t),state:styleState(t)}})
      var previous=batchPast[batchPast.length-1]
    }else{
      if(!comparisonState)return
      var previous=comparisonState;comparisonState=null
    }
    batchMuted=true
    for(var i=0;i<previous.length;i++)for(var j=0;j<terminals.length;j++)if(Workspace.key(terminals[j])===previous[i].key)applyState(j,previous[i].state)
    batchMuted=false
  }
  function styleState(t) {
    return {look:t.look,wallpaper:t.wallpaper,glass:glassFor(t),matrix:matrixFor(t)}
  }
  function captureBatch(indices) {
    if(batchMuted)return
    var targets=indices || actionTargets
    if(!targets.length)return
    batchPast=batchPast.concat([targets.map(function(i){var t=terminals[i];return {key:Workspace.key(t),state:styleState(t)}})]).slice(-30)
    batchFuture=[]
  }
  function applyState(index,state) {
    var t=terminals[index]
    restoreSnapshot(index,state)
    var hosts=t.backend==="tmux"?(t.wallpaperHosts||[]):[t]
    var g=Object.assign({},glassOverrides),m=Object.assign({},matrixOverrides)
    for(var h=0;h<hosts.length;h++){
      if(state.glass)g[Workspace.key(hosts[h])]=state.glass
      if(state.matrix)m[Workspace.key(hosts[h])]=state.matrix
    }
    glassOverrides=g;matrixOverrides=m
    if(terminals[index].wallpaperReady)sendWallpaper(terminals[index],terminals[index].wallpaper)
    syncProfile(terminals[index]);saveConfig()
  }
  function travelBatch(redo) {
    var source=redo?batchFuture:batchPast
    if(!source.length)return
    var snapshot=source[source.length-1]
    var keys=snapshot.map(function(t){return t.key})
    var currentState=terminals.filter(function(t){return keys.indexOf(Workspace.key(t))>=0}).map(function(t){return {key:Workspace.key(t),state:styleState(t)}})
    if(redo){batchFuture=source.slice(0,-1);batchPast=batchPast.concat([currentState])}
    else{batchPast=source.slice(0,-1);batchFuture=batchFuture.concat([currentState])}
    batchMuted=true
    for(var i=0;i<snapshot.length;i++)for(var j=0;j<terminals.length;j++)if(Workspace.key(terminals[j])===snapshot[i].key)applyState(j,snapshot[i].state)
    batchMuted=false
  }
  function togglePrivacy() {
    var next=privacyKeys.slice()
    for(var i=0;i<actionTargets.length;i++){
      var key=Workspace.key(terminals[actionTargets[i]]),at=next.indexOf(key)
      if(at>=0)next.splice(at,1);else next.push(key)
    }
    privacyKeys=next;saveConfig()
    for(var j=0;j<actionTargets.length;j++){var t=terminals[actionTargets[j]];if(t.wallpaperReady)sendWallpaper(t,t.wallpaper)}
  }
  function clearPrivacy() {
    var previous=privacyKeys;privacyKeys=[];saveConfig()
    for(var i=0;i<terminals.length;i++)if(previous.indexOf(Workspace.key(terminals[i]))>=0 && terminals[i].wallpaperReady)sendWallpaper(terminals[i],terminals[i].wallpaper)
  }
  property var readableTargets: []
  function readableGlass() {
    if(readabilityWorker.running)return
    readableTargets=actionTargets.map(function(i){return Workspace.key(terminals[i])})
    if(!readableTargets.length)return
    var t=selectedTerm
    readabilityWorker.command=["python3",pluginDir+"/bin/ombre-readability",t && t.wallpaper?t.wallpaper.path:""]
    readabilityWorker.running=true
    studioMessage="Measuring wallpaper brightness…"
  }
  function applyReadable(text) {
    var recommendation;try{recommendation=JSON.parse(text)}catch(e){studioMessage="Could not measure the wallpaper.";return}
    captureBatch();batchMuted=true
    for(var i=0;i<terminals.length;i++){
      if(readableTargets.indexOf(Workspace.key(terminals[i]))<0)continue
      var state=styleState(terminals[i])
      state.glass={on:true,color:"smoke",tint:recommendation.tint,blur:recommendation.blur}
      state.look=Palette.foregroundLook(state.look,recommendation.foreground)
      if(state.wallpaper)state.wallpaper=Object.assign({},state.wallpaper,{strength:recommendation.strength})
      applyState(i,state)
    }
    batchMuted=false
    studioMessage="Balanced wallpaper exposure, Glass tint and text brightness. Hold Compare to inspect the change; Undo batch restores it."
  }
  Process {
    id:readabilityWorker
    stdout:StdioCollector {onStreamFinished:root.applyReadable(text)}
    onExited:function(code){if(code!==0)root.studioMessage="Wallpaper analysis failed; no changes applied."}
  }
  function saveScene(name) {
    name=Workspace.name(name);if(!name){studioMessage="Enter a scene name.";return}
    var entries=filteredTerminals.map(function(t){return {key:Workspace.key(t),sessionId:t.sessionId||"",title:t.title,cwd:t.cwd,root:t.root,label:t.label || "",layout:t.layout || "",workspace:t.workspace,hostAddress:t.hostAddress||t.address,x:t.x,y:t.y,w:t.w,h:t.h,state:styleState(t)}})
    scenes=scenes.filter(function(s){return s.name!==name}).concat([{name:name,entries:entries}])
    saveConfig();studioMessage="Scene saved: "+name
  }
  function deleteScene(name) {scenes=scenes.filter(function(s){return s.name!==name});saveConfig()}
  function restoreScene(name) {
    var scene=scenes.filter(function(s){return s.name===name})[0];if(!scene)return
    var sceneTargets=[]
    for(var si=0;si<terminals.length;si++)if(scene.entries.some(function(e){return e.key===Workspace.key(terminals[si])}))sceneTargets.push(si)
    captureBatch(sceneTargets);batchMuted=true;var restored=0,missing=0
    for(var i=0;i<scene.entries.length;i++){
      var entry=scene.entries[i],index=-1
      for(var j=0;j<terminals.length;j++)if(Workspace.key(terminals[j])===entry.key){index=j;break}
      if(index<0){missing++;continue}
      applyState(index,entry.state);restored++
      if(terminals[index].sessionId && entry.label)sessionAction({op:"label",sessionId:terminals[index].sessionId,label:entry.label})
      var hosts=terminals[index].backend==="tmux"?(terminals[index].wallpaperHosts||[]):[terminals[index]]
      for(var wh=0;wh<hosts.length;wh++)sessionAction({op:"window-layout",pid:hosts[wh].pid,started:hosts[wh].started,workspace:entry.workspace,x:entry.x,y:entry.y,w:entry.w,h:entry.h})
      if(terminals[index].sessionId)sessionAction({op:"restore-layout",sessionId:terminals[index].sessionId,layout:entry.layout,hostAddress:terminals[index].hostAddress,workspace:entry.workspace,x:entry.x,y:entry.y,w:entry.w,h:entry.h})
    }
    batchMuted=false;studioMessage="Restored "+restored+" live sessions; "+missing+" ended sessions were left untouched."
  }
  function syncProfile(t) {
    if(t && t.backend==="tmux" && followSessions) {
      var profile=styleState(t)
      if(JSON.stringify(t.profile)!==JSON.stringify(profile))sessionAction({op:"profile",sessionId:t.sessionId,profile:profile})
    }
  }
  property var matrixOverrides: ({})
  readonly property var selectedMatrix: matrixFor(selectedTerm)
  function matrixFor(term) {
    var host = term && term.backend === "tmux" ? (term.wallpaperHosts || [])[0] : term
    return matrixOverrides[Workspace.key(host)] || {on:false,size:20,blur:1,opacity:0.25,speed:1,density:0.55,paused:false}
  }
  function setMatrix(json) {
    var effectBefore=terminals.map(function(t){return styleState(t)})
    root.captureBatch()
    var patch
    try { patch = typeof json === "string" ? JSON.parse(json) : json } catch(e) { return "error: invalid Matrix settings" }
    var next = Object.assign({}, matrixOverrides)
    for (var i=0;i<actionTargets.length;i++) {
      var t=terminals[actionTargets[i]]
      var hosts=t.backend === "tmux" ? (t.wallpaperHosts || []) : [t]
      for (var h=0;h<hosts.length;h++) {
        if (!hosts[h].wallpaperReady || hosts[h].backend === "omaguake") continue
        var m=Object.assign({},matrixFor(hosts[h]),patch)
        m.on=m.on===true;m.paused=m.paused===true
        m.size=Palette.glassLevel(m.size,64,20);m.size=Math.max(8,m.size)
        m.blur=Palette.glassLevel(m.blur,12,1)
        m.opacity=Math.max(0,Math.min(1,Number(m.opacity)||0))
        m.speed=Math.max(0.1,Math.min(4,Number(m.speed)||1))
        m.density=Math.max(0.05,Math.min(1,Number(m.density)||0.55))
        next[Workspace.key(hosts[h])]=m
      }
    }
    matrixOverrides=next;refreshEffects(effectBefore);saveConfig()
    for(var j=0;j<actionTargets.length;j++){var term=terminals[actionTargets[j]];if(term.wallpaperReady)sendWallpaper(term,term.wallpaper);syncProfile(term)}
    return "ok"
  }
  function renderToken(term) {
    for(var pi=0;pi<terminals.length;pi++){
      var pt=terminals[pi]
      if(privacyKeys.indexOf(Workspace.key(pt))<0)continue
      if(Workspace.key(pt)===Workspace.key(term) || (pt.wallpaperHosts||[]).some(function(h){return Workspace.key(h)===Workspace.key(term)}))return "private"
    }
    var shadow=shadowVariant(term), m=matrixFor(term)
    if (!m.on) return shadow
    return "matrix:"+[m.size,m.blur,m.opacity,m.speed,m.density,m.paused?1:0,glassFor(term).on && term.wallpaper?1:0].join(":")+"~"+shadow
  }
  property var glassOverrides: ({})
  readonly property var selectedGlass: glassFor(selectedTerm)

  function glassFor(term) {
    var host = term && term.backend === "tmux" ? (term.wallpaperHosts || [])[0] : term
    return glassOverrides[Workspace.key(host)] || {on: glass, color: glassColor, tint: glassTint, blur: glassBlur}
  }

  function changeGlass(patch) {
    var effectBefore=terminals.map(function(t){return styleState(t)})
    root.captureBatch()
    var next = Object.assign({}, glassOverrides)
    var targets = actionTargets
    for (var i = 0; i < targets.length; i++) {
      var term = terminals[targets[i]]
      var hosts = term.backend === "tmux" ? (term.wallpaperHosts || []) : [term]
      for (var h = 0; h < hosts.length; h++) {
        if (!hosts[h].wallpaperReady || hosts[h].backend === "omaguake") continue
        next[Workspace.key(hosts[h])] = Object.assign({}, glassFor(hosts[h]), patch)
      }
    }
    glassOverrides = next
    refreshEffects(effectBefore)
    saveConfig()
    for (var j = 0; j < targets.length; j++) {
      var t = terminals[targets[j]]
      if (t.wallpaperReady) sendWallpaper(t, t.wallpaper)
      syncProfile(t)
    }
    return "ok"
  }
  property var hiddenSources: []     // wallpaper paths hidden from the strips (files untouched)
  property bool showHidden: false
  property bool reshadowAll: false
  property real strength: Palette.DEFAULT_STRENGTH
  property int blur: 0
  property string wallpaperMessage: ""
  // Images added from anywhere (PNG/JPEG files or whole folders), read by bin/ombre-images.
  property var imageSources: []        // absolute paths, in the order added
  property var collapsedFolders: []    // folded wallpaper sections: folder paths, "@builtin", "@files"
  property var imageScan: ({})         // source path -> what the scan found there
  property bool imageScanAgain: false
  property var imagesAdding: []        // sources just added, each reported on once it has been read
  property string imageApplyPath: ""   // a browsed image to put on the selected terminals once it proves real
  property bool browsing: false        // the folder browser stands in for the wallpaper grid
  property string browseFolder: ""
  onBrowseFolderChanged: browsePath.text = Palette.tildePath(browseFolder, home)
  readonly property int currentBlur: root.selectedTerm && root.selectedTerm.wallpaper ? Palette.normalizeBlur(root.selectedTerm.wallpaper.blur) : root.blur
  property bool withWallpaper: true
  property bool welcomed: false
  property bool configLoaded: false

  // Catalog of moods, themes and wallpapers, refreshed whenever the picker opens.
  property var catalog: ({ wallpaper: "", aether: false, ghostty: false, launcher: false, modes: [], wallpapers: [], themes: [], own: [], places: [] })
  property bool catalogLoaded: false
  property real catalogAt: 0
  property string tab: "moods"
  // The picker shows either styling (terminals + tabs) or its settings.
  property string view: "style"
  property string settingsSection: "windows"
  // Moods follow the theme (auto) or are always made dark or light.
  property string moodTone: "auto"
  readonly property bool moodLight: moodTone === "light" || (moodTone === "auto" && lightTheme)
  // Palettes Aether makes from one colour (bin/ombre-colour), per base colour.
  property string baseColour: "#3e63dd"
  property var colourCache: ({})
  property var colourQueue: []
  property string colourRunning: ""
  property string colourMessage: ""
  readonly property var colourLooks: colourCache[baseColour] || []
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
  readonly property color surface: Commons.Color.menu.background
  readonly property color text: Commons.Color.menu.text
  readonly property color muted: Util.alpha(Commons.Color.menu.text, 0.6)
  readonly property color subtle: Util.alpha(Commons.Color.menu.text, 0.14)
  readonly property color accent: Commons.Color.accent
  readonly property string themeBackground: String(Commons.Color.background)
  readonly property bool lightTheme: Palette.isLight(themeBackground)
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int pad: Style.spacing.panelPadding
  readonly property int swatchSize: Style.space(18)

  readonly property var selectedTerm: current >= 0 && current < terminals.length ? terminals[current] : null
  readonly property bool selectedTakesWallpaper: selectedTerm !== null && selectedTerm.wallpaperReady
  readonly property var tabs: ["saved", "colours", "moods", "themes", "wallpapers"]
  readonly property var tabNames: ({ saved: "Looks", colours: "Colours", moods: "Moods", themes: "Themes", wallpapers: "Wallpaper" })
  readonly property var settingsSections: [
    { id: "windows", name: "Window effects" }, { id: "agents", name: "Claude + Codex" },
    { id: "new", name: "New terminals" }, { id: "projects", name: "Project folders" }, { id: "about", name: "About" }]

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
  // Built-in wallpapers: Ombre's folder, the current one, Aether's library, then each theme's.
  readonly property var builtinWallpapers: {
    var out = catalog.own.filter(Palette.isImagePath)
    root.allMoodSources.forEach(function (w) { if (Palette.isImagePath(w) && out.indexOf(w) < 0) out.push(w) })
    for (var i = 0; i < catalog.themes.length; i++) {
      var img = catalog.themes[i].image
      if (Palette.isImagePath(img) && out.indexOf(img) < 0) out.push(img)
    }
    return out
  }
  readonly property var addedImages: Palette.addedImages(imageSources, imageScan)
  // Wallpapers to pick from: the built-in ones, then the images added from anywhere.
  readonly property var wallpaperChoices: {
    var out = builtinWallpapers.slice(), seen = {}
    out.forEach(function (p) { seen[p] = true })
    addedImages.forEach(function (p) { if (!seen[p]) { seen[p] = true; out.push(p) } })
    if (!showHidden) out = out.filter(function (p) { return hiddenSources.indexOf(p) < 0 })
    return out
  }
  // The wallpaper grid in foldable sections, and the images it shows right now.
  readonly property var wallpaperSections: Palette.imageSections(builtinWallpapers, imageSources, imageScan,
    collapsedFolders, hiddenSources, showHidden, home)
  readonly property var shownWallpapers: Palette.visibleImages(wallpaperSections)
  // Quick jumps for the folder browser.
  readonly property var browsePlaces: {
    var named = { "/mnt": "Drives", "/media": "Media" }
    named[home + "/.config/omarchy/backgrounds"] = "Omarchy backgrounds"
    named["/run/media/" + Palette.folderName(home)] = "Removable drives"
    var out = [{ name: "Home", path: home }]
    catalog.places.forEach(function (p) { out.push({ name: named[p] || Palette.tildePath(p, home).replace(/^~\//, ""), path: p }) })
    out.push({ name: "Computer", path: "/" })
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
    if (!catalogLoaded || (selectedTerm && selectedTerm.wallpaperReady)) return ""
    if (selectedTerm && selectedTerm.backend === "omaguake") return "Install the renderer bridge: ombre setup-omaguake. Then restart the shell."
    if (!catalog.ghostty) return "Wallpapers need Ghostty. Install it and make it your terminal with: omarchy install terminal ghostty"
    if (!catalog.launcher) return "Wallpapers need Ghostty windows opened through Ombre's launcher."
    if (!selectedTerm) return ""
    if (selectedTerm.backend === "tmux") return "Attach this session in a Ghostty window opened through Ombre’s launcher. Wallpapers cover the entire host window."
    if (!selectedTerm.ghostty) return "This window is " + (selectedTerm.cls || "not Ghostty") + ". Wallpapers work in Ghostty windows; open one with Super+Return."
    if (!selectedTerm.wallpaperReady) return "This Ghostty window opened before wallpapers were set up. New Ghostty windows can take one."
    return ""
  }

  // ---- Shell lifecycle --------------------------------------------------
  function open(payloadJson) {
    var request = {}
    try { request = JSON.parse(payloadJson || "{}") } catch (error) { }
    if (request.sessions === true) root.searchText = String(request.query || "")
    root.openingWorkspace = Hyprland.focusedWorkspace ? String(Hyprland.focusedWorkspace.name || Hyprland.focusedWorkspace.id) : ""
    root.markedKeys = []
    root.view = request.studio ? "studio" : "style"
    root.opened = true
    root.focusOnScan = true
    root.hoverText = ""
    root.setupMessage = ""
    root.wallpaperMessage = ""
    root.checkAgentThemes("status")
    root.scan()
    root.scanImages()
    root.refreshCatalog()
    Qt.callLater(function () { if (request.sessions === true) terminalSearch.forceActiveFocus(); else keyCatcher.forceActiveFocus() })
  }

  // The catalog is cheap but forks a process per theme, so refresh it at most
  // once a minute; a theme change refreshes it right away. A fresh catalog still
  // needs this wallpaper's moods and this colour's palettes made.
  function refreshCatalog() {
    if (!root.catalogLoaded || Date.now() - root.catalogAt > 60000) root.loadCatalog()
    else if (root.catalog.aether) { root.ensureMoods(root.activeMoodSource); root.ensureColours(root.baseColour) }
  }

  function close() {
    root.comparePrevious(false)
    root.endPreview()
    root.browsing = false
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
  //      | wallpaper:/path/wall.jpg | wallpaper:none | text:#rrggbb
  //   T: focused | title:TEXT | pid:N | address:HEX | all
  function apply(arg) {
    var req
    try { req = JSON.parse(arg) } catch (e) { req = { value: String(arg || "").trim() } }
    if (!req || typeof req !== "object") return "error: bad request"
    var value = String(req.value || "")
    if (req.blur !== undefined && (!isFinite(Number(req.blur)) || Number(req.blur) < 0 || Number(req.blur) > 40)) return "error: blur must be 0–40"
    if (!root.validSpec(value)) return "error: unknown look " + value
    root.requests = root.requests.concat([{ value: value, target: String(req.target || "focused"),
                                            strength: Number(req.strength) || root.strength, blur: req.blur === undefined ? root.blur : Palette.normalizeBlur(req.blur) }])
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
      version: root.pluginVersion,
      sessionMessage:root.sessionMessage,studioMessage:root.studioMessage,
      studio:{focus:root.focusMode,private:root.privacyKeys.length,scenes:root.scenes.length,matrix:root.selectedMatrix},
      selectedCount: root.actionTargets.length,
      filteredCount: root.filteredTerminals.length,
      terminals: root.terminals.map(function (t) {
        return { pty: t.pty, pid: t.pid, address: "0x" + t.address, workspace: t.workspace,
                 title: t.title, label: t.label || "", sessionId: t.sessionId || "", backend: t.backend || "window", command: t.command || "", cwd: t.cwd || "", kind: t.look ? t.look.kind : "", look: Palette.lookLabel(t.look),
                 wallpaper: t.wallpaper ? t.wallpaper.path : "", wallpaperReady: t.wallpaperReady }
      })
    })
  }

  // Moods, themes and wallpapers available to `apply`, and what's installed.
  // Also refreshes the catalog for the next call.
  function looks(arg) {
    root.loadCatalog()
    return JSON.stringify({
      saved: root.savedLooks.map(function (v) { return {name: v.name, favorite: v.favorite} }),
      moods: root.catalog.modes.map(function (m) { return m.id }),
      themes: root.catalog.themes.map(function (t) { return t.id }),
      wallpapers: root.wallpaperChoices,
      glass: root.selectedGlass,
      imageSources: root.imageSources.map(function (p) {
        var s = root.imageScan[p]
        return { path: p, kind: s ? s.kind : "reading", count: s ? s.images.length : 0 }
      }),
      projects: root.projects.map(function (r) { return { path: r.path, look: root.ruleLabel(r) } }),
      wallpaper: root.catalog.wallpaper,
      aether: root.catalog.aether,
      aetherInstalled: root.catalog.aetherInstalled,
      aetherVersion: root.catalog.aetherVersion,
      ghostty: root.catalog.ghostty,
      launcher: root.catalog.launcher
    })
  }

  // Native themes use terminal palette references, so every window can keep
  // its own mood. Linking is one-time; palette changes need no app-file writes.
  function setAgentThemes(enabled) {
    return root.checkAgentThemes(enabled === true || enabled === "true" ? "link" : "unlink")
  }

  function checkAgentThemes(action) {
    if (agentThemeProc.running) return "busy"
    root.agentThemeAction = action
    root.agentThemeMessage = action === "link" ? "Linking app themes…" : action === "unlink" ? "Restoring previous app themes…" : ""
    agentThemeProc.command = ["python3", root.pluginDir + "/bin/ombre-sync-agent-themes", action]
    agentThemeProc.running = true
    return "ok"
  }

  function onAgentThemes(output) {
    try {
      var status = JSON.parse(output)
      root.agentThemeStatus = status
      root.agentThemeMessage = status.errors && status.errors.length ? status.errors.join(" · ")
        : root.agentThemeAction === "unlink" ? "Previous app themes restored. Open /theme in running sessions to select them."
        : status.linked ? "Each terminal follows its own palette. In existing app sessions, select Ombre in /theme once."
        : "Link once to make Claude’s interface and Codex’s code colors follow each terminal."
    } catch (e) { root.agentThemeMessage = "Could not read app theme settings." }
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

  // Glass is a Ghostty shader too: Claude's message band, Codex blocks and any
  // other cell background become frosted, darkened glass over the wallpaper.
  function setGlass(enabled) { return changeGlass({on: enabled === true || enabled === "true"}) }
  function setGlassColor(value) {
    var c = Palette.glassColor(value)
    if (!c) return "error: glass colour is auto, a colour name or #rrggbb"
    return changeGlass({color: c})
  }
  function setGlassTint(value) { return changeGlass({tint: Palette.glassLevel(value, 100, selectedGlass.tint)}) }
  function setGlassBlur(value) { return changeGlass({blur: Palette.glassLevel(value, 60, selectedGlass.blur)}) }
  function resetGlass() { return changeGlass({color: "auto", tint: Palette.GLASS_TINT, blur: Palette.GLASS_BLUR}) }

  // The shader token for a window's Ghostty config: dark, light or - for the
  // text shadow; with Glass on, glass:RRGGBB:TINT:BLUR plus -dark or -light.
  function shadowVariant(term) {
    var bg = (term && Palette.lookBackground(term.look, root.themeBackground)) || root.themeBackground
    var shadow = root.textShadow ? (Palette.isLight(bg) ? "light" : "dark") : "-"
    var settings = root.glassFor(term)
    return settings.on ? Palette.glassToken(settings.color, settings.tint, settings.blur, bg, shadow) : shadow
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

  // Every window drawn by Ghostty counts, whatever its class (Omarchy's agent windows are
  // Ghostty too) and even when Ombre can't style it, so windows are listed from Hyprland
  // and kept when their process is ghostty.
  function applySolid() {
    if (!root.solid || !root.solidLoaded || !root.configLoaded) return
    if (solidReader.running) { solidLater.restart(); return }
    solidReader.command = ["sh", "-c",
      'hyprctl clients | awk \'/^Window /{a=$2} /^\\tpid: /{print a, $2}\' | while read -r a pid; do\n'
      + '  [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = ghostty ] || continue\n'
      + '  case " $* " in *" $a "*) continue ;; esac\n'
      + '  printf "%s %s %s\\n" "$a" "$(hyprctl getprop "address:0x$a" opacity 2>/dev/null | head -n1)" "$(hyprctl getprop "address:0x$a" opacity_inactive 2>/dev/null | head -n1)"\n'
      + 'done', "sh"].concat(Object.keys(root.solidOriginal))
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
    return v === "undo" || v === "redo" || ((v.indexOf("saved:") === 0 || v.indexOf("save:") === 0) && Workspace.name(v.slice(v.indexOf(":") + 1)) !== "")
      || v === "next" || v === "reset" || Palette.tintLook(v) !== null || /^text:#[0-9a-fA-F]{6}$/.test(v)
      || /^mood:[a-z0-9-]+(@\/.+)?$/.test(v) || /^theme:[A-Za-z0-9._-]+$/.test(v)
      || /^colou?r:#[0-9a-fA-F]{6}(:[a-z]+)?$/.test(v)
      || v === "wallpaper:none" || (v.indexOf("wallpaper:") === 0 && Palette.isImagePath(v.slice(10)))
      || (/^blur:[0-9]+$/.test(v) && Number(v.slice(5)) <= 40)
      || v === "pulse:now" || v === "pulse:stop"
      || v === "default:from" || v === "project:from"
      || v.indexOf("project:remove:/") === 0
      || (v.indexOf("default:") === 0 && v !== "default:next" && v !== "default:reset" && root.validSpec(v.slice(8)))
  }

  // A look for a spec, { wait: true } while its data loads, or { error }.
  function resolveSpec(spec) {
    if (spec === "reset") return { look: null }
    if (spec.indexOf("saved:") === 0) {
      if (!root.configLoaded) return { wait: true }
      var saved = Workspace.find(root.savedLooks, spec.slice(6))
      return saved >= 0 ? Workspace.snapshot(root.savedLooks[saved]) : { error: "no saved look " + spec.slice(6) }
    }
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

    var cm = spec.match(/^colou?r:(#[0-9a-fA-F]{6})(?::([a-z]+))?$/)
    if (cm) {
      if (!root.catalog.aether) return { error: "Aether is not installed" }
      var base = cm[1].toLowerCase(), made = root.colourCache[base]
      if (!made) { root.ensureColours(base); return { wait: true } }
      var want = "colour-" + base.slice(1) + (cm[2] && cm[2] !== "classic" ? "-" + cm[2] : "")
      for (var ci = 0; ci < made.length; ci++) if (made[ci].id === want) return { look: made[ci] }
      return { error: "no " + (cm[2] || "classic") + " palette from " + base }
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
      if (req.value === "undo" || req.value === "redo") {
        for (var hi = 0; hi < hits.length; hi++) root.travelHistory(root.indexOf(hits[hi].pty), req.value)
        continue
      }
      if (req.value.indexOf("save:") === 0) {
        if (!root.configLoaded) { waiting.push(req); continue }
        if (hits.length) root.saveNamedLook(req.value.slice(5), hits[0])
        continue
      }
      if (req.value.indexOf("saved:") === 0) {
        if (!root.configLoaded) { waiting.push(req); continue }
        var savedIndex = Workspace.find(root.savedLooks, req.value.slice(6))
        if (savedIndex < 0) { console.warn("ombre: no saved look", req.value.slice(6)); continue }
        for (var si = 0; si < hits.length; si++) root.applySaved(root.indexOf(hits[si].pty), root.savedLooks[savedIndex], "all")
        continue
      }
      if (req.value.indexOf("blur:") === 0) {
        for (var bi = 0; bi < hits.length; bi++) {
          var blurIndex = root.indexOf(hits[bi].pty), bw = root.terminals[blurIndex].wallpaper
          if (bw) root.setWallpaper(blurIndex, {path: bw.path, strength: bw.strength, blur: Number(req.value.slice(5))})
        }
        continue
      }
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
        root.setDefaultLook(d.look, d.wallpaper || null)
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
        var wp = path === "none" ? null : { path: path, strength: req.strength, blur: req.blur }
        for (var w = 0; w < hits.length; w++) {
          if (hits[w].wallpaperReady) root.setWallpaper(root.indexOf(hits[w].pty), wp)
          else console.warn("ombre: " + hits[w].title + " can't take a wallpaper")
        }
        continue
      }
      if (req.value.indexOf("text:") === 0) {
        for (var ti = 0; ti < hits.length; ti++) {
          var textIndex = root.indexOf(hits[ti].pty)
          root.commit(textIndex, Palette.foregroundLook(root.terminals[textIndex].look, req.value.slice(5)))
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

  // ---- Saved looks, per-terminal history and picker targeting ------------
  function ensureVisibleCurrent() {
    var visible = Workspace.filtered(root.terminals, root.searchText, root.workspaceOnly ? root.openingWorkspace : "")
    if (!visible.length) { root.current = -1; return }
    for (var i = 0; i < visible.length; i++) if (visible[i].sourceIndex === root.current) return
    root.current = visible[0].sourceIndex
  }
  function resetFilterSelection() {
    root.endPreview()
    root.markedKeys = []
    root.ensureVisibleCurrent()
  }
  function moveCurrent(delta, wrap) {
    var visible = root.filteredTerminals
    if (!visible.length) return
    var at = 0
    for (var i = 0; i < visible.length; i++) if (visible[i].sourceIndex === root.current) at = i
    at = wrap ? (at + delta + visible.length) % visible.length : Math.max(0, Math.min(visible.length - 1, at + delta))
    root.current = visible[at].sourceIndex
  }
  function selectCard(index, multiple) {
    root.endPreview()
    root.current = index
    if (multiple) root.toggleMarked(index)
    else root.markedKeys = []
  }
  function toggleMarked(index) {
    if (index < 0 || index >= root.terminals.length) return
    root.endPreview()
    root.current = index
    var key = Workspace.key(root.terminals[index]), next = root.markedKeys.slice(), at = next.indexOf(key)
    if (at >= 0) next.splice(at, 1)
    else next.push(key)
    root.markedKeys = next
  }
  function selectVisible(onlyWorkspace) {
    root.endPreview()
    root.markedKeys = root.filteredTerminals.filter(function (t) {
      return !onlyWorkspace || t.workspace === root.openingWorkspace
    }).map(Workspace.key)
  }
  function recordChange(index, before) {
    if (!root.historyMuted && root.terminals[index]) root.histories = Workspace.record(root.histories, root.terminals[index], before)
  }
  function restoreSnapshot(index, state) {
    if (index < 0 || index >= root.terminals.length) return
    var muted = root.historyMuted
    root.historyMuted = true
    root.commit(index, state.look, true)
    if (root.terminals[index].wallpaperReady) root.setWallpaper(index, state.wallpaper)
    var t=root.terminals[index], hosts=t.backend==="tmux"?(t.wallpaperHosts||[]):[t]
    var g=Object.assign({},root.glassOverrides),m=Object.assign({},root.matrixOverrides)
    for(var h=0;h<hosts.length;h++){
      if(state.glass)g[Workspace.key(hosts[h])]=state.glass
      if(state.matrix)m[Workspace.key(hosts[h])]=state.matrix
    }
    root.glassOverrides=g;root.matrixOverrides=m;root.refreshEffects(null)
    if(t.wallpaperReady)root.sendWallpaper(root.terminals[index],root.terminals[index].wallpaper)
    root.saveConfig();root.syncProfile(root.terminals[index])
    root.historyMuted = muted
  }
  function travelHistory(index, direction) {
    if (index < 0 || index >= root.terminals.length) return
    root.endPreview()
    var result = Workspace.travel(root.histories, root.terminals[index], direction)
    if (!result) return
    root.histories = result.histories
    root.restoreSnapshot(index, result.state)
  }
  function applyLookTargets(look) {
    root.captureBatch()
    root.endPreview()
    var targets = root.actionTargets.slice()
    for (var i = 0; i < targets.length; i++) root.commitWithWallpaper(targets[i], look)
  }
  function applyTintTargets(value) {
    root.captureBatch()
    root.endPreview()
    var targets = root.actionTargets.slice()
    for (var i = 0; i < targets.length; i++) root.commit(targets[i], Palette.layerLook(root.terminals[targets[i]].look, Palette.tintLook(value), "background"))
  }
  function applyCardTint(index, value) {
    if (root.markedKeys.indexOf(Workspace.key(root.terminals[index])) < 0) root.markedKeys = []
    root.current = index
    root.applyTintTargets(value)
  }
  function resetTargets() {
    root.captureBatch()
    root.endPreview()
    var targets = root.actionTargets.slice()
    for (var i = 0; i < targets.length; i++) root.commit(targets[i], null)
  }
  function applyWallpaperTargets(wallpaper) {
    root.captureBatch()
    root.endPreview()
    var targets = root.actionTargets.slice(), skipped = 0
    for (var i = 0; i < targets.length; i++) {
      if (root.terminals[targets[i]].wallpaperReady) root.setWallpaper(targets[i], wallpaper)
      else skipped++
    }
    if (skipped) root.hoverText = "Wallpaper applied to " + (targets.length - skipped) + " terminals; " + skipped + " cannot display wallpapers."
  }
  function saveNamedLook(value, term, replace) {
    var name = Workspace.name(value)
    if (!name) { root.libraryMessage = "Use a name of 1–64 characters."; return false }
    term = term || root.selectedTerm
    if (!term) { root.libraryMessage = "Select a terminal to save."; return false }
    var at = Workspace.find(root.savedLooks, name)
    if (at >= 0 && !replace) { root.libraryMessage = "That name is already saved. Use Update on its card to replace it."; return false }
    if (at < 0 && root.savedLooks.length >= 200) { root.libraryMessage = "The library holds up to 200 looks. Remove one before saving another."; return false }
    var state = Workspace.snapshot(root.styleState(term)), next = root.savedLooks.slice()
    var item = Object.assign({},state,{name: at >= 0 ? next[at].name : name,favorite: at >= 0 && next[at].favorite})
    if (at >= 0) next[at] = item
    else next.push(item)
    root.savedLooks = next
    root.libraryMessage = "Saved " + item.name + "."
    root.saveConfig()
    return true
  }
  function renameSaved(arg) {
    try {
      var request = JSON.parse(arg)
      return root.renameNamedLook(request.from, request.to) ? "ok" : "error: " + root.libraryMessage
    } catch (e) { return "error: invalid rename request" }
  }
  function favoriteNamedLook(value) {
    var at = Workspace.find(root.savedLooks, value)
    if (at < 0) return "error: no saved look " + value
    var next = root.savedLooks.slice()
    next[at] = Object.assign({}, next[at], {favorite: !next[at].favorite})
    root.savedLooks = next
    root.saveConfig()
    return "ok"
  }
  function removeNamedLook(value) {
    var at = Workspace.find(root.savedLooks, value)
    if (at < 0) return "error: no saved look " + value
    var next = root.savedLooks.slice()
    next.splice(at, 1)
    root.savedLooks = next
    root.pendingDeleteName = ""
    root.libraryMessage = "Removed " + value + "."
    root.saveConfig()
    return "ok"
  }
  function renameNamedLook(oldName, newName) {
    var at = Workspace.find(root.savedLooks, oldName), name = Workspace.name(newName), conflict = Workspace.find(root.savedLooks, name)
    if (at < 0 || !name || (conflict >= 0 && conflict !== at)) {
      root.libraryMessage = "Choose an unused name of 1–64 characters."
      return false
    }
    var next = root.savedLooks.slice()
    next[at] = Object.assign({}, next[at], {name: name})
    root.savedLooks = next
    root.editingSavedName = ""
    root.libraryMessage = "Renamed to " + name + "."
    root.saveConfig()
    return true
  }
  function savedChipLook(saved) {
    var textLook = Palette.textLook(saved.look)
    return {palette: {background: Palette.lookBackground(saved.look, root.themeBackground) || root.themeBackground,
      foreground: Palette.lookForeground(saved.look) || String(root.text), colors: textLook ? textLook.palette.colors : []}}
  }
  function submitSavedName(value) {
    var ok = root.editingSavedName ? root.renameNamedLook(root.editingSavedName, value) : root.saveNamedLook(value)
    if (ok) { savedName.text = ""; keyCatcher.forceActiveFocus() }
  }
  function applySaved(index, saved, scope) {
    if (index < 0 || index >= root.terminals.length) return
    var before = Workspace.snapshot(root.terminals[index]), muted = root.historyMuted
    root.historyMuted = true
    root.commit(index, scope === "all" ? saved.look : Palette.layerLook(root.terminals[index].look, saved.look, scope), true)
    if (scope !== "text" && root.terminals[index].wallpaperReady) root.restoreSnapshot(index,Object.assign({},saved,{look:root.terminals[index].look}))
    root.historyMuted = muted
    root.recordChange(index, before)
  }
  function applySavedTargets(saved) {
    root.captureBatch()
    root.endPreview()
    var targets = root.actionTargets.slice(), skipped = 0
    for (var i = 0; i < targets.length; i++) {
      if (root.applyScope !== "text" && saved.wallpaper && !root.terminals[targets[i]].wallpaperReady) skipped++
      root.applySaved(targets[i], saved, root.applyScope)
    }
    root.libraryMessage = "Applied " + saved.name + " to " + targets.length + (targets.length === 1 ? " terminal." : " terminals.")
      + (skipped ? " " + skipped + " cannot display wallpapers; their colors were applied." : "")
    root.hoverText = root.libraryMessage
  }

  // ---- Scanning ---------------------------------------------------------
  function sessionAction(request) {
    sessionMessage = ""
    if (sessionWorker.running) sessionWorker.write(JSON.stringify(request) + "\n")
    else sessionMessage = "Session adapter unavailable"
  }

  function labelSession(value) {
    var t = root.selectedTerm
    if (!t) return
    var label = value.trim()
    if (label && !Workspace.name(label)) { root.sessionMessage = "Use a label of at most 64 characters."; return }
    if (t.sessionId) root.sessionAction({op: "label", sessionId: t.sessionId, label: label})
    else {
      var labels = Object.assign({}, root.sessionLabels)
      if (label) labels[Workspace.key(t)] = label
      else delete labels[Workspace.key(t)]
      root.sessionLabels = labels
      root.saveConfig()
    }
    root.update(root.current, {label: label})
  }

  function jumpSession() {
    var t = root.selectedTerm
    if (!t) return
    root.endPreview()
    if (t.sessionId) root.sessionAction({op: "focus", sessionId: t.sessionId, hostAddress:t.hostAddress})
    else {
      root.dismiss()
      Hyprland.dispatch("focuswindow address:0x" + t.address)
    }
  }

  function sessionStyle(term, look, persist) {
    var text = Palette.textLook(look)
    root.sessionAction({op: "style", sessionId: term.sessionId, look: look,
      persist: persist === true, background: Palette.lookBackground(look, root.themeBackground) || "",
      foreground: Palette.lookForeground(look), cursor: text ? text.palette.cursor : "",
      colors: text ? text.palette.colors : []})
  }

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
    var f = output.indexOf("\n@@SESSIONS@@\n")
    if (a < 0 || b < 0 || c < 0 || d < 0 || e < 0) return null
    var list = Palette.terminals(output.slice(0, a), output.slice(a + 8, b), output.slice(b + 11, c),
                                 output.slice(c + 13, d), root.runtimeDir, output.slice(d + 14, e), output.slice(e + 9, f < 0 ? undefined : f))
    if (f >= 0) {
      try {
        var extra = JSON.parse(output.slice(f + 14))
        var panes = extra.sessions || []
        for (var hi = 0; hi < list.length; hi++) list[hi].started = extra.starts[list[hi].pid] || ""
        var clientPtys = []
        for (var p = 0; p < panes.length; p++) clientPtys = clientPtys.concat(panes[p].clientPtys || [])
        for (var h = 0; h < panes.length; h++) {
          var pane = panes[h]
          if (pane.backend !== "tmux") continue
          var hosts = list.filter(function (host) { return (pane.clientPtys || []).indexOf(host.pty) >= 0 })
          var visual = hosts.filter(function(host) { return host.focused })[0]
            || hosts.filter(function(host) { return host.visible })[0] || hosts[0]
          pane.visible = !!visual && visual.visible
          if (visual) {
            for (var field of ["monitor", "lx", "ly", "x", "y", "w", "h", "workspace"]) pane[field] = visual[field]
            pane.hostAddress = visual.address
          }
          pane.wallpaperHosts = hosts.filter(function(host) { return host.wallpaperReady })
          pane.wallpaperReady = pane.wallpaperHosts.length > 0
          if (pane.wallpaperReady) pane.wallpaper = pane.wallpaperHosts[0].wallpaper
        }
        list = list.filter(function (t) { return clientPtys.indexOf(t.pty) < 0 })
        for (var n = 0; n < list.length; n++) {
          list[n].started = extra.starts[list[n].pid] || ""
          list[n].label = root.sessionLabels[Workspace.key(list[n])] || ""
        }
        list = list.concat(panes.map(function(t) { t.look = Palette.normalizeLook(t.look); return t }))
      } catch (error) { root.sessionMessage = "Could not read terminal sessions" }
    }
    for (var i = 0; i < list.length; i++) {
      var k = root.known[list[i].pty]
      if (k && k.pid === list[i].pid && k.identity === Workspace.key(list[i])) {
        list[i].look = k.look
        list[i].wallpaper = k.wallpaper
      }
    }
    for(var fx=0;fx<list.length;fx++){
      list[fx].glass=root.glassFor(list[fx]);list[fx].matrix=root.matrixFor(list[fx])
    }
    return list
  }

  function followProfiles(list) {
    if(root.followSessions) {
      var followed=Object.assign({},root.followSeen)
      var wasMuted=root.batchMuted;root.batchMuted=true
      for(var fi=0;fi<list.length;fi++){
        var ft=list[fi]
        if(ft.backend!=="tmux" || !ft.profile || !ft.displayed || !ft.wallpaperReady)continue
        var fingerprint=JSON.stringify([ft.wallpaperHosts.map(function(h){return Workspace.key(h)}),ft.profile])
        var hostKeys=ft.wallpaperHosts.map(function(h){return Workspace.key(h)})
        if(hostKeys.every(function(k){return followed[k]===ft.sessionId+fingerprint}))continue
        for(var hk=0;hk<hostKeys.length;hk++)followed[hostKeys[hk]]=ft.sessionId+fingerprint
        root.applyState(fi,ft.profile)
      }
      root.followSeen=followed;root.batchMuted=wasMuted
    }
  }

  function onScan(output) {
    var list = root.parseScan(output)
    if (!list) return
    var previous = Workspace.key(root.selectedTerm)
    root.terminals = list
    root.followProfiles(list)
    root.histories = Workspace.prune(root.histories, list)
    root.markedKeys = root.markedKeys.filter(function (k) { return list.some(function (t) { return Workspace.key(t) === k }) })
    for (var pi = 0; pi < list.length; pi++) if (Workspace.key(list[pi]) === previous) root.current = pi
    if (root.focusOnScan) {
      root.focusOnScan = false
      root.current = Palette.focusedIndex(list)
    }
    root.current = Math.max(0, Math.min(root.current, list.length - 1))
    var waiting = root.pendingPulses
    root.pendingPulses = []
    for (var w = 0; w < waiting.length; w++) {
      for (var t = 0; t < list.length; t++) if (list[t].address === waiting[w] || list[t].hostAddress === waiting[w]) root.startPulse(Object.assign({},list[t],{address:waiting[w]}))
    }
    var muted = root.historyMuted
    root.historyMuted = true
    root.applyProjects(list)
    root.applyDefaults(list)
    root.historyMuted = muted
    root.ensureVisibleCurrent()
    root.applySolid()
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
    look = Palette.backgroundLook(look)
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
    if (!root.tabChosen && !c.aether && root.tab === "moods") root.tab = "colours"
    if (root.opened && c.aether) { root.ensureMoods(root.activeMoodSource); root.ensureColours(root.baseColour) }
    if (root.requests.length > 0) root.scan()
    root.maybeWelcome()
  }

  function moodKey(source) {
    return source + (root.moodLight ? "|light" : "|dark")
  }

  function setMoodTone(tone) {
    if (tone !== "auto" && tone !== "dark" && tone !== "light") return "error: tone is auto, dark or light"
    root.endPreview()
    root.moodTone = tone
    root.saveConfig()
    if (root.catalog.aether) root.ensureMoods(root.activeMoodSource)
    return "ok"
  }

  // Aether palettes from one colour: classic, vivid, soft, warm, cool, contrast.
  function setBaseColour(value) {
    if (!Palette.isHex(value)) return "error: colour is #rrggbb"
    root.endPreview()
    root.baseColour = String(value).toLowerCase()
    root.saveConfig()
    root.ensureColours(root.baseColour)
    return "ok"
  }

  function ensureColours(base) {
    base = String(base || "").toLowerCase()
    if (!Palette.isHex(base) || !root.catalog.aether || root.colourCache[base]) return
    if (root.colourRunning === base || root.colourQueue.indexOf(base) >= 0) return
    root.colourQueue = root.colourQueue.concat([base])
    root.nextColours()
  }

  function nextColours() {
    if (colourProc.running || root.colourQueue.length === 0) return
    var base = root.colourQueue[0]
    root.colourQueue = root.colourQueue.slice(1)
    root.colourRunning = base
    root.colourMessage = ""
    colourProc.command = ["python3", "-I", root.pluginDir + "/bin/ombre-colour", base]
    colourProc.running = true
  }

  function onColours(output) {
    var base = root.colourRunning, made = Palette.colourLooks(output)
    if (made.length) {
      var cache = Object.assign({}, root.colourCache)
      cache[base] = made
      root.colourCache = cache
    } else root.colourMessage = "Aether could not make a palette from " + base + "."
    root.colourRunning = ""
    root.nextColours()
    if (root.requests.length > 0) root.scan()
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
    moodProc.command = ["sh", "-c", root.moodScript, "sh", source, root.moodLight ? "--light-mode" : ""].concat(modes)
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

  // ---- Images from anywhere --------------------------------------------
  // Add a PNG/JPEG file, or a folder of them, from anywhere. Files are only
  // read: nothing is copied, moved or changed. Callable from the shell too.
  function addImageSource(path) {
    var p = Palette.cleanSourcePath(String(path || "").trim().replace(/^~(?=\/|$)/, root.home))
    if (!p) { root.wallpaperMessage = "Give a full path to an image or a folder, such as ~/Pictures."; return "error: needs a full path" }
    if (root.imageSources.indexOf(p) >= 0) { root.wallpaperMessage = Palette.folderName(p) + " is already added."; return "ok" }
    if (root.imageSources.length >= Palette.MAX_IMAGE_SOURCES) {
      root.wallpaperMessage = "Ombre holds up to " + Palette.MAX_IMAGE_SOURCES + " added files and folders. Remove one first."
      return "error: too many added files and folders"
    }
    root.imageSources = root.imageSources.concat([p])
    root.imagesAdding = root.imagesAdding.concat([p])
    root.wallpaperMessage = "Reading " + Palette.folderName(p) + "…"
    root.saveConfig()
    root.scanImages()
    return "ok"
  }

  // Take an added file or folder back out. The files stay where they are.
  function removeImageSource(path) {
    var p = Palette.cleanSourcePath(path)
    if (root.imageSources.indexOf(p) < 0) return "error: not added: " + path
    var keep = root.imageSources.filter(function (s) { return s !== p })
    root.imageSources = keep
    root.collapsedFolders = root.collapsedFolders.filter(function (k) {
      if (k !== p && k.indexOf(p + "/") !== 0) return true
      return keep.some(function (s) { return k === s || k.indexOf(s + "/") === 0 })
    })
    var scan = Object.assign({}, root.imageScan)
    delete scan[p]
    root.imageScan = scan
    root.saveConfig()
    root.wallpaperMessage = "Removed " + Palette.folderName(p) + " from Ombre. The files are untouched."
    return "ok"
  }

  function toggleSection(key) {
    root.collapsedFolders = root.collapsedFolders.indexOf(key) >= 0
      ? root.collapsedFolders.filter(function (k) { return k !== key })
      : root.collapsedFolders.concat([key])
    root.saveConfig()
  }

  function scanImages() {
    if (imagesProc.running) { root.imageScanAgain = true; return }
    if (root.imageSources.length === 0) { root.imageScan = ({}); return }
    imagesProc.command = ["python3", "-I", root.pluginDir + "/bin/ombre-images"].concat(root.imageSources)
    imagesProc.running = true
  }

  function onImageScan(text) {
    if (String(text || "").trim() === "") return
    root.imageScan = Palette.parseImageScan(text)
    var read = root.imagesAdding.filter(function (p) { return root.imageScan[p] })
    root.imagesAdding = root.imagesAdding.filter(function (p) { return !root.imageScan[p] })
    read.forEach(root.reportAdded)
  }

  // Say what an addition held. Anything that isn't a real PNG/JPEG comes back out.
  function reportAdded(p) {
    var s = root.imageScan[p], name = Palette.folderName(p)
    var apply = root.imageApplyPath === p
    if (apply) root.imageApplyPath = ""
    if (s.kind === "missing" || s.kind === "unsupported") {
      root.imageSources = root.imageSources.filter(function (x) { return x !== p })
      root.saveConfig()
      root.wallpaperMessage = s.kind === "missing" ? name + " was not found."
        : name + " is not a PNG or JPEG image, so it was not added. Ghostty can only show those two formats."
      return
    }
    if (s.kind === "file") {
      root.wallpaperMessage = "Added " + name + "."
      if (apply && root.targetTakesWallpaper) root.applyWallpaperTargets({ path: p, strength: root.strength, blur: root.currentBlur })
      return
    }
    // A folder of folders opens tidy: its own images show, the folders inside start folded.
    var inner = s.groups.filter(function (g) { return g.depth === 1 && root.collapsedFolders.indexOf(g.dir) < 0 })
      .map(function (g) { return g.dir })
    if (inner.length) root.collapsedFolders = root.collapsedFolders.concat(inner)
    root.saveConfig()
    var total = s.groups.length ? s.groups[0].total : 0
    root.wallpaperMessage = total === 0 ? "Added " + name + ", but it has no PNG or JPEG images."
      : "Added " + name + ": " + (s.truncated ? "the first " : "") + total + (total === 1 ? " image" : " images")
        + (inner.length ? ". Click a folder to open it." : ".")
  }

  function openBrowser() {
    if (!root.browseFolder) {
      var pictures = root.home + "/Pictures"
      root.browseFolder = root.catalog.places.indexOf(pictures) >= 0 ? pictures : (root.home || "/")
    }
    root.wallpaperMessage = ""
    root.tab = "wallpapers"
    root.tabChosen = true
    root.browsing = true
  }

  function closeBrowser() {
    root.browsing = false
    previewEnd.restart()
    keyCatcher.forceActiveFocus()
  }

  // Go to a folder, or take an image, typed or pasted as a path (~ works).
  function browseTo(path) {
    var p = Palette.cleanSourcePath(String(path || "").trim().replace(/^~(?=\/|$)/, root.home))
    if (!p) { root.wallpaperMessage = "Type a full path, such as ~/Pictures or /mnt/photos."; return }
    if (Palette.isImagePath(p)) { root.useBrowsedImage(p); return }
    root.wallpaperMessage = ""
    root.browseFolder = p
    root.saveConfig()
  }

  function browseUp() {
    var f = root.browseFolder
    if (!f || f === "/") return
    root.browseFolder = f.slice(0, f.lastIndexOf("/")) || "/"
    root.saveConfig()
  }

  function openBrowsed(index) {
    if (index < 0 || index >= folderModel.count) return
    var path = String(folderModel.get(index, "filePath") || "")
    if (folderModel.get(index, "fileIsDir")) root.browseTo(path)
    else if (path) root.useBrowsedImage(path)
  }

  // One image from the browser: add it, then put it on the selected terminals
  // once the scan confirms it is a real PNG or JPEG.
  function useBrowsedImage(path) {
    root.closeBrowser()
    if (root.addedImages.indexOf(path) >= 0 || root.builtinWallpapers.indexOf(path) >= 0) {
      if (root.targetTakesWallpaper) root.applyWallpaperTargets({ path: path, strength: root.strength, blur: root.currentBlur })
      return
    }
    root.imageApplyPath = root.targetTakesWallpaper ? path : ""
    root.addImageSource(path)
  }

  // Keys while the browser is open. Anything not handled here falls through.
  function browserKey(k) {
    if (k === Qt.Key_Escape) root.closeBrowser()
    else if (k === Qt.Key_Backspace || k === Qt.Key_Left) root.browseUp()
    else if (k === Qt.Key_Down || k === Qt.Key_J) browseList.incrementCurrentIndex()
    else if (k === Qt.Key_Up || k === Qt.Key_K) browseList.decrementCurrentIndex()
    else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Right) root.openBrowsed(browseList.currentIndex)
    else if (k === Qt.Key_A) { root.addImageSource(root.browseFolder); root.closeBrowser() }
    else if (k === Qt.Key_Slash) { browsePath.forceActiveFocus(); browsePath.selectAll() }
    else return false
    return true
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
    if (term.sessionId) root.sessionStyle(term, look, false)
    else root.send("write " + term.pty + " " + Palette.sequence(look, root.themeBackground))
    root.paintBorder(term, look)
  }

  function paintBorder(term, look) {
    if (!term.address) return
    var color = root.borders ? Palette.lookAccent(look) : ""
    Hyprland.dispatch(Palette.borderPair(term.address, color, "ff",
      Palette.inactiveAccent(color, root.themeBackground), "ff", root.themeBorders))
  }

  function persist(term) {
    if (term.sessionId) {
      root.sessionStyle(term, term.look, true)
      if (term.backend === "tmux") {
        var hosts = term.wallpaperHosts || []
        for (var h = 0; h < hosts.length; h++) {
          var host = Object.assign({}, hosts[h], {wallpaper: term.wallpaper})
          root.persist(host)
        }
      }
      if (term.wallpaperReady && term.backend === "omaguake") root.sessionAction({op: "wallpaper", sessionId: term.sessionId,
        wallpaper: term.wallpaper, persist: true,
        background: Palette.lookBackground(term.look, root.themeBackground) || root.themeBackground})
    }
    else if (term.look || term.wallpaper)
      root.send("save " + term.pty + " " + JSON.stringify({ pid: term.pid, look: term.look, wallpaper: term.wallpaper }))
    else root.send("forget " + term.pty)
    var known = Object.assign({}, root.known)
    known[term.pty] = { pid: term.pid, identity: Workspace.key(term), look: term.look, wallpaper: term.wallpaper }
    root.known = known
    root.syncProfile(term)
  }

  function update(index, patch) {
    var next = root.terminals.slice()
    next[index] = Object.assign({}, root.terminals[index], patch)
    root.terminals = next
    return next[index]
  }

  function commit(index, look, exact) {
    if (index < 0 || index >= root.terminals.length) return
    var before = Workspace.snapshot(root.terminals[index])
    // A background swatch must never discard the selected text palette.
    if (!exact && look && look.kind === "tint") look = Palette.layerLook(root.terminals[index].look, look, "background")
    look = Palette.normalizeLook(look)
    if (root.previewPty === root.terminals[index].pty) root.previewPty = ""
    var term = root.update(index, { look: look })
    root.show(term, look)
    root.persist(term)
    if (term.wallpaperReady) root.sendWallpaper(term, term.wallpaper)
    root.recordChange(index, before)
    if (root.pulses[term.address]) {
      var pulses = Object.assign({}, root.pulses)
      pulses[term.address] = Object.assign({}, pulses[term.address],
        { look: look, color: Palette.lookAccent(look) || root.accentHex })
      root.pulses = pulses
    }
  }

  function scopeLook(look) {
    return root.applyScope === "text" ? Palette.textLook(look)
      : root.applyScope === "background" ? Palette.backgroundLook(look) : look
  }

  function setLayerColor(layer, value) {
    if (!root.selectedTerm || (value && !Palette.isHex(value))) return
    root.endPreview()
    var targets = root.actionTargets.slice()
    for (var i = 0; i < targets.length; i++) {
      var index = targets[i], currentLook = root.terminals[index].look
      root.commit(index, layer === "text" ? Palette.foregroundLook(currentLook, value)
        : Palette.layerLook(currentLook, Palette.tintLook(value), "background"))
    }
  }

  function resetLayer(layer) {
    if (!root.selectedTerm) return
    root.endPreview()
    var targets = root.actionTargets.slice()
    for (var i = 0; i < targets.length; i++) root.commit(targets[i], Palette.layerLook(root.terminals[targets[i]].look, null, layer))
  }

  // A mood or theme, with its wallpaper too when the window can take one.
  function commitWithWallpaper(index, look) {
    if (index < 0 || index >= root.terminals.length) return
    var before = Workspace.snapshot(root.terminals[index]), muted = root.historyMuted
    root.historyMuted = true
    root.commit(index, Palette.layerLook(root.terminals[index].look, look, root.applyScope))
    var term = root.terminals[index]
    var image = look ? (look.kind === "mood" ? look.source : look.image) : ""
    if (root.applyScope !== "text" && root.withWallpaper && term && term.wallpaperReady && Palette.isImagePath(image))
      root.setWallpaper(index, { path: image, strength: root.strength, blur: root.currentBlur })
    root.historyMuted = muted
    root.recordChange(index, before)
  }

  // Ghostty reloads the window's config file on SIGUSR2. The writer checks the
  // pid really is Ghostty before signalling it.
  function sendWallpaper(term, wallpaper) {
    var w = Palette.normalizeWallpaper(wallpaper)
    if (term.backend === "tmux") {
      var hosts = term.wallpaperHosts || []
      for (var h = 0; h < hosts.length; h++) root.sendWallpaper(hosts[h], w)
      return
    }
    if (term.backend === "omaguake") {
      root.sessionAction({op: "wallpaper", sessionId: term.sessionId, wallpaper: w,
        background: Palette.lookBackground(term.look, root.themeBackground) || root.themeBackground})
      return
    }
    root.send("ghostty " + term.pid + " " + (term.confDir || root.runtimeDir + "/ghostty/") + " "
      + root.renderToken(term) + " " + Palette.ghosttyColors(term.look, root.themeBackground) + " " + (w ? w.strength + " " + w.blur + " " + w.path : "- 0 -"))
    // Re-send the look once the reload settles, in case it reset the colors.
    if (root.reshowPtys.indexOf(term.pty) < 0) root.reshowPtys = root.reshowPtys.concat([term.pty])
    reshowLater.restart()
  }

  function setWallpaper(index, wallpaper) {
    if (index < 0 || index >= root.terminals.length || !root.terminals[index].wallpaperReady) return
    var before = Workspace.snapshot(root.terminals[index])
    var w = Palette.normalizeWallpaper(wallpaper)
    if (root.previewWallpaperPty === root.terminals[index].pty) root.previewWallpaperPty = ""
    var term = root.update(index, { wallpaper: w })
    root.sendWallpaper(term, w)
    root.persist(term)
    root.recordChange(index, before)
  }

  function preview(index, look, scope) {
    if (index < 0 || index >= root.terminals.length) return
    previewEnd.stop()
    var term = root.terminals[index]
    if (root.previewPty && root.previewPty !== term.pty) root.endPreview()
    root.previewPty = term.pty
    root.previewLook = Palette.layerLook(term.look, look, scope || (look && look.kind === "tint" ? "background" : root.applyScope))
    root.show(term, root.previewLook)
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
      root.show(t, root.previewPty === t.pty ? root.previewLook : t.look)
    }
  }

  function setStrength(value) {
    root.captureBatch()
    root.strength = value
    root.saveConfig()
    var targets = root.actionTargets.slice()
    for (var i = 0; i < targets.length; i++) {
      var term = root.terminals[targets[i]]
      if (term.wallpaper) root.setWallpaper(targets[i], { path: term.wallpaper.path, strength: value, blur: term.wallpaper.blur })
    }
  }

  function setBlur(value) {
    root.captureBatch()
    root.wallpaperMessage = ""
    root.endPreview()
    root.blur = Palette.normalizeBlur(value)
    root.saveConfig()
    var targets = root.actionTargets.slice()
    for (var i = 0; i < targets.length; i++) {
      var term = root.terminals[targets[i]]
      if (term.wallpaper && term.wallpaperReady)
        root.setWallpaper(targets[i], { path: term.wallpaper.path, strength: term.wallpaper.strength, blur: root.blur })
    }
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
      if (applied[Workspace.key(t)] === key) continue
      applied[Workspace.key(t)] = key
      changed = true
      if (!rule) continue
      var index = root.indexOf(t.pty)
      if (rule.look) root.commit(index, rule.look)
      if (t.wallpaperReady) root.setWallpaper(index, rule.wallpaper || null)
      if (!root.seen[Workspace.key(t)]) root.markSeen([t])
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
    var wp = Palette.isImagePath(req.wallpaper) ? { path: req.wallpaper, strength: Number(req.strength) || root.strength, blur: req.blur === undefined ? root.blur : Palette.normalizeBlur(req.blur) } : null
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
    if (rule.look) parts.push(Palette.lookLabel(rule.look))
    if (rule.wallpaper) parts.push(Palette.basename(rule.wallpaper.path) + " wallpaper")
    return parts.join(" with ") || "their own colors"
  }

  // ---- Default look for new terminals -----------------------------------
  function markSeen(list) {
    var seen = Object.assign({}, root.seen)
    for (var i = 0; i < list.length; i++) seen[Workspace.key(list[i])] = true
    root.seen = seen
    root.seenReady = true
  }

  function applyDefaults(list) {
    if (!root.seenReady) return
    var fresh = list.filter(function (t) { return !root.seen[Workspace.key(t)] })
    if (fresh.length === 0) return
    root.markSeen(fresh)
    var aw = Object.assign({}, root.awaiting)
    for (var f = 0; f < fresh.length; f++) delete aw[fresh[f].address]
    root.awaiting = aw
    if (root.newDefault.mode === "none" && !root.textShadow && !root.glass) return
    for (var i = 0; i < fresh.length; i++) {
      var t = fresh[i]
      var index = root.indexOf(t.pty)
      if ((root.textShadow || root.glass) && t.wallpaperReady && !t.wallpaper) root.sendWallpaper(t, null)
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
      var l = Palette.backgroundLook(root.terminals[i].look)
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
    if (d.look) parts.push(Palette.lookLabel(d.look))
    if (d.wallpaper) parts.push(Palette.basename(d.wallpaper.path) + " wallpaper")
    return parts.join(" with ") || "their own colors"
  }

  // Space and Shift+Space walk the list on the open tab for the selected terminal.
  function stepLook(delta) {
    var term = root.selectedTerm
    if (!term) return
    if (root.tab === "saved") {
      if (!root.sortedLooks.length) return
      var savedIndex = -1
      for (var s = 0; s < root.sortedLooks.length; s++) if (Workspace.same(term, root.sortedLooks[s])) savedIndex = s
      var sn = savedIndex < 0 ? (delta > 0 ? 0 : root.sortedLooks.length - 1) : (savedIndex + delta + root.sortedLooks.length) % root.sortedLooks.length
      root.applySavedTargets(root.sortedLooks[sn])
      return
    }
    if (root.tab === "wallpapers") {
      if (!root.targetTakesWallpaper || root.shownWallpapers.length === 0) return
      var choices = root.shownWallpapers
      var w = term.wallpaper ? choices.indexOf(term.wallpaper.path) : -1
      var wn = w < 0 ? (delta > 0 ? 0 : choices.length - 1) : (w + delta + choices.length) % choices.length
      root.applyWallpaperTargets({ path: choices[wn], strength: root.strength, blur: root.currentBlur })
      root.hoverText = Palette.basename(choices[wn])
      return
    }
    var list = root.tab === "moods" ? root.moods : root.tab === "colours" ? root.colourLooks : root.catalog.themes
    if (list.length === 0) return
    var i = -1
    for (var k = 0; k < list.length; k++) if (Palette.sameLook(list[k], root.scopeLook(term.look))) i = k
    var next = i < 0 ? (delta > 0 ? 0 : list.length - 1) : (i + delta + list.length) % list.length
    root.applyLookTargets(list[next])
    root.hoverText = root.describe(list[next])
  }

  function describe(look) {
    if (!look) return ""
    if (look.kind === "mood") return Palette.pretty(look.id) + " — " + (look.description || "")
    return Palette.pretty(look.id)
  }

  function nextTab(delta) {
    var i = root.tabs.indexOf(root.tab)
    root.endPreview()
    root.hoverText = ""
    root.tab = root.tabs[(i + delta + root.tabs.length) % root.tabs.length]
    root.tabChosen = true
  }

  function showSettings(section) {
    root.endPreview()
    root.hoverText = ""
    root.browsing = false
    if (section) root.settingsSection = section
    root.view = "settings"
  }

  function nextSection(delta) {
    var ids = root.settingsSections.map(function (s) { return s.id })
    var i = ids.indexOf(root.settingsSection)
    root.settingsSection = ids[(i + delta + ids.length) % ids.length]
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
      if (list[i].look) {
        root.show(list[i], list[i].look)
        if (list[i].wallpaperReady) root.sendWallpaper(list[i], list[i].wallpaper)
      }
      else if (root.repaintAll) root.paintBorder(list[i], null)
    }
    root.repaintAll = false
    root.applySolid()
    root.markSeen(list)
    if (root.opened) {
      var previous = Workspace.key(root.selectedTerm)
      root.terminals = list
      root.histories = Workspace.prune(root.histories, list)
      root.markedKeys = root.markedKeys.filter(function (k) { return list.some(function (t) { return Workspace.key(t) === k }) })
      for (var j = 0; j < list.length; j++) if (Workspace.key(list[j]) === previous) root.current = j
      root.ensureVisibleCurrent()
    }
  }

  function toplevelFor(address) {
    var list = Hyprland.toplevels.values
    for (var i = 0; i < list.length; i++) if (list[i].address === address) return list[i].wayland
    return null
  }

  // ---- Needs-you pulse ---------------------------------------------------
  readonly property string accentHex: "#" + String(Commons.Color.accent).replace(/^#/, "").slice(-6)

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
      Hyprland.dispatch(Palette.borderPair(addr, c, "ff", c, "ff", root.themeBorders))
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
  property bool configDirty: false
  function saveConfig() { root.configDirty = true; configSaveLater.restart() }
  function writeConfig() {
    if (configWriter.running) return
    root.configDirty = false
    configWriter.command = ["sh", "-c", 'umask 077; mkdir -p "$(dirname "$1")" && tmp=$(mktemp "$1.XXXXXX") && { printf "%s\\n" "$2" > "$tmp" && mv -f "$tmp" "$1"; }',
      "sh", root.configFile, JSON.stringify({
        borders: root.borders, pulse: root.pulse, solid: root.solid, textShadow: root.textShadow, privacyKeys: root.privacyKeys, scenes: root.scenes, followSessions: root.followSessions, matrixOverrides: root.matrixOverrides, glassOverrides: root.glassOverrides, glass: root.glass, glassColor: root.glassColor, glassTint: root.glassTint, glassBlur: root.glassBlur, strength: root.strength, blur: root.blur,
        hiddenSources: root.hiddenSources,
        imageSources: root.imageSources, collapsedFolders: root.collapsedFolders, browseFolder: root.browseFolder,
        withWallpaper: root.withWallpaper, welcomed: root.welcomed, newTerminals: root.newDefault,
        moodTone: root.moodTone, baseColour: root.baseColour,
        projects: root.projects, savedLooks: root.savedLooks, sessionLabels: root.sessionLabels
      })]
    configWriter.running = true
  }

  function onConfig(text) {
    try {
      var cfg = JSON.parse(text)
      if (cfg && cfg.sessionLabels && typeof cfg.sessionLabels === "object" && !Array.isArray(cfg.sessionLabels)) {
        var labels = {}
        Object.keys(cfg.sessionLabels).slice(-1000).forEach(function(k) {
          if (Workspace.name(cfg.sessionLabels[k])) labels[k] = cfg.sessionLabels[k]
        })
        root.sessionLabels = labels
      }
      if (cfg && typeof cfg.borders === "boolean") root.borders = cfg.borders
      if (cfg && typeof cfg.pulse === "boolean") root.pulse = cfg.pulse
      if (cfg && typeof cfg.solid === "boolean") root.solid = cfg.solid
      if (cfg && typeof cfg.textShadow === "boolean") root.textShadow = cfg.textShadow
      if (cfg && typeof cfg.glass === "boolean") root.glass = cfg.glass
      if(cfg && Array.isArray(cfg.privacyKeys))root.privacyKeys=cfg.privacyKeys
      if(cfg && Array.isArray(cfg.scenes))root.scenes=cfg.scenes
      if(cfg && typeof cfg.followSessions==="boolean")root.followSessions=cfg.followSessions
      if (cfg && cfg.matrixOverrides && typeof cfg.matrixOverrides === "object") root.matrixOverrides = cfg.matrixOverrides
      if (cfg && cfg.glassOverrides && typeof cfg.glassOverrides === "object") root.glassOverrides = cfg.glassOverrides
      if (cfg && Palette.glassColor(cfg.glassColor)) root.glassColor = Palette.glassColor(cfg.glassColor)
      if (cfg && typeof cfg.glassTint === "number") root.glassTint = Palette.glassLevel(cfg.glassTint, 100, Palette.GLASS_TINT)
      if (cfg && typeof cfg.glassBlur === "number") root.glassBlur = Palette.glassLevel(cfg.glassBlur, 60, Palette.GLASS_BLUR)
      if (cfg && Array.isArray(cfg.hiddenSources)) root.hiddenSources = cfg.hiddenSources.filter(Palette.isImagePath)
      if (cfg && Array.isArray(cfg.imageSources)) root.imageSources = Palette.normalizeImageSources(cfg.imageSources)
      if (cfg && Array.isArray(cfg.collapsedFolders))
        root.collapsedFolders = cfg.collapsedFolders.filter(function (k) {
          return k === "@builtin" || k === "@files" || Palette.cleanSourcePath(k) === k
        }).slice(0, 1000)
      if (cfg && typeof cfg.browseFolder === "string") root.browseFolder = Palette.cleanSourcePath(cfg.browseFolder)
      if (cfg && typeof cfg.strength === "number") root.strength = Palette.normalizeWallpaper({ path: "/x.png", strength: cfg.strength }).strength
      if (cfg && typeof cfg.blur === "number") root.blur = Palette.normalizeBlur(cfg.blur)
      if (cfg && typeof cfg.withWallpaper === "boolean") root.withWallpaper = cfg.withWallpaper
      if (cfg && (cfg.moodTone === "auto" || cfg.moodTone === "dark" || cfg.moodTone === "light")) root.moodTone = cfg.moodTone
      if (cfg && Palette.isHex(cfg.baseColour)) root.baseColour = String(cfg.baseColour).toLowerCase()
      if (cfg && cfg.welcomed === true) root.welcomed = true
      if (cfg && Array.isArray(cfg.savedLooks)) root.savedLooks = Workspace.library(cfg.savedLooks)
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
    if (!root.configLoaded && root.themeBorders.active) {
      root.repaintAll = true
      root.reapply()
    }
    root.configLoaded = true
    root.scanImages()
    if (root.requests.length) root.scan()
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
    + 'printf "%s\\t%s\\t%s\\n" "$p" "$d" "$r"; done; true; printf \"\\n@@SESSIONS@@\\n\"; python3 -I \"$2/bin/ombre-sessions\" list'

  readonly property string catalogScript:
    'printf "@@WALLPAPER %s\\n" "$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null)"\n'
    + 'for f in "$HOME"/Wallpapers/Ombre/*; do [ -f "$f" ] && printf "@@OMBRE %s\\n" "$f"; done\n'
    + 'for d in "$HOME/Pictures" "$HOME/Pictures/Wallpapers" "$HOME/Wallpapers" "$HOME/Downloads" "$HOME/.config/omarchy/backgrounds" /mnt /media "/run/media/$USER"; do\n'
    + '  [ -d "$d" ] && printf "@@PLACE %s\\n" "$d"\n'
    + 'done\n'
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
  //   ghostty PID CONFDIR SHADOW COLORS STRENGTH BLUR PATH   per-window wallpaper and shaders, then SIGUSR2
  //     SHADOW is dark, light or -; with Glass on, glass:RRGGBB:TINT:BLUR plus -dark or -light,
  //     written into a per-window shader by bin/ombre-glass. STRENGTH BLUR PATH are "- 0 -" for
  //     no wallpaper; Glass needs a wallpaper to show through.
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
    + '      cdir=${arg%% *}; rest=${arg#* }; shadow=${rest%% *}; rest=${rest#* }; colors=${rest%% *}; rest=${rest#* }; strength=${rest%% *}; rest=${rest#* }; blur=${rest%% *}; path=${rest#* }\n'
    + '      case $cdir in /*/ghostty/) ;; *) continue ;; esac\n'
    + "      matrixAnimation=always; matrix=; case $shadow in matrix:*) matrix=${shadow%%~*}; shadow=${shadow#*~} ;; esac\n"
    + '      glass=; case $shadow in glass*)\n'
    + '        glass=${shadow%%-*}; case $shadow in *-dark) shadow=dark ;; *-light) shadow=light ;; *) shadow=- ;; esac\n'
    + '        ;;\n'
    + '      esac\n'
    + '      [ -d "$cdir" ] && [ ! -L "${cdir%/}" ] && [ -O "$cdir" ] || continue\n'
    + "      if [ -n \"$matrix\" ]; then settings=${matrix#matrix:}; old=$IFS; IFS=:; set -- $settings; IFS=$old; [ \"${6:-0}\" = 1 ] && matrixAnimation=false; matrix=$(python3 -I \"$plug/bin/ombre-matrix\" --dir \"$cdir\" --pid \"$key\" --settings \"${matrix#matrix:}\") || continue; fi\n"
    + '      if [ -n "$glass" ]; then\n'
    + '        old=$IFS; IFS=:; set -- $glass; IFS=$old; glass=\n'
    + '        if [ "$strength" != "-" ]; then glass=$(python3 -I "$plug/bin/ombre-glass" --dir "$cdir" --pid "$key" --color "${2:-000000}" --tint "${3:-86}" --blur "${4:-36}") || glass=; fi\n'
    + '      fi\n'
    + '      if [ "$strength" != "-" ] && [ "$blur" != "0" ]; then\n'
    + '        if prepared=$(printf "%s\\n" "$path" | timeout 15 python3 -I "$plug/bin/ombre-blur" --amount "$blur"); then path=$prepared; else printf "wallpaper-error\\n"; continue; fi\n'
    + '      fi\n'
    + '      {\n'
    + '        echo "app-notifications = no-config-reload"\n'
    + '        if [ "$colors" != "-" ]; then printf "%s\\n" "$colors" | tr ";" "\\n"; fi\n'
    + "        if [ -n \"$matrix\" ]; then printf 'custom-shader = \"%s\"\\n' \"$matrix\"; echo \"background-opacity = 0.5\"; echo \"background-opacity-cells = true\"; fi\n"
    // Glass runs first: it reads the cell layers by alpha and hands an opaque frame on.
    + '        if [ -n "$glass" ] && [ "$strength" != "-" ]; then\n'
    + '          printf "custom-shader = \\"%s\\"\\n" "$glass"\n'
    + '          echo "background-opacity = 0.5"\n'
    + '          echo "background-opacity-cells = true"\n'
    + '        else glass=; fi\n'
    + "        if [ \"$shadow\" = private ]; then printf 'custom-shader = \"%s/shaders/private.glsl\"\\n' \"$plug\"; echo \"custom-shader-animation = false\"; fi\n"
    + '        case $shadow in dark|light)\n'
    + '          printf "custom-shader = \\"%s/shaders/text-shadow-%s.glsl\\"\\n" "$plug" "$shadow" ;;\n'
    + '        esac\n'
    + '        case $glass$shadow in /*|dark|light) echo "custom-shader-animation = false" ;; esac\n'
    + "        if [ -n \"$matrix\" ]; then echo \"custom-shader-animation = $matrixAnimation\"; fi\n"
    + '        if [ "$strength" != "-" ]; then\n'
    + '          printf "background-image = \\"%s\\"\\n" "$path"\n'
    + '          echo "background-image-fit = cover"\n'
    + '          printf "background-image-opacity = %s\\n" "$strength"\n'
    + '        fi\n'
    + '      } > "$cdir$key.conf" && kill -USR2 "$key" && printf "wallpaper-ok\\n" ;;\n'
    + '  esac\n'
    + 'done 2>/dev/null\n'

  Process {
    id: writer
    stdout: SplitParser {
      onRead: function(data) {
        if (data === "wallpaper-error") root.wallpaperMessage = "Could not render wallpaper blur. Check that the image is readable and python-pillow is installed."
      }
    }
    stdinEnabled: true
    running: true
    command: ["sh", "-c", root.writerScript, "sh", root.runtimeDir, root.pluginDir]
    onExited: restartWriter.start()
  }

  Timer { id: restartWriter; interval: 1000; onTriggered: writer.running = true }

  Process {
    id: agentThemeProc
    stdout: StdioCollector { onStreamFinished: root.onAgentThemes(text) }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 && !root.agentThemeStatus.errors.length)
        root.agentThemeMessage = "Could not link app themes. Check that Python 3.11 or newer is installed."
    }
  }

  Process {
    id: sessionWorker
    running: true
    command: ["python3", "-I", root.pluginDir + "/bin/ombre-sessions", "serve"]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var reply = JSON.parse(line)
          if (reply.error) root.sessionMessage = reply.error
          else if (reply.focused) root.dismiss()
        } catch (error) { root.sessionMessage = "Invalid session adapter response" }
      }
    }
  }
  Timer {
    interval: root.privacyKeys.length || root.focusMode ? 600 : root.opened ? 3000 : 10000
    running: root.opened || root.projects.length > 0 || root.newDefault.mode !== "none"
    repeat: true
    onTriggered: root.scan()
  }

  Process {
    id: scanner
    command: ["sh", "-c", root.scanScript, "sh", root.runtimeDir, root.pluginDir]
    stdout: StdioCollector { onStreamFinished: root.onScan(text) }
  }

  Process {
    id: reapplyScan
    command: ["sh", "-c", root.scanScript, "sh", root.runtimeDir, root.pluginDir]
    stdout: StdioCollector { onStreamFinished: root.onReapplyScan(text) }
  }

  Process {
    id: catalogProc
    command: ["sh", "-c", root.catalogScript]
    stdout: StdioCollector { onStreamFinished: root.onCatalog(text) }
  }

  Process {
    id: imagesProc
    stdout: StdioCollector { onStreamFinished: root.onImageScan(text) }
    onExited: function (code) {
      if (code !== 0) root.wallpaperMessage = "Could not read the added images. Ombre needs python3 for that."
      if (root.imageScanAgain) { root.imageScanAgain = false; Qt.callLater(root.scanImages) }
    }
  }

  Process {
    id: moodProc
    stdout: StdioCollector { onStreamFinished: root.onMoods(text) }
  }

  Process {
    id: colourProc
    stdout: StdioCollector { onStreamFinished: root.onColours(text) }
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

  Timer { id: configSaveLater; interval: 40; onTriggered: root.writeConfig() }
  Process {
    id: configWriter
    onExited: function (code) {
      if (code !== 0) root.libraryMessage = "Could not save Ombre settings. Check that the configuration folder is writable."
      else if (root.configDirty) configSaveLater.restart()
    }
  }
  Process { id: solidWriter }
  Timer { id: solidLater; interval: 400; onTriggered: root.applySolid() }
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
    id: borderProbe
    command: ["sh", "-c", "hyprctl -j getoption general:col.active_border; printf '\\n@@\\n'; hyprctl -j getoption general:col.inactive_border"]
    stdout: StdioCollector {
      onStreamFinished: {
        var halves = String(text).split("@@")
        var active = Palette.themeGradient(halves[0]), inactive = Palette.themeGradient(halves[1] || "")
        if (!active && !inactive) return
        var changed = active !== root.themeBorders.active || inactive !== root.themeBorders.inactive
        root.themeBorders = { active: active, inactive: inactive }
        // Windows painted before the theme was known (or under the old theme) get it now.
        if (changed && root.configLoaded) { root.repaintAll = true; root.reapply() }
      }
    }
  }

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
    function onBackgroundChanged() { borderProbe.running = true; reapplyLater.restart(); root.loadCatalog() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var data = String(event.data || "").trim()
      switch (event.name) {
      case "configreloaded": borderProbe.running = true; reapplyLater.restart(); break
      case "activewindowv2": root.activeAddress = data; root.stopPulse(data); if(root.focusMode || root.privacyKeys.length)root.scan(); break
      case "closewindow":
        if (root.opened) root.scan()
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
      case "urgent":
        root.requestPulse(data)
        var signals=Object.assign({},root.signalStates)
        for(var si=0;si<root.terminals.length;si++){var st=root.terminals[si];if(st.address===data || st.hostAddress===data)signals[Workspace.key(st)]="input"}
        root.signalStates=signals;break
      case "openwindow":
        if (root.solid) solidLater.restart()
        // A window can take seconds to start its shell; keep looking until it
        // shows up in a scan.
        if (root.newDefault.mode !== "none" || root.textShadow || root.glass || root.solid || root.projects.length > 0) {
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

  Component.onCompleted: { borderProbe.running = true; root.loadCatalog() }

  // Shutting down mid-pulse would leave a pulse color on the border.
  Component.onDestruction: {
    for (var addr in root.pulses) root.paintBorder({ address: addr }, root.pulses[addr].look)
  }

  // ---- UI ---------------------------------------------------------------
  // A tint for the terminals being styled; "" is none. Hovering tries it on the
  // selected terminal, a click keeps it on every target.
  component Swatch: Item {
    id: swatch
    property string value: ""
    readonly property var background: root.selectedTerm ? Palette.backgroundLook(root.selectedTerm.look) : null
    readonly property bool chosen: root.selectedTerm !== null
      && (value ? background !== null && background.kind === "tint" && background.id === value : background === null)
    readonly property bool hot: hover.containsMouse

    width: Style.space(26)
    height: width
    Accessible.role: Accessible.Button
    Accessible.name: value ? Palette.hue(value).name + " tint" : "No tint"
    Accessible.onPressAction: root.applyTintTargets(swatch.value)

    Rectangle {
      anchors.centerIn: parent
      width: parent.width + Style.space(7)
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
      scale: swatch.hot ? 1.14 : 1.0
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
      onEntered: {
        root.hoverText = swatch.value ? Palette.hue(swatch.value).name + " tint · keeps the text colours" : "No tint · the terminal's own background"
        root.preview(root.current, Palette.tintLook(swatch.value), "background")
      }
      onExited: { root.hoverText = ""; previewEnd.restart() }
      onClicked: root.applyTintTargets(swatch.value)
    }
  }

  component TabButton: Item {
    id: tabButton
    property string name: ""
    readonly property bool on: root.tab === name
    width: tabText.implicitWidth + Style.space(4)
    height: tabText.implicitHeight + Style.space(18)
    Accessible.role: Accessible.PageTab
    Accessible.name: root.tabNames[name] || name
    Accessible.onPressAction: { root.endPreview(); root.tab = tabButton.name; root.tabChosen = true }

    Text {
      id: tabText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.tabNames[tabButton.name] || tabButton.name
      color: tabButton.on || tabArea.containsMouse ? root.text : root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: tabButton.on
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(2, Style.space(2))
      radius: height / 2
      color: root.accent
      visible: tabButton.on
    }

    MouseArea {
      id: tabArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { root.endPreview(); root.tab = tabButton.name; root.tabChosen = true; keyCatcher.forceActiveFocus() }
    }
  }

  // A row of mutually exclusive choices in one outline, the current one filled.
  component Segmented: Rectangle {
    id: seg
    property var options: []      // [{id, label}]
    property string current: ""
    signal picked(string id)
    width: segRow.implicitWidth + Style.space(6)
    height: segRow.implicitHeight + Style.space(6)
    radius: Style.cornerRadius
    color: "transparent"
    border.width: Math.max(1, Style.space(1))
    border.color: root.subtle

    Row {
      id: segRow
      anchors.centerIn: parent
      spacing: Style.space(2)
      Repeater {
        model: seg.options
        delegate: Rectangle {
          id: segItem
          required property var modelData
          readonly property bool on: seg.current === modelData.id
          width: segText.implicitWidth + Style.space(18)
          height: segText.implicitHeight + Style.space(10)
          radius: Math.max(0, Style.cornerRadius - Style.space(2))
          color: on ? Commons.Color.menu.selectedBackground : segArea.containsMouse ? Util.alpha(root.text, 0.06) : "transparent"
          Accessible.role: Accessible.Button
          Accessible.name: modelData.label
          Accessible.onPressAction: seg.picked(segItem.modelData.id)
          Text {
            id: segText
            anchors.centerIn: parent
            text: segItem.modelData.label
            color: segItem.on || segArea.containsMouse ? root.text : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: segItem.on
          }
          MouseArea {
            id: segArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { seg.picked(segItem.modelData.id); keyCatcher.forceActiveFocus() }
          }
        }
      }
    }
  }

  // Small capitals over a group of controls.
  component SectionLabel: Text {
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: Style.space(1)
    font.capitalization: Font.AllUppercase
  }

  // A key, drawn as a keycap.
  component Keycap: Rectangle {
    id: keycap
    property string label: ""
    width: Math.max(height, keyText.implicitWidth + Style.space(10))
    height: keyText.implicitHeight + Style.space(4)
    radius: Style.space(4)
    color: "transparent"
    border.width: Math.max(1, Style.space(1))
    border.color: root.subtle
    Text {
      id: keyText
      anchors.centerIn: parent
      text: keycap.label
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One switch in Settings: what it does, its key, and the switch.
  component SettingRow: Rectangle {
    id: settingRow
    property string name: ""
    property string detail: ""
    property string key: ""
    property bool checked: false
    signal toggled()
    width: parent ? parent.width : 0
    height: Math.max(settingText.implicitHeight, settingSwitch.height) + Style.space(24)
    color: "transparent"
    Accessible.role: Accessible.CheckBox
    Accessible.name: name
    Accessible.checked: checked
    Accessible.onToggleAction: settingRow.toggled()

    Column {
      id: settingText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(14)
      anchors.right: settingKey.left
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      Text {
        text: settingRow.name
        color: root.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: settingRow.detail
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
    Keycap {
      id: settingKey
      visible: settingRow.key !== ""
      label: settingRow.key
      anchors.right: settingSwitch.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
    }
    ToggleSwitch {
      id: settingSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      checked: settingRow.checked
      onToggled: settingRow.toggled()
    }
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(1, Style.space(1))
      color: root.subtle
    }
  }

  // A bordered group in a tab or in Settings.
  component Group: Rectangle {
    default property alias content: panelColumn.data
    property alias spacing: panelColumn.spacing
    height: panelColumn.implicitHeight + Style.space(28)
    radius: Style.cornerRadius
    color: Util.alpha(root.text, 0.02)
    border.width: Math.max(1, Style.space(1))
    border.color: root.subtle
    Column {
      id: panelColumn
      x: Style.space(14)
      y: Style.space(14)
      width: parent.width - Style.space(28)
      spacing: Style.space(12)
    }
  }

  component ColorField: Rectangle {
    id: colorField
    property string value: ""
    signal applied(string value)
    width: Style.space(116)
    height: Style.space(30)
    radius: Style.cornerRadius
    color: root.surface
    border.width: Math.max(1, Style.space(1))
    border.color: colorInput.activeFocus ? root.accent : root.subtle
    onValueChanged: if (!colorInput.activeFocus) colorInput.text = value
    Text {
      anchors.centerIn: parent
      visible: colorInput.text === ""
      text: "#rrggbb"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    TextInput {
      id: colorInput
      property string targetPty: ""
      onActiveFocusChanged: if (activeFocus) targetPty = root.selectedTerm ? root.selectedTerm.pty : ""
      anchors.fill: parent
      anchors.margins: Style.space(6)
      text: colorField.value
      color: root.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      selectByMouse: true
      maximumLength: 7
      validator: RegularExpressionValidator { regularExpression: /#[0-9a-fA-F]{6}/ }
      onAccepted: {
        if (acceptableInput && root.selectedTerm && targetPty === root.selectedTerm.pty) colorField.applied(text)
        keyCatcher.forceActiveFocus()
      }
      onEditingFinished: {
        if (acceptableInput && text !== colorField.value && root.selectedTerm && targetPty === root.selectedTerm.pty)
          colorField.applied(text)
        text = colorField.value
      }
      Keys.onEscapePressed: { text = colorField.value; keyCatcher.forceActiveFocus() }
      // No paste: Qt reads the whole clipboard offer before maximumLength and the
      // validator apply, so a huge or endless clipboard could stall the shell.
      // A colour is seven characters; type it.
      Keys.onPressed: function (event) {
        if (event.matches(StandardKey.Paste) || (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier)))
          event.accepted = true
      }
    }
  }

  component TextButton: Rectangle {
    id: textButton
    property string label: ""
    property bool chosen: false
    signal activated()
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.onPressAction: if (enabled) activated()
    opacity: enabled ? 1 : 0.4
    width: buttonText.implicitWidth + Style.space(16)
    height: buttonText.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: chosen ? Commons.Color.menu.selectedBackground : "transparent"
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
      onClicked: if (textButton.enabled) textButton.activated()
    }
  }

  // One wallpaper in the grid; path "" is None. Added images can be removed.
  component WallTile: Rectangle {
    id: wallTile
    property string path: ""
    property bool removable: false
    readonly property bool chosen: root.selectedTerm !== null
      && (root.selectedTerm.wallpaper ? root.selectedTerm.wallpaper.path === path : path === "")
    width: Style.space(128)
    height: Style.space(72)
    radius: Style.cornerRadius
    color: root.themeBackground
    border.width: Math.max(1, Style.space(chosen ? 2 : 1))
    border.color: chosen ? root.accent : wallArea.containsMouse ? root.text : root.subtle
    clip: true
    opacity: path && root.hiddenSources.indexOf(path) >= 0 ? 0.35 : 1

    Image {
      visible: wallTile.path !== ""
      anchors.fill: parent
      anchors.margins: parent.border.width
      source: wallTile.path ? Palette.fileUrl(wallTile.path) : ""
      sourceSize.width: Style.space(256)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
    }

    Text {
      visible: wallTile.path === ""
      anchors.centerIn: parent
      text: "None"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: wallArea
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: root.targetTakesWallpaper ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: {
        root.hoverText = wallTile.path ? Palette.basename(wallTile.path) : "No wallpaper"
        if (root.selectedTakesWallpaper)
          root.previewWallpaper(root.current, wallTile.path ? { path: wallTile.path, strength: root.strength, blur: root.currentBlur } : null)
      }
      onExited: { root.hoverText = ""; previewEnd.restart() }
      onClicked: function (mouse) {
        if (mouse.button === Qt.RightButton && wallTile.path) {
          if (root.hiddenSources.indexOf(wallTile.path) >= 0) root.unhideSource(wallTile.path)
          else root.hideSource(wallTile.path)
        } else if (root.targetTakesWallpaper)
          root.applyWallpaperTargets(wallTile.path ? { path: wallTile.path, strength: root.strength, blur: root.currentBlur } : null)
      }
    }

    Rectangle {
      visible: wallTile.removable && (wallArea.containsMouse || removeArea.containsMouse)
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(4)
      width: Style.space(20)
      height: width
      radius: width / 2
      color: root.surface
      border.width: Math.max(1, Style.space(1))
      border.color: removeArea.containsMouse ? root.text : root.subtle

      Text {
        anchors.centerIn: parent
        text: "×"
        color: root.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      MouseArea {
        id: removeArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hoverText = "Remove " + Palette.basename(wallTile.path) + " from Ombre (the file stays)"
        onExited: root.hoverText = ""
        onClicked: root.removeImageSource(wallTile.path)
      }
    }
  }

  Variants {
    model: Quickshell.screens
    delegate: PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.privacyKeys.length > 0
      anchors {top:true;bottom:true;left:true;right:true}
      color:"transparent";exclusionMode:ExclusionMode.Ignore
      WlrLayershell.namespace:"omarchy-ombre-privacy"
      WlrLayershell.layer:WlrLayer.Overlay
      WlrLayershell.keyboardFocus:WlrKeyboardFocus.None
      mask: Region {}
      Repeater {
        model: root.terminals.filter(function(t){return root.privacyKeys.indexOf(Workspace.key(t))>=0 && t.visible && t.monitor===modelData.name})
        delegate: Rectangle {
          required property var modelData
          x:modelData.lx;y:modelData.ly;width:modelData.w;height:modelData.h
          color:"#10131a";radius:8
          Text {anchors.centerIn:parent;text:"Private terminal · reveal in Ombre Studio";color:"#a4b0bf"}
        }
      }
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
      visible: root.opened || (root.focusMode && root.terminals.some(function(t){return t.address === root.activeAddress || t.hostAddress === root.activeAddress}))
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-ombre-spotlight"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      readonly property var term: root.opened ? root.selectedTerm : (root.terminals.filter(function(t){return t.address === root.activeAddress || t.hostAddress === root.activeAddress})[0] || null)
      readonly property bool here: term !== null && term.visible === true && term.monitor === modelData.name
      readonly property int gap: Style.space(5)
      readonly property color scrim: Commons.Color.menu.scrim
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

    // Two columns: the terminals on the left, what to give them on the right.
    // Settings swaps both columns for its sections.
    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(panel.width - Style.gapsOut * 4, Style.space(1240))
      height: Math.min(panel.height - Style.gapsOut * 4, Style.space(820))
      radius: Style.cornerRadius
      color: root.surface
      borderSpec: root.borderSpec

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: root.pad
        focus: true

        Keys.onPressed: function (event) {
          var k = event.key
          var shift = (event.modifiers & Qt.ShiftModifier) !== 0
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          if (k === Qt.Key_B && !ctrl) root.setBorders(!root.borders)
          else if (k === Qt.Key_P && !ctrl) root.setPulse(!root.pulse)
          else if (k === Qt.Key_O && !ctrl) root.setSolid(!root.solid)
          else if (k === Qt.Key_T && !ctrl) root.setTextShadow(!root.textShadow)
          else if (k === Qt.Key_G && !ctrl) root.setGlass(!root.selectedGlass.on)
          else if (root.view === "settings") {
            if (k === Qt.Key_Escape || k === Qt.Key_Backspace || k === Qt.Key_Comma) root.view = "style"
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.dismiss()
            else if (k === Qt.Key_Up || k === Qt.Key_K || k === Qt.Key_Backtab) root.nextSection(-1)
            else if (k === Qt.Key_Down || k === Qt.Key_J || k === Qt.Key_Tab) root.nextSection(1)
            else return
          }
          else if (root.browsing && root.tab === "wallpapers" && !ctrl && root.browserKey(k)) { }
          else if (ctrl && k === Qt.Key_F) { terminalSearch.forceActiveFocus(); terminalSearch.selectAll() }
          else if (ctrl && k === Qt.Key_Z) root.travelHistory(root.current, shift ? "redo" : "undo")
          else if (ctrl && k === Qt.Key_Y) root.travelHistory(root.current, "redo")
          else if (ctrl && k === Qt.Key_A) root.selectVisible(false)
          else if (ctrl && k === Qt.Key_Space) root.toggleMarked(root.current)
          else if (ctrl && k === Qt.Key_S) { root.tab = "saved"; root.tabChosen = true; savedName.forceActiveFocus() }
          else if (ctrl && (k === Qt.Key_Return || k === Qt.Key_Enter)) root.jumpSession()
          else if (ctrl) return
          else if (k === Qt.Key_Slash) terminalSearch.forceActiveFocus()
          else if (k === Qt.Key_Comma) root.showSettings("")
          else if (k === Qt.Key_Escape || k === Qt.Key_Return || k === Qt.Key_Enter) root.dismiss()
          else if (k === Qt.Key_Tab || k === Qt.Key_Right) root.nextTab(1)
          else if (k === Qt.Key_Backtab || k === Qt.Key_Left) root.nextTab(-1)
          else if (k === Qt.Key_W && root.tab === "moods") root.stepSource(shift ? -1 : 1)
          else if (k === Qt.Key_X && root.tab === "moods" && root.activeMoodSource) {
            if (root.hiddenSources.indexOf(root.activeMoodSource) >= 0) root.unhideSource(root.activeMoodSource)
            else root.hideSource(root.activeMoodSource)
          }
          else if (k === Qt.Key_H && (root.tab === "moods" || root.tab === "wallpapers")) root.showHidden = !root.showHidden
          else if (k === Qt.Key_D && root.selectedTerm) root.saveDefaultFrom(root.selectedTerm)
          else if (k === Qt.Key_F && root.selectedTerm) root.saveProjectFrom(root.selectedTerm)
          else if (k === Qt.Key_A && root.tab === "wallpapers") root.openBrowser()
          else if (root.filteredTerminals.length === 0) return
          else if (k === Qt.Key_Down || k === Qt.Key_J) root.moveCurrent(1, false)
          else if (k === Qt.Key_Up || k === Qt.Key_K) root.moveCurrent(-1, false)
          else if (k >= Qt.Key_1 && k <= Qt.Key_8) root.applyTintTargets(Palette.HUES[k - Qt.Key_1].id)
          else if (k === Qt.Key_0 || k === Qt.Key_Backspace || k === Qt.Key_Delete) {
            if (root.tab === "wallpapers") root.applyWallpaperTargets(null)
            else root.resetTargets()
          }
          else if (k === Qt.Key_Space) root.stepLook(shift ? -1 : 1)
          else if (k === Qt.Key_N) root.applyTintTargets(root.nextHue(root.selectedTerm.look))
          else return
          event.accepted = true
        }

        // ---- Header: brand, search, filter, settings, close ----
        Item {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Style.space(48)

          Row {
            id: brand
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)
            Image {
              anchors.verticalCenter: parent.verticalCenter
              source: Qt.resolvedUrl("assets/brand/ombre-mark.svg")
              width: Style.space(34)
              height: width
              sourceSize: Qt.size(width * 2, height * 2)
              Accessible.ignored: true
            }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                text: "OMBRE"
                color: root.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.letterSpacing: Style.space(3)
                font.bold: true
              }
              Text {
                objectName: "ombreVersionLabel"
                text: root.pluginVersion ? "v" + root.pluginVersion : "—"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                Accessible.name: root.pluginVersion ? "Ombre version " + root.pluginVersion : "Ombre version unavailable"
              }
            }
          }

          TextField {
            id: terminalSearch
            objectName: "ombreTerminalSearch"
            visible: root.view === "style"
            anchors.left: brand.right
            anchors.leftMargin: Style.space(28)
            anchors.right: headerRight.left
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Find a session, label, command or project   ( / )"
            text: root.searchText
            onTextChanged: if (root.searchText !== text) root.searchText = text
            onAccepted: root.jumpSession()
            Keys.onDownPressed: root.moveCurrent(1, false)
            Keys.onUpPressed: root.moveCurrent(-1, false)
            Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
            Accessible.name: "Search terminals by title, project or workspace"
          }

          Text {
            visible: root.view === "settings"
            anchors.left: brand.right
            anchors.leftMargin: Style.space(28)
            anchors.verticalCenter: parent.verticalCenter
            text: "Settings"
            color: root.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Row {
            id: headerRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            Segmented {
              visible: root.view === "style"
              anchors.verticalCenter: parent.verticalCenter
              options: [{ id: "all", label: "All workspaces" }, { id: "here", label: "This workspace" }]
              current: root.workspaceOnly ? "here" : "all"
              onPicked: function (id) { root.workspaceOnly = id === "here" }
            }
            TextButton {
              anchors.verticalCenter: parent.verticalCenter
              label: root.view === "studio" ? "← Styling" : "Studio"
              onActivated: root.view = root.view === "studio" ? "style" : "studio"
            }
            TextButton {
              anchors.verticalCenter: parent.verticalCenter
              label: root.view === "settings" ? "← Back to styling" : "󰒓  Settings"
              chosen: root.view === "settings"
              Accessible.name: root.view === "settings" ? "Back to styling" : "Settings"
              onActivated: { if (root.view === "settings") root.view = "style"; else root.showSettings(""); keyCatcher.forceActiveFocus() }
            }
            TextButton {
              anchors.verticalCenter: parent.verticalCenter
              label: "×"
              Accessible.name: "Close Ombre"
              onActivated: root.dismiss()
            }
          }
        }

        Rectangle {
          id: headerRule
          anchors.top: header.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(1, Style.space(1))
          color: root.subtle
        }

        // ---- Footer: what the pointer is over, or the keys ----
        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          elide: Text.ElideRight
          text: root.sessionMessage || root.hoverText || (root.view === "settings"
            ? "↑ ↓ section · B P O T G switch effects · Esc back to styling"
            : "Ctrl+Enter jump · ↑ ↓ session · ← → tab · Ctrl+Space tick · Space next look · 1–8 tint · Ctrl+Z undo · Ctrl+S save · , settings · Esc close")
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          id: footerRule
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(1, Style.space(1))
          color: root.subtle
        }

        Item {
          id: body
          anchors.top: headerRule.bottom
          anchors.topMargin: Style.space(14)
          anchors.bottom: footerRule.top
          anchors.bottomMargin: Style.space(12)
          anchors.left: parent.left
          anchors.right: parent.right

          readonly property int sideWidth: Math.min(Style.space(340), Math.round(width * 0.32))

          Studio { anchors.fill: parent; visible: root.view === "studio"; controller: root }

          // ======== Styling ========
          Item {
            id: styleView
            anchors.fill: parent
            visible: root.view === "style"

            // ---- Terminals ----
            Item {
              id: side
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: body.sideWidth

              Item {
                id: sideHead
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: Style.space(26)
                SectionLabel {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Terminals · " + (root.markedKeys.length ? root.markedKeys.length + " ticked"
                    : root.filteredTerminals.length + (root.filteredTerminals.length === root.terminals.length ? " open" : " of " + root.terminals.length))
                }
                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.filteredTerminals.length > 1
                  text: root.markedKeys.length ? "Clear ticks" : "Tick all"
                  color: tickAllArea.containsMouse ? root.text : root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  MouseArea {
                    id: tickAllArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (root.markedKeys.length) root.markedKeys = []; else root.selectVisible(false); keyCatcher.forceActiveFocus() }
                  }
                }
              }

              Text {
                visible: root.filteredTerminals.length === 0
                anchors.top: sideHead.bottom
                anchors.topMargin: Style.space(10)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(4)
                wrapMode: Text.WordWrap
                text: root.terminals.length ? "No terminals match. Clear the search or switch to All workspaces." : scanner.running ? "Looking for terminals…"
                  : "No terminal sessions found. Open a terminal, Omaguake tab or tmux session."
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Row {
                id: identityControls
                anchors.top: sideHead.bottom
                anchors.topMargin: Style.space(8)
                width: parent.width
                spacing: Style.space(6)
                TextField {
                  id: sessionLabel
                  objectName: "ombreSessionLabel"
                  width: Math.max(80, parent.width - jumpButton.width - Style.space(6))
                  placeholderText: "Name this session…"
                  maximumLength: 64
                  Binding {
                    target: sessionLabel
                    property: "text"
                    value: root.selectedTerm ? root.selectedTerm.label || "" : ""
                    when: !sessionLabel.activeFocus
                  }
                  enabled: root.selectedTerm !== null
                  onAccepted: { root.labelSession(text); keyCatcher.forceActiveFocus() }
                  Accessible.name: "Session label; Enter to save"
                }
                TextButton {
                  id: jumpButton
                  label: "Jump ↗"
                  Accessible.name: "Switch to selected terminal session"
                  onActivated: root.jumpSession()
                }
              }

              Flickable {
                id: termList
                anchors.top: identityControls.bottom
                anchors.topMargin: Style.space(8)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: sideHint.top
                anchors.bottomMargin: Style.space(8)
                contentWidth: width
                contentHeight: termColumn.implicitHeight
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: termColumn
                  width: termList.width
                  spacing: Style.space(4)

                  Repeater {
                    model: root.opened ? root.filteredTerminals : []

                    delegate: Rectangle {
                      id: row
                      required property var modelData
                      readonly property int termIndex: modelData.sourceIndex
                      readonly property bool selected: termIndex === root.current
                      readonly property bool marked: root.markedKeys.indexOf(Workspace.key(modelData)) >= 0
                      readonly property real aspect: Math.max(0.2, Math.min(5, modelData.h / Math.max(1, modelData.w)))
                      readonly property var look: modelData.look
                      readonly property string where: modelData.root || modelData.cwd || ""

                      width: termColumn.width
                      height: Style.space(78)
                      radius: Style.cornerRadius
                      color: selected ? Commons.Color.menu.selectedBackground
                        : marked ? Util.alpha(root.accent, 0.10)
                        : rowArea.containsMouse ? Util.alpha(root.text, 0.05) : "transparent"
                      border.width: Math.max(1, Style.space(selected ? 2 : 1))
                      border.color: selected ? root.accent : "transparent"
                      Accessible.role: Accessible.ListItem
                      Accessible.name: modelData.title + (marked ? ", ticked" : "")

                      onSelectedChanged: if (selected) {
                        if (y < termList.contentY) termList.contentY = y
                        else if (y + height > termList.contentY + termList.height)
                          termList.contentY = y + height - termList.height
                      }

                      MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: function (mouse) { root.selectCard(row.termIndex, (mouse.modifiers & Qt.ControlModifier) !== 0); keyCatcher.forceActiveFocus() }
                        onDoubleClicked: { root.current = row.termIndex; root.jumpSession() }
                      }

                      // Tick box: add the terminal to the ones being styled.
                      Rectangle {
                        id: tick
                        x: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(18)
                        height: width
                        radius: Style.space(4)
                        color: row.marked ? root.accent : "transparent"
                        border.width: Math.max(1, Style.space(2))
                        border.color: row.marked ? root.accent : tickArea.containsMouse ? root.text : root.muted
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: (row.marked ? "Untick " : "Tick ") + row.modelData.title
                        Accessible.checked: row.marked
                        Accessible.onToggleAction: root.toggleMarked(row.termIndex)
                        Text {
                          anchors.centerIn: parent
                          visible: row.marked
                          text: "✓"
                          color: Palette.isLight(String(root.accent)) ? "#000000" : "#ffffff"
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                        }
                        MouseArea {
                          id: tickArea
                          anchors.fill: parent
                          anchors.margins: -Style.space(6)
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: { root.toggleMarked(row.termIndex); keyCatcher.forceActiveFocus() }
                        }
                      }

                      // Live thumbnail in the terminal's own colours.
                      Rectangle {
                        id: thumb
                        readonly property real innerWidth: width - border.width * 2
                        readonly property real innerHeight: height - border.width * 2
                        anchors.left: tick.right
                        anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(104)
                        height: Style.space(62)
                        radius: Style.space(4)
                        color: Palette.lookBackground(row.look, root.themeBackground) || root.themeBackground
                        border.width: Math.max(1, Style.space(2))
                        border.color: Palette.lookAccent(row.look) || root.subtle
                        clip: true

                        ScreencopyView {
                          anchors.centerIn: parent
                          width: Math.min(thumb.innerWidth, thumb.innerHeight / row.aspect)
                          height: Math.min(thumb.innerHeight, thumb.innerWidth * row.aspect)
                          captureSource: root.toplevelFor(row.modelData.address)
                          live: root.opened && root.view === "style"
                        }
                      }

                      Column {
                        anchors.left: thumb.right
                        anchors.leftMargin: Style.space(10)
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)

                        Row {
                          width: parent.width
                          spacing: Style.space(6)
                          Text {
                            width: Math.min(implicitWidth, parent.width - (needsYou.visible ? needsYou.width + Style.space(6) : 0))
                            text: row.modelData.label || row.modelData.title
                            elide: Text.ElideRight
                            color: root.text
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                          }
                          // The agent here finished and is waiting.
                          Rectangle {
                            id: needsYou
                            visible: root.pulses[row.modelData.address] !== undefined
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(8)
                            height: width
                            radius: width / 2
                            color: Palette.lookAccent(row.look) || root.accent
                          }
                        }
                        Text {
                          width: parent.width
                          visible: text !== ""
                          text: row.where ? Palette.tildePath(row.where, root.home) : (row.modelData.cls || "")
                          elide: Text.ElideMiddle
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                        Row {
                          width: parent.width
                          spacing: Style.space(6)
                          Rectangle {
                            visible: row.modelData.workspace !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            width: wsText.implicitWidth + Style.space(10)
                            height: wsText.implicitHeight + Style.space(2)
                            radius: Style.space(3)
                            color: Util.alpha(root.text, 0.08)
                            Text {
                              id: wsText
                              anchors.centerIn: parent
                              text: "ws " + row.modelData.workspace
                              color: root.text
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                            }
                          }
                          Rectangle {
                            visible: row.look !== null
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(8)
                            height: width
                            radius: Style.space(2)
                            color: Palette.lookAccent(row.look) || "transparent"
                          }
                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(0, parent.width - x)
                            text: {
                              var parts = [row.modelData.backend || "window", row.modelData.command || "", row.look ? Palette.lookLabel(row.look) : "Own colours"]
                              if (row.modelData.wallpaper) parts.push("󰋩 " + Palette.basename(row.modelData.wallpaper.path))
                              if (row.modelData.visible === false) parts.push("off screen")
                              return parts.join(" · ")
                            }
                            elide: Text.ElideRight
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }
                  }
                }
              }

              Text {
                id: sideHint
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(4)
                wrapMode: Text.WordWrap
                text: "Click a terminal to style it. Tick several to style them together."
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: sideRule
              anchors.left: side.right
              anchors.leftMargin: Style.space(16)
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.max(1, Style.space(1))
              color: root.subtle
            }

            // ---- Styling ----
            Item {
              id: main
              anchors.left: sideRule.right
              anchors.leftMargin: Style.space(20)
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom

              // Who gets the next pick, with undo and redo for the selected one.
              Item {
                id: targetRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: Math.max(targetFlow.implicitHeight, historyRow.height, Style.space(28))

                SectionLabel {
                  id: stylingLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Styling"
                }
                Flow {
                  id: targetFlow
                  anchors.left: stylingLabel.right
                  anchors.leftMargin: Style.space(12)
                  anchors.right: historyRow.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  Repeater {
                    model: root.actionTargets.slice(0, 4)
                    delegate: Rectangle {
                      id: targetChip
                      required property var modelData
                      readonly property var term: root.terminals[modelData] || null
                      width: Math.min(chipRow.implicitWidth + Style.space(16), Style.space(220))
                      height: chipRow.implicitHeight + Style.space(8)
                      radius: height / 2
                      color: Util.alpha(root.text, 0.07)
                      Row {
                        id: chipRow
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)
                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(8)
                          height: width
                          radius: Style.space(2)
                          color: (targetChip.term && Palette.lookAccent(targetChip.term.look)) || root.muted
                        }
                        Text {
                          width: Math.min(implicitWidth, Style.space(180))
                          text: targetChip.term ? targetChip.term.title : ""
                          elide: Text.ElideRight
                          color: root.text
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }
                    }
                  }
                  Text {
                    visible: root.actionTargets.length > 4
                    height: Style.space(24)
                    verticalAlignment: Text.AlignVCenter
                    text: "+" + (root.actionTargets.length - 4) + " more"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: root.selectedTerm !== null && root.markedKeys.length === 0 && root.selectedTerm.visible === false
                    height: Style.space(24)
                    verticalAlignment: Text.AlignVCenter
                    text: root.selectedTerm ? "on workspace " + root.selectedTerm.workspace + ", not on screen" : ""
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                Row {
                  id: historyRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  TextButton { label: "Undo"; enabled: root.selectedHistory.past.length > 0; onActivated: root.travelHistory(root.current, "undo") }
                  TextButton { label: "Redo"; enabled: root.selectedHistory.future.length > 0; onActivated: root.travelHistory(root.current, "redo") }
                }
              }

              // Tabs, and which layer a pick changes.
              Item {
                id: tabBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: targetRow.bottom
                anchors.topMargin: Style.space(10)
                height: Math.max(tabRow.height, scopeRow.height)

                Row {
                  id: tabRow
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  spacing: Style.space(24)
                  Repeater {
                    model: root.tabs
                    delegate: TabButton {
                      required property var modelData
                      name: modelData
                    }
                  }
                }

                Row {
                  id: scopeRow
                  visible: root.tab !== "wallpapers"
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Change"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Segmented {
                    anchors.verticalCenter: parent.verticalCenter
                    options: [{ id: "all", label: "Everything" }, { id: "text", label: "Text" }, { id: "background", label: "Background" }]
                    current: root.applyScope
                    onPicked: function (id) { root.endPreview(); root.applyScope = id }
                  }
                }
              }

              Rectangle {
                id: tabRule
                anchors.top: tabBar.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: Math.max(1, Style.space(1))
                color: root.subtle
              }

              Flickable {
                id: tabView
                anchors.top: tabRule.bottom
                anchors.topMargin: Style.space(16)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                contentWidth: width
                contentHeight: tabContent.implicitHeight + Style.space(8)
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                onVisibleChanged: contentY = 0

                Connections {
                  target: root
                  function onTabChanged() { tabView.contentY = 0 }
                }

                Column {
                  id: tabContent
                  width: tabView.width
                  spacing: Style.space(14)

                  // ---- Looks: saved looks and favourites ----
                  Column {
                    visible: root.tab === "saved"
                    width: parent.width
                    spacing: Style.space(10)
                    Row {
                      spacing: Style.space(8)
                      TextField {
                        id: savedName
                        objectName: "ombreSavedName"
                        width: Style.space(280)
                        maximumLength: 64
                        placeholderText: root.editingSavedName ? "New name for " + root.editingSavedName : "Name the selected terminal’s look…"
                        onAccepted: root.submitSavedName(text)
                        Keys.onEscapePressed: { root.editingSavedName = ""; text = ""; keyCatcher.forceActiveFocus() }
                        Accessible.name: "Saved look name"
                      }
                      TextButton { anchors.verticalCenter: parent.verticalCenter; label: root.editingSavedName ? "Rename" : "Save look"; enabled: root.editingSavedName !== "" || root.selectedTerm !== null; onActivated: root.submitSavedName(savedName.text) }
                      TextButton { anchors.verticalCenter: parent.verticalCenter; visible: root.editingSavedName !== ""; label: "Cancel"; onActivated: { root.editingSavedName = ""; savedName.text = "" } }
                      TextButton { anchors.verticalCenter: parent.verticalCenter; label: "★ Favourites only"; chosen: root.favoritesOnly; onActivated: root.favoritesOnly = !root.favoritesOnly }
                    }
                    Text {
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: root.libraryMessage || "A look keeps the exact colours, wallpaper, strength and blur. Click one to give it to every terminal you're styling."
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      visible: root.sortedLooks.length === 0
                      text: root.savedLooks.length ? "No favourites yet. Star a look to keep it close." : "No saved looks yet. Give a terminal a look, then name it above."
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Column {
                      spacing: Style.space(8)
                      Repeater {
                        model: root.opened && root.tab === "saved" ? root.sortedLooks : []
                        delegate: Row {
                          id: savedRow
                          required property var modelData
                          spacing: Style.space(8)
                          LookChip {
                            width: Style.space(260)
                            label: savedRow.modelData.name
                            look: root.savedChipLook(savedRow.modelData)
                            image: savedRow.modelData.wallpaper ? savedRow.modelData.wallpaper.path : ""
                            chosen: root.selectedTerm !== null && Workspace.same(root.selectedTerm, savedRow.modelData)
                            ring: root.accent
                            fontFamily: root.fontFamily
                            onHoverStarted: {
                              root.preview(root.current, savedRow.modelData.look, root.applyScope)
                              if (root.applyScope !== "text" && root.selectedTakesWallpaper) root.previewWallpaper(root.current, savedRow.modelData.wallpaper)
                            }
                            onHoverEnded: previewEnd.restart()
                            onPicked: root.applySavedTargets(savedRow.modelData)
                          }
                          TextButton {
                            anchors.verticalCenter: parent.verticalCenter
                            label: savedRow.modelData.favorite ? "★" : "☆"
                            chosen: savedRow.modelData.favorite
                            Accessible.name: (savedRow.modelData.favorite ? "Unstar " : "Star ") + savedRow.modelData.name
                            onActivated: root.favoriteNamedLook(savedRow.modelData.name)
                          }
                          TextButton { anchors.verticalCenter: parent.verticalCenter; label: "Update"; enabled: root.selectedTerm !== null; onActivated: root.saveNamedLook(savedRow.modelData.name, root.selectedTerm, true) }
                          TextButton { anchors.verticalCenter: parent.verticalCenter; label: "Rename"; onActivated: { root.editingSavedName = savedRow.modelData.name; savedName.text = savedRow.modelData.name; savedName.forceActiveFocus(); savedName.selectAll() } }
                          TextButton {
                            anchors.verticalCenter: parent.verticalCenter
                            label: root.pendingDeleteName === savedRow.modelData.name ? "Confirm delete" : "Delete"
                            onActivated: {
                              if (root.pendingDeleteName === savedRow.modelData.name) root.removeNamedLook(savedRow.modelData.name)
                              else { root.pendingDeleteName = savedRow.modelData.name; root.libraryMessage = "Click Confirm delete to remove " + savedRow.modelData.name + "." }
                            }
                          }
                        }
                      }
                    }
                  }

                  // ---- Colours: tints, Aether palettes from any colour, exact colours ----
                  Column {
                    visible: root.tab === "colours"
                    width: parent.width
                    spacing: Style.space(12)

                    SectionLabel { text: "Tint · keys 1–8, N for the next, 0 for none" }
                    Row {
                      spacing: Style.space(14)
                      Repeater {
                        model: Palette.HUES
                        delegate: Swatch { required property var modelData; value: modelData.id }
                      }
                      Swatch { value: "" }
                    }

                    Item { width: 1; height: Style.space(4) }
                    SectionLabel { text: "From any colour · full palettes made by Aether" }
                    Text {
                      visible: root.aetherBlocker !== ""
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: root.aetherBlocker
                      color: root.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Row {
                      visible: root.catalog.aether
                      spacing: Style.space(10)
                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(30)
                        height: width
                        radius: Style.cornerRadius
                        color: root.baseColour
                        border.width: Math.max(1, Style.space(1))
                        border.color: root.subtle
                      }
                      ColorField {
                        anchors.verticalCenter: parent.verticalCenter
                        value: root.baseColour
                        onApplied: function (value) { root.setBaseColour(value) }
                      }
                      Repeater {
                        model: Palette.HUES.map(function (h) { return h.hex }).concat([root.accentHex])
                        delegate: Rectangle {
                          required property var modelData
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(18)
                          height: width
                          radius: width / 2
                          color: modelData
                          border.width: root.baseColour === String(modelData).toLowerCase() ? Math.max(2, Style.space(2)) : 0
                          border.color: root.text
                          MouseArea {
                            anchors.fill: parent
                            anchors.margins: -Style.space(3)
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.hoverText = "Make palettes from " + String(modelData).toLowerCase()
                            onExited: root.hoverText = ""
                            onClicked: root.setBaseColour(String(modelData).toLowerCase())
                          }
                        }
                      }
                    }
                    Text {
                      visible: root.catalog.aether && (root.colourRunning !== "" || root.colourMessage !== "" || root.colourLooks.length === 0)
                      text: root.colourRunning ? "Aether is mixing palettes from " + root.colourRunning + "…"
                        : root.colourMessage || "Type a colour or pick one to get six full palettes."
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Flow {
                      visible: root.colourLooks.length > 0
                      width: parent.width
                      spacing: Style.space(8)
                      Repeater {
                        model: root.opened && root.tab === "colours" ? root.colourLooks : []
                        delegate: LookChip {
                          required property var modelData
                          look: modelData
                          label: String(modelData.description).split(" palette")[0]
                          chosen: root.selectedTerm !== null && Palette.sameLook(modelData, root.scopeLook(root.selectedTerm.look))
                          ring: root.accent
                          fontFamily: root.fontFamily
                          onHoverStarted: { root.hoverText = modelData.description; root.preview(root.current, modelData) }
                          onHoverEnded: { root.hoverText = ""; previewEnd.restart() }
                          onPicked: root.applyLookTargets(modelData)
                        }
                      }
                    }

                    Item { width: 1; height: Style.space(4) }
                    SectionLabel { text: "Exact colours" }
                    Row {
                      width: parent.width
                      spacing: Style.space(24)
                      Repeater {
                        model: ["text", "background"]
                        delegate: Column {
                          required property string modelData
                          width: (parent.width - Style.space(24)) / 2
                          spacing: Style.space(8)
                          Row {
                            spacing: Style.space(10)
                            Text {
                              text: modelData === "text" ? "Text" : "Background"
                              color: root.text
                              font.bold: true
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.body
                            }
                            Text {
                              text: !root.selectedTerm ? "" : modelData === "text"
                                ? Palette.textLabel(root.selectedTerm.look) : Palette.backgroundLabel(root.selectedTerm.look)
                              color: root.muted
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                              width: Style.space(170)
                              elide: Text.ElideRight
                            }
                          }
                          Row {
                            spacing: Style.space(8)
                            ColorField {
                              value: !root.selectedTerm ? "" : modelData === "text"
                                ? Palette.lookForeground(root.selectedTerm.look) : Palette.lookBackground(root.selectedTerm.look, root.themeBackground)
                              onApplied: function (value) { root.setLayerColor(modelData, value) }
                            }
                            TextButton {
                              label: "Choose a mood"
                              onActivated: { root.endPreview(); root.applyScope = modelData; root.tab = "moods"; root.tabChosen = true }
                            }
                            TextButton { label: "Reset"; onActivated: root.resetLayer(modelData) }
                          }
                          Row {
                            visible: modelData === "text"
                            spacing: Style.space(8)
                            Repeater {
                              model: Palette.HUES
                              delegate: Rectangle {
                                required property var modelData
                                readonly property string textColor: Palette.mix(modelData.hex,
                                  Palette.isLight(root.selectedTerm ? (Palette.lookBackground(root.selectedTerm.look, root.themeBackground) || root.themeBackground) : root.themeBackground)
                                    ? "#000000" : "#ffffff", 0.35)
                                width: root.swatchSize
                                height: width
                                radius: width / 2
                                color: textColor
                                border.width: root.selectedTerm && Palette.lookForeground(root.selectedTerm.look) === textColor ? 2 : 0
                                border.color: root.text
                                MouseArea {
                                  anchors.fill: parent
                                  hoverEnabled: true
                                  cursorShape: Qt.PointingHandCursor
                                  onEntered: root.hoverText = modelData.name + " text · keeps your background and syntax palette"
                                  onExited: root.hoverText = ""
                                  onClicked: root.setLayerColor("text", textColor)
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }

                  // ---- Moods: Aether styles from a wallpaper ----
                  Column {
                    visible: root.tab === "moods"
                    width: parent.width
                    spacing: Style.space(10)

                    Item {
                      width: parent.width
                      height: Math.max(moodCount.implicitHeight, moodTools.height)
                      Text {
                        id: moodCount
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.catalog.aether
                        text: root.catalog.modes.length + " Aether styles · moods, pastel, muted, colour harmonies"
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Row {
                        id: moodTools
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(14)
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: root.hiddenCount > 0
                          text: (root.showHidden ? "Hide hidden (" : "Show hidden (") + root.hiddenCount + ")"
                          color: moodHiddenArea.containsMouse ? root.text : root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          MouseArea { id: moodHiddenArea; anchors.fill: parent; anchors.margins: -Style.space(4); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.showHidden = !root.showHidden }
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: root.applyScope !== "text" && root.selectedTakesWallpaper
                          text: (root.withWallpaper ? "󰄲" : "󰄱") + " Bring its wallpaper"
                          color: moodWithArea.containsMouse ? root.text : root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          MouseArea { id: moodWithArea; anchors.fill: parent; anchors.margins: -Style.space(4); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.withWallpaper = !root.withWallpaper; root.saveConfig() } }
                        }
                        Segmented {
                          visible: root.catalog.aether
                          anchors.verticalCenter: parent.verticalCenter
                          options: [{ id: "auto", label: "Auto" }, { id: "dark", label: "Dark" }, { id: "light", label: "Light" }]
                          current: root.moodTone
                          onPicked: function (id) { root.setMoodTone(id) }
                        }
                      }
                    }

                    Text {
                      visible: root.aetherBlocker !== ""
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: root.aetherBlocker
                      color: root.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    SectionLabel { visible: root.catalog.aether; text: "Made from · W for the next wallpaper, X hides it" }

                    // Wallpapers to draw moods from; the current one comes first.
                    Flickable {
                      visible: root.catalog.aether
                      width: parent.width
                      height: Style.space(60)
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
                            width: Style.space(104)
                            height: Style.space(60)
                            radius: Style.cornerRadius
                            color: root.themeBackground
                            border.width: Math.max(1, Style.space(chosen ? 2 : 1))
                            border.color: chosen ? root.accent : sourceArea.containsMouse ? root.text : root.subtle
                            clip: true
                            opacity: root.hiddenSources.indexOf(modelData) >= 0 ? 0.35 : 1

                            Image {
                              anchors.fill: parent
                              anchors.margins: parent.border.width
                              source: Palette.fileUrl(sourceTile.modelData)
                              sourceSize.width: Style.space(208)
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

                    Flow {
                      visible: root.moods.length > 0
                      width: parent.width
                      spacing: Style.space(8)
                      Repeater {
                        model: root.opened && root.tab === "moods" ? root.moods : []
                        delegate: LookChip {
                          required property var modelData
                          look: modelData
                          label: Palette.pretty(modelData.id)
                          chosen: root.selectedTerm !== null && Palette.sameLook(modelData, root.scopeLook(root.selectedTerm.look))
                          ring: root.accent
                          fontFamily: root.fontFamily
                          onHoverStarted: { root.hoverText = root.describe(modelData); root.preview(root.current, modelData) }
                          onHoverEnded: { root.hoverText = ""; previewEnd.restart() }
                          onPicked: root.applyLookTargets(modelData)
                        }
                      }
                    }
                  }

                  // ---- Themes: every installed Omarchy theme ----
                  Column {
                    visible: root.tab === "themes"
                    width: parent.width
                    spacing: Style.space(10)
                    Item {
                      width: parent.width
                      height: Math.max(themeCount.implicitHeight, themeWith.implicitHeight)
                      Text {
                        id: themeCount
                        anchors.left: parent.left
                        text: root.catalog.themes.length + " Omarchy themes, Aether's included"
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        id: themeWith
                        anchors.right: parent.right
                        visible: root.applyScope !== "text" && root.selectedTakesWallpaper
                        text: (root.withWallpaper ? "󰄲" : "󰄱") + " Bring its wallpaper"
                        color: themeWithArea.containsMouse ? root.text : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        MouseArea { id: themeWithArea; anchors.fill: parent; anchors.margins: -Style.space(4); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.withWallpaper = !root.withWallpaper; root.saveConfig() } }
                      }
                    }
                    Flow {
                      width: parent.width
                      spacing: Style.space(8)
                      Repeater {
                        model: root.opened && root.tab === "themes" ? root.catalog.themes : []
                        delegate: LookChip {
                          required property var modelData
                          look: modelData
                          label: Palette.pretty(modelData.id)
                          image: modelData.image || ""
                          chosen: root.selectedTerm !== null && Palette.sameLook(modelData, root.scopeLook(root.selectedTerm.look))
                          ring: root.accent
                          fontFamily: root.fontFamily
                          onHoverStarted: { root.hoverText = root.describe(modelData); root.preview(root.current, modelData) }
                          onHoverEnded: { root.hoverText = ""; previewEnd.restart() }
                          onPicked: root.applyLookTargets(modelData)
                        }
                      }
                    }
                  }

                  // ---- Wallpaper: Ghostty only, one config file per window ----
                  Column {
                    visible: root.tab === "wallpapers"
                    width: parent.width
                    spacing: Style.space(12)

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
                      width: parent.width
                      spacing: Style.space(12)

                      Group {
                        width: root.catalog.launcher ? (parent.width - Style.space(12)) / 2 : parent.width
                        opacity: root.targetTakesWallpaper ? 1 : 0.45
                        SectionLabel { text: "Image" }
                        Row {
                          spacing: Style.space(10)
                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(64)
                            text: "Strength"
                            color: root.text
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                          }
                          Segmented {
                            options: Palette.STRENGTHS.map(function (s) { return { id: String(s.value), label: s.name } })
                            current: String(root.selectedTerm && root.selectedTerm.wallpaper ? root.selectedTerm.wallpaper.strength : root.strength)
                            onPicked: function (id) { root.setStrength(Number(id)) }
                          }
                        }
                        Row {
                          spacing: Style.space(10)
                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(64)
                            text: "Blur"
                            color: root.text
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                          }
                          PanelSlider {
                            id: blurSlider
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(180)
                            minimum: 0
                            maximum: 40
                            step: 1
                            integer: true
                            enabled: root.targetTakesWallpaper
                            value: root.currentBlur
                            fillColor: root.accent
                            knobColor: root.accent
                            onReleased: function (value) { root.setBlur(value) }
                            Accessible.name: "Wallpaper blur"
                          }
                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(28)
                            text: Math.round(blurSlider.liveValue) === 0 ? "Off" : String(Math.round(blurSlider.liveValue))
                            color: root.text
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                          }
                          TextButton { anchors.verticalCenter: parent.verticalCenter; label: "Reset"; enabled: root.targetTakesWallpaper; onActivated: root.setBlur(0) }
                        }
                      }

                      // Glass: frosted glass behind coloured blocks, in a colour of your choosing.
                      Group {
                        visible: root.catalog.launcher
                        width: (parent.width - Style.space(12)) / 2
                        Item {
                          width: parent.width
                          height: glassSwitch.height
                          SectionLabel { anchors.verticalCenter: parent.verticalCenter; text: "Glass · G" }
                          Segmented {
                            id: glassSwitch
                            anchors.right: parent.right
                            options: [{ id: "on", label: "On" }, { id: "off", label: "Off" }]
                            current: root.selectedGlass.on ? "on" : "off"
                            onPicked: function (id) { root.setGlass(id === "on") }
                          }
                        }
                        Text {
                          width: parent.width
                          wrapMode: Text.WordWrap
                          text: "Applies to the selected terminal’s window. Lower Tint reveals more wallpaper; wallpaper strength also controls visibility."
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                        Flow {
                          visible: root.glass
                          width: parent.width
                          spacing: Style.space(8)
                          TextButton {
                            label: "Auto"
                            chosen: root.selectedGlass.color === "auto"
                            onActivated: root.setGlassColor("auto")
                            HoverHandler { onHoveredChanged: root.hoverText = hovered ? "Auto: each terminal’s glass takes its own look’s colour" : "" }
                          }
                          Repeater {
                            model: Palette.glassSwatches()
                            delegate: Rectangle {
                              required property var modelData
                              width: root.swatchSize + Style.space(6)
                              height: width
                              radius: width / 2
                              color: modelData.hex
                              border.width: root.selectedGlass.color === modelData.hex ? Math.max(2, Style.space(2)) : Math.max(1, Style.space(1))
                              border.color: root.selectedGlass.color === modelData.hex ? root.text : root.subtle
                              MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.hoverText = modelData.name + " glass"
                                onExited: root.hoverText = ""
                                onClicked: root.setGlassColor(modelData.hex)
                              }
                            }
                          }
                          ColorField {
                            value: root.selectedGlass.color === "auto" ? "" : root.selectedGlass.color
                            onApplied: function (value) { root.setGlassColor(value) }
                          }
                        }
                        Row {
                          visible: root.glass
                          spacing: Style.space(10)
                          Text { anchors.verticalCenter: parent.verticalCenter; width: Style.space(36); text: "Tint"; color: root.text; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                          PanelSlider {
                            id: glassTintSlider
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(140)
                            minimum: 0
                            maximum: 100
                            step: 1
                            integer: true
                            value: root.selectedGlass.tint
                            fillColor: root.accent
                            knobColor: root.accent
                            onReleased: function (value) { root.setGlassTint(value) }
                            Accessible.name: "Glass tint"
                          }
                          Text { anchors.verticalCenter: parent.verticalCenter; width: Style.space(36); text: Math.round(glassTintSlider.liveValue) + "%"; color: root.text; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                        }
                        Row {
                          visible: root.glass
                          spacing: Style.space(10)
                          Text { anchors.verticalCenter: parent.verticalCenter; width: Style.space(36); text: "Blur"; color: root.text; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                          PanelSlider {
                            id: glassBlurSlider
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(140)
                            minimum: 0
                            maximum: 60
                            step: 1
                            integer: true
                            value: root.selectedGlass.blur
                            fillColor: root.accent
                            knobColor: root.accent
                            onReleased: function (value) { root.setGlassBlur(value) }
                            Accessible.name: "Glass blur"
                          }
                          Text { anchors.verticalCenter: parent.verticalCenter; width: Style.space(36); text: Math.round(glassBlurSlider.liveValue) === 0 ? "Off" : String(Math.round(glassBlurSlider.liveValue)); color: root.text; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                          TextButton { anchors.verticalCenter: parent.verticalCenter; label: "Reset"; onActivated: root.resetGlass() }
                        }
                      }
                    }

                    Text {
                      visible: root.wallpaperMessage !== ""
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: root.wallpaperMessage
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Item {
                      visible: !root.browsing
                      width: parent.width
                      height: Math.max(noneTile.height, addColumn.implicitHeight)
                      WallTile { id: noneTile; path: ""; opacity: root.targetTakesWallpaper ? 1 : 0.4 }
                      Column {
                        id: addColumn
                        anchors.left: noneTile.right
                        anchors.leftMargin: Style.space(14)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)
                        TextButton { label: "+  Add images or a folder…   A"; onActivated: root.openBrowser() }
                        Text {
                          text: "From anywhere on this computer. Click a section’s name to fold it; right-click an image to hide it."
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    // Folder browser: any folder on this computer. Only PNG and JPEG
                    // files are listed, the formats Ghostty can show; nothing is changed.
                    Column {
                      visible: root.browsing
                      width: parent.width
                      spacing: Style.space(8)

                      Row {
                        width: parent.width
                        spacing: Style.space(8)
                        TextButton { id: browseUpButton; label: "Up"; enabled: root.browseFolder !== "/"; onActivated: root.browseUp() }
                        TextField {
                          id: browsePath
                          objectName: "ombreBrowsePath"
                          width: parent.width - browseUpButton.width - Style.space(8)
                          placeholderText: "Type or paste a folder or image path, then press Enter"
                          onAccepted: { root.browseTo(text); keyCatcher.forceActiveFocus() }
                          Keys.onEscapePressed: { text = Palette.tildePath(root.browseFolder, root.home); keyCatcher.forceActiveFocus() }
                          Accessible.name: "Folder or image path"
                        }
                      }

                      Flow {
                        width: parent.width
                        spacing: Style.space(6)
                        Repeater {
                          model: root.browsing ? root.browsePlaces : []
                          delegate: TextButton {
                            required property var modelData
                            label: modelData.name
                            chosen: root.browseFolder === modelData.path
                            onActivated: root.browseTo(modelData.path)
                          }
                        }
                      }

                      Rectangle {
                        width: parent.width
                        height: Style.space(300)
                        radius: Style.cornerRadius
                        color: root.themeBackground
                        border.width: Math.max(1, Style.space(1))
                        border.color: root.subtle
                        clip: true

                        ListView {
                          id: browseList
                          anchors.fill: parent
                          anchors.margins: Style.space(4)
                          clip: true
                          boundsBehavior: Flickable.StopAtBounds
                          // No rows (and no thumbnails read) until the browser opens.
                          model: root.browsing ? folderModel : null
                          FolderListModel {
                            id: folderModel
                            folder: Palette.fileUrl(root.browseFolder || root.home || "/")
                            nameFilters: ["*.png", "*.jpg", "*.jpeg"]
                            caseSensitive: false
                            showDirsFirst: true
                            showDotAndDotDot: false
                            showHidden: false
                            showOnlyReadable: true
                            sortCaseSensitive: false
                            onFolderChanged: browseList.currentIndex = 0
                          }

                          delegate: Rectangle {
                            id: browseRow
                            required property int index
                            required property string fileName
                            required property string filePath
                            required property bool fileIsDir
                            width: ListView.view.width
                            height: Style.space(44)
                            radius: Style.cornerRadius
                            color: ListView.isCurrentItem || rowArea.containsMouse ? Commons.Color.menu.selectedBackground : "transparent"

                            MouseArea {
                              id: rowArea
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              onEntered: {
                                browseList.currentIndex = browseRow.index
                                root.hoverText = browseRow.fileIsDir ? "" : browseRow.fileName
                                if (!browseRow.fileIsDir && root.selectedTakesWallpaper)
                                  root.previewWallpaper(root.current, { path: browseRow.filePath, strength: root.strength, blur: root.currentBlur })
                              }
                              onExited: { root.hoverText = ""; previewEnd.restart() }
                              onClicked: root.openBrowsed(browseRow.index)
                            }

                            Item {
                              id: browseThumb
                              anchors.left: parent.left
                              anchors.leftMargin: Style.space(6)
                              anchors.verticalCenter: parent.verticalCenter
                              width: Style.space(64)
                              height: Style.space(36)

                              // A plain drawn folder, so no icon font is needed.
                              Item {
                                visible: browseRow.fileIsDir
                                anchors.centerIn: parent
                                width: Style.space(30)
                                height: Style.space(22)
                                Rectangle { x: 0; y: 0; width: parent.width * 0.45; height: parent.height * 0.3; radius: Style.space(2); color: root.muted }
                                Rectangle { x: 0; y: parent.height * 0.18; width: parent.width; height: parent.height * 0.82; radius: Style.space(3); color: root.muted }
                              }

                              Image {
                                visible: !browseRow.fileIsDir
                                anchors.fill: parent
                                source: browseRow.fileIsDir ? "" : Palette.fileUrl(browseRow.filePath)
                                sourceSize.height: Style.space(72)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                              }
                            }

                            Text {
                              anchors.left: browseThumb.right
                              anchors.leftMargin: Style.space(10)
                              anchors.right: rowAdd.visible ? rowAdd.left : parent.right
                              anchors.rightMargin: Style.space(8)
                              anchors.verticalCenter: parent.verticalCenter
                              text: browseRow.fileName
                              elide: Text.ElideMiddle
                              color: root.text
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                            }

                            TextButton {
                              id: rowAdd
                              visible: browseRow.fileIsDir
                              anchors.right: parent.right
                              anchors.rightMargin: Style.space(6)
                              anchors.verticalCenter: parent.verticalCenter
                              label: "Add folder"
                              onActivated: { root.addImageSource(browseRow.filePath); root.closeBrowser() }
                            }
                          }
                        }

                        Text {
                          anchors.centerIn: parent
                          visible: folderModel.status === FolderListModel.Ready && folderModel.count === 0
                          text: "No folders or PNG/JPEG images here."
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      Row {
                        spacing: Style.space(8)
                        TextButton {
                          label: "Add this folder"
                          enabled: root.browseFolder !== ""
                          onActivated: { root.addImageSource(root.browseFolder); root.closeBrowser() }
                        }
                        TextButton { label: "Close"; onActivated: root.closeBrowser() }
                      }

                      Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Click an image to use it, or add a whole folder. Only PNG and JPEG files are listed: those are the formats Ghostty can show. Nothing is copied or changed. "
                          + "Keys: ↑ ↓ move, Enter opens, Backspace goes up, A adds this folder, / types a path, Esc closes."
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Column {
                      id: wallSections
                      visible: !root.browsing
                      width: parent.width
                      spacing: Style.space(12)

                      Repeater {
                        model: root.opened && root.tab === "wallpapers" && !root.browsing ? root.wallpaperSections : []

                        delegate: Column {
                          id: wallSection
                          required property var modelData
                          readonly property int indent: Style.space(18) * modelData.depth
                          width: wallSections.width
                          spacing: Style.space(6)

                          Item {
                            x: wallSection.indent
                            width: parent.width - x
                            height: Math.max(sectionText.implicitHeight, sectionRemove.visible ? sectionRemove.height : 0)

                            Column {
                              id: sectionText
                              anchors.left: parent.left
                              anchors.right: sectionRemove.visible ? sectionRemove.left : parent.right
                              anchors.rightMargin: Style.space(8)
                              anchors.verticalCenter: parent.verticalCenter
                              spacing: Style.space(2)

                              Row {
                                spacing: Style.space(8)
                                Text {
                                  visible: !wallSection.modelData.empty
                                  text: wallSection.modelData.collapsed ? "▸" : "▾"
                                  color: sectionArea.containsMouse ? root.text : root.muted
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.body
                                }
                                Text {
                                  id: sectionTitle
                                  text: wallSection.modelData.title
                                  color: root.text
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.body
                                  font.bold: wallSection.modelData.depth === 0
                                }
                                Text {
                                  anchors.baseline: sectionTitle.baseline
                                  visible: !wallSection.modelData.empty
                                  text: wallSection.modelData.count + (wallSection.modelData.count === 1 ? " image" : " images")
                                  color: root.muted
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.caption
                                }
                              }

                              Text {
                                visible: text !== ""
                                width: parent.width
                                elide: Text.ElideMiddle
                                text: [wallSection.modelData.detail, wallSection.modelData.note].filter(function (t) { return t }).join(" · ")
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                              }
                            }

                            MouseArea {
                              id: sectionArea
                              anchors.fill: sectionText
                              hoverEnabled: true
                              enabled: !wallSection.modelData.empty
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.toggleSection(wallSection.modelData.key)
                            }

                            TextButton {
                              id: sectionRemove
                              visible: wallSection.modelData.source !== ""
                              anchors.right: parent.right
                              anchors.verticalCenter: parent.verticalCenter
                              label: "Remove"
                              onActivated: root.removeImageSource(wallSection.modelData.source)
                            }
                          }

                          Flow {
                            visible: wallSection.modelData.images.length > 0
                            x: wallSection.indent
                            width: parent.width - x
                            spacing: Style.space(8)
                            opacity: root.targetTakesWallpaper ? 1 : 0.4

                            Repeater {
                              model: wallSection.modelData.images
                              delegate: WallTile {
                                required property var modelData
                                path: modelData
                                removable: wallSection.modelData.removableImages
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ======== Settings ========
          Item {
            id: settingsView
            anchors.fill: parent
            visible: root.view === "settings"

            Column {
              id: settingsNav
              anchors.left: parent.left
              anchors.top: parent.top
              width: body.sideWidth
              spacing: Style.space(4)
              Repeater {
                model: root.settingsSections
                delegate: Rectangle {
                  id: navItem
                  required property var modelData
                  readonly property bool on: root.settingsSection === modelData.id
                  width: settingsNav.width
                  height: Style.space(42)
                  radius: Style.cornerRadius
                  color: on ? Commons.Color.menu.selectedBackground : navArea.containsMouse ? Util.alpha(root.text, 0.05) : "transparent"
                  border.width: Math.max(1, Style.space(on ? 2 : 1))
                  border.color: on ? root.accent : "transparent"
                  Accessible.role: Accessible.PageTab
                  Accessible.name: modelData.name
                  Accessible.onPressAction: root.settingsSection = navItem.modelData.id
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(14)
                    anchors.verticalCenter: parent.verticalCenter
                    text: navItem.modelData.name
                    color: navItem.on || navArea.containsMouse ? root.text : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: navItem.on
                  }
                  MouseArea {
                    id: navArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.settingsSection = navItem.modelData.id; keyCatcher.forceActiveFocus() }
                  }
                }
              }
            }

            Rectangle {
              id: settingsRule
              anchors.left: settingsNav.right
              anchors.leftMargin: Style.space(16)
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.max(1, Style.space(1))
              color: root.subtle
            }

            Flickable {
              id: settingsPane
              anchors.left: settingsRule.right
              anchors.leftMargin: Style.space(20)
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              contentWidth: width
              contentHeight: settingsContent.implicitHeight
              clip: true
              interactive: contentHeight > height
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: settingsContent
                width: Math.min(settingsPane.width, Style.space(760))
                spacing: Style.space(14)

                // Window effects: switches that apply to every terminal.
                Column {
                  visible: root.settingsSection === "windows"
                  width: parent.width
                  spacing: Style.space(12)
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "These apply to every terminal. Each has a key you can press anywhere in Ombre."
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Rectangle {
                    width: parent.width
                    height: effectRows.implicitHeight
                    radius: Style.cornerRadius
                    color: Util.alpha(root.text, 0.02)
                    border.width: Math.max(1, Style.space(1))
                    border.color: root.subtle
                    clip: true
                    Column {
                      id: effectRows
                      width: parent.width
                      SettingRow {
                        name: "Matching borders"
                        detail: "The window border takes the look’s colour: bright when focused, dim otherwise."
                        key: "B"
                        checked: root.borders
                        onToggled: root.setBorders(!root.borders)
                      }
                      SettingRow {
                        name: "Pulse when an agent is done"
                        detail: "The border breathes in its colour until you click into the window. Works with agents that show a spinner in the title and with the terminal bell."
                        key: "P"
                        checked: root.pulse
                        onToggled: root.setPulse(!root.pulse)
                      }
                      SettingRow {
                        visible: root.catalog.ghostty
                        name: "Solid Ghostty windows"
                        detail: "Turn off Omarchy’s window transparency so the desktop doesn’t show through a terminal’s wallpaper."
                        key: "O"
                        checked: root.solid
                        onToggled: root.setSolid(!root.solid)
                      }
                      SettingRow {
                        visible: root.catalog.launcher
                        name: "Text shadow (Ghostty)"
                        detail: "A soft shadow under the text so it reads over any wallpaper."
                        key: "T"
                        checked: root.textShadow
                        onToggled: root.setTextShadow(!root.textShadow)
                      }
                      SettingRow {
                        visible: root.catalog.launcher
                        name: "Glass (Ghostty)"
                        detail: "Coloured blocks become frosted glass over the wallpaper. Its colour, tint and blur are in the Wallpaper tab."
                        key: "G"
                        checked: root.glass
                        onToggled: root.setGlass(!root.selectedGlass.on)
                      }
                    }
                  }
                  Column {
                    visible: root.catalog.ghostty && !root.catalog.launcher
                    width: parent.width
                    spacing: Style.space(8)
                    Text {
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: "Wallpapers, text shadow and glass need Ghostty windows opened through Ombre. It takes one click."
                      color: root.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    TextButton { label: setupProc.running ? "Setting up…" : "Set up Ghostty for wallpapers"; onActivated: root.runSetup() }
                  }
                }

                // Claude Code and Codex follow each terminal's colours.
                Column {
                  visible: root.settingsSection === "agents"
                  width: parent.width
                  spacing: Style.space(12)
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Let Claude Code and Codex draw their interface in each terminal’s own colours. Link once, then pick “Ombre” in each app’s /theme menu."
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Group {
                    width: parent.width
                    Item {
                      width: parent.width
                      height: Math.max(agentText.implicitHeight, agentButtons.height)
                      Column {
                        id: agentText
                        anchors.left: parent.left
                        anchors.right: agentButtons.left
                        anchors.rightMargin: Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)
                        Text {
                          text: "Claude Code + Codex app themes"
                          color: root.text
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                        }
                        Text {
                          width: parent.width
                          wrapMode: Text.WordWrap
                          text: root.agentThemeMessage || (root.agentThemeStatus.linked ? "Linked. Each terminal follows its own palette." : "Not linked yet.")
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }
                      Row {
                        id: agentButtons
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)
                        TextButton {
                          label: agentThemeProc.running ? "Checking…" : root.agentThemeStatus.linked ? "Linked to Ombre" : "Link app themes"
                          chosen: root.agentThemeStatus.linked
                          onActivated: root.setAgentThemes(true)
                        }
                        TextButton {
                          visible: root.agentThemeStatus.canUnlink
                          label: "Unlink"
                          onActivated: root.setAgentThemes(false)
                        }
                      }
                    }
                  }
                }

                // What newly opened terminals get.
                Column {
                  visible: root.settingsSection === "new"
                  width: parent.width
                  spacing: Style.space(12)
                  Text {
                    text: "When a new terminal opens, give it:"
                    color: root.text
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Segmented {
                    options: [{ id: "none", label: "Its own colours" }, { id: "auto", label: "A different tint each" }, { id: "look", label: "A saved look" }]
                    current: root.newDefault.mode
                    onPicked: function (id) { root.setDefaultMode(id) }
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.newDefault.mode === "auto"
                      ? "Each new terminal gets the tint the fewest open terminals have, so new agents never look alike."
                      : root.newDefault.mode === "look"
                        ? "New terminals open as " + root.defaultLabel + "."
                        : "New terminals keep their usual colours."
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Row {
                    spacing: Style.space(10)
                    TextButton {
                      label: root.selectedTerm ? "Use the look of “" + root.selectedTerm.title.slice(0, 40) + "”" : "Use the selected terminal’s look"
                      opacity: root.selectedTerm && (root.selectedTerm.look || root.selectedTerm.wallpaper) ? 1 : 0.4
                      onActivated: if (root.selectedTerm) root.saveDefaultFrom(root.selectedTerm)
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "or press D while styling"
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                // Project rules: a folder's terminals get its look.
                Column {
                  visible: root.settingsSection === "projects"
                  width: parent.width
                  spacing: Style.space(12)
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "A terminal working inside one of these folders gets that folder’s look automatically. "
                      + (root.selectedTerm && (root.selectedTerm.root || root.selectedTerm.cwd)
                        ? "The selected terminal is in " + Palette.tildePath(root.selectedTerm.root || root.selectedTerm.cwd, root.home) + "." : "")
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: root.projects.length === 0
                    text: "No project folders yet."
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Rectangle {
                    visible: root.projects.length > 0
                    width: parent.width
                    height: ruleRows.implicitHeight
                    radius: Style.cornerRadius
                    color: Util.alpha(root.text, 0.02)
                    border.width: Math.max(1, Style.space(1))
                    border.color: root.subtle
                    clip: true
                    Column {
                      id: ruleRows
                      width: parent.width
                      Repeater {
                        model: root.opened && root.view === "settings" ? root.projects : []
                        delegate: Item {
                          id: ruleRow
                          required property var modelData
                          readonly property string accentHex: Palette.lookAccent(modelData.look) || root.accentHex
                          width: ruleRows.width
                          height: Style.space(56)
                          Rectangle {
                            id: ruleSwatch
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(14)
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(30)
                            height: Style.space(20)
                            radius: Style.space(3)
                            color: Palette.lookBackground(ruleRow.modelData.look, root.themeBackground) || root.themeBackground
                            border.width: Math.max(1, Style.space(2))
                            border.color: ruleRow.accentHex
                          }
                          Column {
                            anchors.left: ruleSwatch.right
                            anchors.leftMargin: Style.space(12)
                            anchors.right: ruleRemove.left
                            anchors.rightMargin: Style.space(12)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(2)
                            Text {
                              width: parent.width
                              elide: Text.ElideMiddle
                              text: Palette.tildePath(ruleRow.modelData.path, root.home)
                              color: root.text
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.body
                            }
                            Text {
                              width: parent.width
                              elide: Text.ElideRight
                              text: root.ruleLabel(ruleRow.modelData)
                              color: root.muted
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                            }
                          }
                          TextButton {
                            id: ruleRemove
                            anchors.right: parent.right
                            anchors.rightMargin: Style.space(14)
                            anchors.verticalCenter: parent.verticalCenter
                            label: "Remove"
                            Accessible.name: "Remove " + ruleRow.modelData.path
                            onActivated: root.removeProject(ruleRow.modelData.path)
                          }
                          Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: Math.max(1, Style.space(1))
                            color: root.subtle
                          }
                        }
                      }
                    }
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
                      text: "or press F while styling"
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                // About: version, maker and what's installed.
                Column {
                  visible: root.settingsSection === "about"
                  width: parent.width
                  spacing: Style.space(14)
                  Row {
                    spacing: Style.space(16)
                    Image {
                      anchors.verticalCenter: parent.verticalCenter
                      source: Qt.resolvedUrl("assets/brand/ombre-mark.svg")
                      width: Style.space(72)
                      height: width
                      sourceSize: Qt.size(width * 2, height * 2)
                      Accessible.ignored: true
                    }
                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(4)
                      Text {
                        text: "Ombre " + (root.pluginVersion || "")
                        color: root.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.display
                        font.bold: true
                      }
                      Text {
                        text: "Every terminal, its own look. From ekkOStech."
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }
                  }
                  Group {
                    width: parent.width
                    spacing: Style.space(8)
                    Repeater {
                      model: [
                        root.catalog.aether ? "✓ Aether " + String(root.catalog.aetherVersion).replace(/^aether /, "") + ": moods and colour palettes"
                          : root.catalog.aetherInstalled ? "✗ Aether is too old for moods: omarchy update" : "✗ Aether is not installed: omarchy pkg add aether",
                        root.catalog.ghostty ? (root.catalog.launcher ? "✓ Ghostty is set up for wallpapers, text shadow and glass" : "✗ Ghostty is installed but not set up for wallpapers yet")
                          : "✗ Ghostty is not installed: omarchy install terminal ghostty",
                        root.catalog.themes.length + " Omarchy themes · " + root.savedLooks.length + " saved looks · " + root.projects.length + " project folders"
                      ]
                      delegate: Text {
                        required property var modelData
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: modelData
                        color: root.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "github.com/ekkostech/omarchy-ombre · run ombre --check in a terminal for a full report."
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
