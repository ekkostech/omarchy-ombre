.pragma library

// A look is what a terminal wears:
//   { kind: "tint",  id: "blue" | "#rrggbb" }
//   { kind: "mood",  id: "fire", source: "/path/to/wallpaper.jpg", palette }
//   { kind: "theme", id: "tokyo-night", palette }
// palette = { background, foreground, cursor, accent, colors: [16 x "#rrggbb"] }
// null means the terminal's own configured colors.
//
// Tints only change the background: the theme background with a little of the
// hue mixed in, so text stays readable on light and dark themes. Moods (from
// Aether) and themes replace the whole palette. The window border takes the
// look's accent.
var HUES = [
  { id: "red",    name: "Red",    hex: "#e5484d" },
  { id: "orange", name: "Orange", hex: "#f76b15" },
  { id: "amber",  name: "Amber",  hex: "#ffc53d" },
  { id: "green",  name: "Green",  hex: "#46a758" },
  { id: "teal",   name: "Teal",   hex: "#12a594" },
  { id: "blue",   name: "Blue",   hex: "#3e63dd" },
  { id: "purple", name: "Purple", hex: "#8e4ec6" },
  { id: "pink",   name: "Pink",   hex: "#d6409f" }
];

var DARK_STRENGTH = 0.18;
var LIGHT_STRENGTH = 0.14;

function isHex(value) {
  return /^#[0-9a-fA-F]{6}$/.test(String(value || ""));
}

function isName(value) {
  return /^[A-Za-z0-9._-]+$/.test(String(value || ""));
}

function hue(id) {
  for (var i = 0; i < HUES.length; i++) if (HUES[i].id === id) return HUES[i];
  return null;
}

function hueIndex(id) {
  for (var i = 0; i < HUES.length; i++) if (HUES[i].id === id) return i;
  return -1;
}

// ---- Color math -----------------------------------------------------------

// QML colors stringify as #rrggbb, or #aarrggbb when translucent.
function rgb(color) {
  var s = String(color || "#000000").replace(/^#/, "");
  if (s.length === 8) s = s.slice(2);
  if (!/^[0-9a-fA-F]{6}$/.test(s)) s = "000000";
  return [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)];
}

function hex(c) {
  var out = "#";
  for (var i = 0; i < 3; i++) {
    var v = Math.max(0, Math.min(255, Math.round(c[i])));
    out += (v < 16 ? "0" : "") + v.toString(16);
  }
  return out;
}

function isLight(color) {
  var c = rgb(color);
  return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255 > 0.5;
}

function mix(base, over, amount) {
  var a = rgb(base), b = rgb(over);
  return hex([a[0] + (b[0] - a[0]) * amount,
              a[1] + (b[1] - a[1]) * amount,
              a[2] + (b[2] - a[2]) * amount]);
}

function chroma(color) {
  var c = rgb(color);
  return Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2]);
}

function mostChromatic(list) {
  var best = list[0];
  for (var i = 1; i < list.length; i++) if (chroma(list[i]) > chroma(best)) best = list[i];
  return best;
}

// ---- Palettes ---------------------------------------------------------------

function validPalette(p) {
  if (!p || !isHex(p.background) || !isHex(p.foreground) || !isHex(p.cursor) || !isHex(p.accent)) return false;
  if (!Array.isArray(p.colors) || p.colors.length !== 16) return false;
  for (var i = 0; i < 16; i++) if (!isHex(p.colors[i])) return false;
  return true;
}

function copyPalette(p) {
  return {
    background: p.background.toLowerCase(),
    foreground: p.foreground.toLowerCase(),
    cursor: p.cursor.toLowerCase(),
    accent: p.accent.toLowerCase(),
    colors: p.colors.map(function (c) { return c.toLowerCase(); })
  };
}

// Aether palettes are the 16 ANSI colors: 0 is the background, 7 the text.
function aetherPalette(colors) {
  if (!Array.isArray(colors) || colors.length < 16) return null;
  var c = colors.slice(0, 16).map(function (x) { return String(x).toLowerCase(); });
  for (var i = 0; i < 16; i++) if (!isHex(c[i])) return null;
  return { background: c[0], foreground: c[7], cursor: c[15], accent: mostChromatic(c.slice(1, 7)), colors: c };
}

function parseToml(text) {
  var out = {};
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

// Omarchy colors.toml, mapped onto the 16 colors the way Omarchy's own foot
// template does. Older themes that list color0..color15 use those directly.
function themePalette(t) {
  if (!isHex(t.background) || !isHex(t.foreground)) return null;
  function pick(key, fallback) { return isHex(t[key]) ? t[key].toLowerCase() : fallback; }
  var bg = t.background.toLowerCase(), fg = t.foreground.toLowerCase();
  var red = pick("red", fg), green = pick("green", fg), yellow = pick("yellow", fg);
  var blue = pick("blue", fg), magenta = pick("purple", pick("magenta", fg)), cyan = pick("cyan", fg);
  var colors = [bg, red, green, yellow, blue, magenta, cyan, fg,
    pick("muted", mix(bg, fg, 0.4)), pick("bright_red", red), pick("bright_green", green),
    pick("bright_yellow", yellow), pick("bright_blue", blue), pick("bright_magenta", magenta),
    pick("bright_cyan", cyan), pick("bright_foreground", fg)];
  for (var i = 0; i < 16; i++) colors[i] = pick("color" + i, colors[i]);
  return { background: bg, foreground: fg, cursor: colors[15], accent: pick("accent", blue), colors: colors };
}

// ---- Looks ------------------------------------------------------------------

function tintLook(id) {
  if (hue(id)) return { kind: "tint", id: id };
  if (isHex(id)) return { kind: "tint", id: String(id).toLowerCase() };
  return null;
}

// Only the fields worth saving, validated; anything else is no look.
function normalizeLook(look) {
  if (!look || typeof look !== "object") return null;
  if (look.kind === "tint") return tintLook(look.id);
  if ((look.kind === "mood" || look.kind === "theme") && isName(look.id) && validPalette(look.palette)) {
    var out = { kind: look.kind, id: look.id, palette: copyPalette(look.palette) };
    if (look.kind === "mood") out.source = String(look.source || "");
    return out;
  }
  return null;
}

function sameLook(a, b) {
  if (!a || !b) return !a && !b;
  return a.kind === b.kind && a.id === b.id && (a.kind !== "mood" || a.source === b.source);
}

function lookBackground(look, themeBackground) {
  if (!look) return "";
  if (look.kind === "tint") {
    if (isHex(look.id)) return look.id;
    var h = hue(look.id);
    return h ? mix(themeBackground, h.hex, isLight(themeBackground) ? LIGHT_STRENGTH : DARK_STRENGTH) : "";
  }
  return look.palette.background;
}

// Unfocused windows get a much darker version of their color, so the focused
// one still stands out the way Omarchy's own borders do.
function inactiveAccent(accent, themeBackground) {
  return accent ? mix(themeBackground, accent, 0.4) : "";
}

function lookAccent(look) {
  if (!look) return "";
  if (look.kind === "tint") return isHex(look.id) ? look.id : hue(look.id).hex;
  return look.palette.accent;
}

function pretty(id) {
  return String(id || "").split(/[-_]/).map(function (w) {
    return w ? w.charAt(0).toUpperCase() + w.slice(1) : w;
  }).join(" ");
}

function basename(path) {
  var s = String(path || "");
  return s.slice(s.lastIndexOf("/") + 1).replace(/\.[^.]+$/, "");
}

function lookLabel(look) {
  if (!look) return "";
  if (look.kind === "tint") return hue(look.id) ? hue(look.id).name : look.id;
  if (look.kind === "mood") return pretty(look.id) + " · " + basename(look.source);
  return pretty(look.id);
}

// ---- Wallpapers (Ghostty only) ----------------------------------------------

// { path, strength }: an image file and how strongly it shows through the
// background color (Ghostty's background-image-opacity). Ghostty shows images
// far brighter than the number suggests: a light wallpaper at 0.4 drowns the
// text. Hence a low scale with names instead of percentages.
var STRENGTHS = [
  { value: 0.04, name: "Faint" },
  { value: 0.08, name: "Soft" },
  { value: 0.15, name: "Medium" },
  { value: 0.3,  name: "Strong" }
];
var DEFAULT_STRENGTH = 0.08;

function isImagePath(path) {
  var p = String(path || "");
  return /^\//.test(p) && !/[\n"]/.test(p) && /\.(png|jpe?g)$/i.test(p);
}

function normalizeWallpaper(w) {
  if (!w || typeof w !== "object" || !isImagePath(w.path)) return null;
  var strength = Number(w.strength);
  if (!isFinite(strength)) strength = DEFAULT_STRENGTH;
  return { path: String(w.path), strength: Math.round(Math.max(0.01, Math.min(1, strength)) * 100) / 100 };
}

function sameWallpaper(a, b) {
  if (!a || !b) return !a && !b;
  return a.path === b.path && a.strength === b.strength;
}

// The escape sequence that makes a terminal wear a look. OSC 4/10/11/12 set the
// palette, text, background and cursor; 104/110/111/112 put them back.
var ESC = "\u001b";
function osc(body) { return ESC + "]" + body + ESC + "\\"; }

function sequence(look, themeBackground) {
  var reset = osc("104") + osc("110") + osc("112");
  if (!look) return reset + osc("111");
  if (look.kind === "tint") return reset + osc("11;" + lookBackground(look, themeBackground));
  var p = look.palette, out = "";
  for (var i = 0; i < 16; i++) out += osc("4;" + i + ";" + p.colors[i]);
  return out + osc("10;" + p.foreground) + osc("11;" + p.background) + osc("12;" + p.cursor);
}

// ---- Needs-you pulse ----------------------------------------------------------

// Agents such as Claude Code put a spinner (◐ ◓ ◑ ◒) at the front of the
// window title while they work and ✳ once they're waiting. Ghostty puts 🔔 in
// front after a bell.
function agentState(title) {
  var t = String(title || "").replace(/^\uD83D\uDD14\s*/, "");
  var c = t.charAt(0);
  if ("\u25D0\u25D1\u25D2\u25D3".indexOf(c) >= 0) return "working";
  if (c === "\u2733") return "idle";
  return "other";
}

// The border color at a moment of the pulse: a slow breath between a dim and a
// bright version of the accent, about 1.6 seconds per cycle.
var PULSE_PERIOD_MS = 1600;
function pulseColor(accent, themeBackground, elapsedMs) {
  var t = 0.5 - 0.5 * Math.cos(2 * Math.PI * (elapsedMs % PULSE_PERIOD_MS) / PULSE_PERIOD_MS);
  var dim = mix(themeBackground, accent, 0.3);
  var bright = mix(accent, isLight(themeBackground) ? "#000000" : "#ffffff", 0.35);
  return mix(dim, bright, t);
}

// Hyprland's Lua dispatcher: set or clear a per-window property.
function borderCommand(prop, address, color, alpha) {
  var v = color ? JSON.stringify("rgba(" + color.replace(/^#/, "") + alpha + ")") : "-1";
  return "hl.dsp.window.set_prop({ prop = " + JSON.stringify(prop)
    + ", value = " + v + ", window = " + JSON.stringify("address:0x" + address) + " })";
}

// Both border colors in one Hyprland call, so they can't be applied out of
// order with another update to the same window.
function borderPair(address, active, activeAlpha, inactive, inactiveAlpha) {
  return "function() hl.dispatch(" + borderCommand("active_border_color", address, active, activeAlpha)
    + ") hl.dispatch(" + borderCommand("inactive_border_color", address, inactive, inactiveAlpha) + ") end";
}

// ---- Parsing shell output ---------------------------------------------------

// Parse `ps -e -o pid=,ppid=,tty=` into { tty: pid -> tty, kids: ppid -> [tty] }.
function processes(psText) {
  var out = { tty: {}, kids: {} };
  var lines = String(psText || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/);
    if (parts.length < 3) continue;
    out.tty[parts[0]] = parts[2];
    if (!out.kids[parts[1]]) out.kids[parts[1]] = [];
    out.kids[parts[1]].push(parts[2]);
  }
  return out;
}

// The pty that belongs to a terminal window: the controlling tty of its
// children. A GUI app started from a shell shares that shell's tty with its
// children, so a pty the window process already had is not its own. Terminals
// that host several windows in one process (foot --server, some Ghostty
// setups) have more than one, so their windows cannot be told apart.
function ptyFor(pid, procs) {
  var own = procs.tty[String(pid)];
  var kids = procs.kids[String(pid)] || [];
  var found = "";
  for (var i = 0; i < kids.length; i++) {
    var tty = kids[i];
    if (!/^pts\/[0-9]+$/.test(tty) || tty === own) continue;
    if (found && found !== tty) return "";
    found = tty;
  }
  return found;
}

// State lines are "pts-5 {"pid":"1234","look":{...},"wallpaper":{...}}": the terminal pid that
// owned the pty when the look was set, so a pty reused by a new terminal is
// ignored. Version 0.1 wrote "pts-5 1234 blue".
function parseState(text) {
  var out = {};
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    var m = line.match(/^pts-([0-9]+)\s+(.*)$/);
    if (!m) continue;
    var pid = "", look = null, wallpaper = null;
    if (m[2].charAt(0) === "{") {
      try {
        var j = JSON.parse(m[2]);
        pid = String(j.pid || "");
        look = normalizeLook(j.look);
        wallpaper = normalizeWallpaper(j.wallpaper);
      } catch (e) { continue; }
    } else {
      var parts = m[2].split(/\s+/);
      pid = parts[0];
      look = tintLook(parts[1]);
    }
    if (look || wallpaper) out["pts/" + m[1]] = { pid: pid, look: look, wallpaper: wallpaper };
  }
  return out;
}

// `pid<TAB>cmdline` lines for running Ghostty processes. A window can take a
// wallpaper when Terminal Tint's launcher started it with its own config file.
function ghosttyPids(ghosttyText, runtimeDir) {
  var out = { all: {}, ready: {} };
  var lines = String(ghosttyText || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var tab = lines[i].indexOf("\t");
    if (tab < 0) continue;
    var pid = lines[i].slice(0, tab).trim();
    var want = "--config-file=?" + runtimeDir + "/ghostty/" + pid + ".conf";
    out.all[pid] = true;
    if (lines[i].slice(tab + 1).indexOf(want) >= 0) out.ready[pid] = true;
  }
  return out;
}

// `hyprctl -j monitors` by id: name, layout position and the workspaces showing.
function monitorsById(monitorsText) {
  var out = {};
  var list;
  try { list = JSON.parse(monitorsText); } catch (e) { return out; }
  if (!Array.isArray(list)) return out;
  for (var i = 0; i < list.length; i++) {
    var m = list[i];
    out[m.id] = {
      name: String(m.name || ""), x: m.x || 0, y: m.y || 0,
      active: m.activeWorkspace ? m.activeWorkspace.id : null,
      special: m.specialWorkspace && m.specialWorkspace.id ? m.specialWorkspace.id : null
    };
  }
  return out;
}

function terminals(clientsText, psText, stateText, ghosttyText, runtimeDir, monitorsText) {
  var clients;
  try { clients = JSON.parse(clientsText); } catch (e) { return []; }
  if (!Array.isArray(clients)) return [];
  var monitors = monitorsById(monitorsText);
  var procs = processes(psText);
  var state = parseState(stateText);
  var ghostty = ghosttyPids(ghosttyText, runtimeDir);
  var out = [];
  for (var i = 0; i < clients.length; i++) {
    var c = clients[i];
    if (c.mapped === false || !c.pid || c.pid < 0) continue;
    var pty = ptyFor(c.pid, procs);
    if (!pty) continue;
    var saved = state[pty];
    var mine = saved && saved.pid === String(c.pid);
    var mon = monitors[c.monitor] || null;
    var wsId = c.workspace ? c.workspace.id : null;
    out.push({
      address: String(c.address || "").replace(/^0x/, ""),
      pid: String(c.pid),
      pty: pty,
      title: String(c.title || c["class"] || "Terminal"),
      cls: String(c["class"] || ""),
      workspace: c.workspace ? c.workspace.name || String(c.workspace.id) : "",
      focused: c.focusHistoryID === 0,
      x: c.at ? c.at[0] : 0,
      y: c.at ? c.at[1] : 0,
      w: c.size ? c.size[0] : 16,
      h: c.size ? c.size[1] : 9,
      // Where the window sits on its monitor, and whether it's on screen now.
      monitor: mon ? mon.name : "",
      lx: c.at && mon ? c.at[0] - mon.x : 0,
      ly: c.at && mon ? c.at[1] - mon.y : 0,
      visible: !!mon && c.hidden !== true && (wsId === mon.active || (mon.special !== null && wsId === mon.special)),
      ghostty: ghostty.all[String(c.pid)] === true,
      wallpaperReady: ghostty.ready[String(c.pid)] === true,
      look: mine ? saved.look : null,
      wallpaper: mine ? saved.wallpaper : null
    });
  }
  out.sort(function (a, b) {
    var wa = Number(a.workspace), wb = Number(b.workspace);
    if (isFinite(wa) && isFinite(wb) && wa !== wb) return wa - wb;
    if (a.workspace !== b.workspace) return a.workspace < b.workspace ? -1 : 1;
    return a.x !== b.x ? a.x - b.x : a.y - b.y;
  });
  return out;
}

function focusedIndex(list) {
  for (var i = 0; i < list.length; i++) if (list[i].focused) return i;
  return 0;
}

// Resolve a scripting target ("focused", "title:TEXT", "pid:N", "address:HEX",
// or "all") to matching terminals.
function match(list, target) {
  var t = String(target || "focused");
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var term = list[i];
    var hit = t === "all" ? true
      : t === "focused" ? term.focused
      : t.indexOf("title:") === 0 ? term.title.toLowerCase().indexOf(t.slice(6).toLowerCase()) >= 0
      : t.indexOf("pid:") === 0 ? term.pid === t.slice(4)
      : t.indexOf("address:") === 0 ? term.address === t.slice(8).replace(/^0x/, "")
      : false;
    if (hit) out.push(term);
  }
  return out;
}

// The catalog script prints sections:
//   @@WALLPAPER <current wallpaper>
//   @@AETHER <version>   Aether is installed (its `--version` line)
//   @@MODES        then `aether --list-modes --json`  (only with Aether 4 or newer)
//   @@WALLPAPERS   then `aether --list-wallpapers --json`
//   @@GHOSTTY      Ghostty is installed
//   @@LAUNCHER     Terminal Tint's Ghostty launcher is set up
//   @@THEME <name>\t<background image>   then that theme's colors.toml
function parseCatalog(text) {
  var out = { wallpaper: "", aether: false, aetherInstalled: false, aetherVersion: "",
              ghostty: false, launcher: false, modes: [], wallpapers: [], themes: [] };
  var section = "", buf = [], theme = null, byName = {};

  function flush() {
    var body = buf.join("\n");
    if (section === "modes") out.modes = parseModes(body);
    else if (section === "wallpapers") {
      try {
        var j = JSON.parse(body);
        out.wallpapers = (j.wallpapers || []).map(function (w) { return String(w.path || ""); })
          .filter(function (p) { return p.length > 0; });
      } catch (e) { }
    } else if (section === "theme" && theme) {
      var palette = themePalette(parseToml(body));
      if (palette) byName[theme.id] = { kind: "theme", id: theme.id, image: theme.image, palette: palette };
    }
    buf = [];
  }

  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.indexOf("@@") !== 0) { buf.push(line); continue; }
    flush();
    if (line.indexOf("@@WALLPAPER ") === 0) { out.wallpaper = line.slice(12).trim(); section = ""; }
    else if (line.indexOf("@@AETHER") === 0) {
      out.aetherInstalled = true;
      out.aetherVersion = line.slice(8).trim();
      section = "";
    }
    else if (line === "@@MODES") section = "modes";
    else if (line === "@@GHOSTTY") { out.ghostty = true; section = ""; }
    else if (line === "@@LAUNCHER") { out.launcher = true; section = ""; }
    else if (line === "@@WALLPAPERS") section = "wallpapers";
    else if (line.indexOf("@@THEME ") === 0) {
      var parts = line.slice(8).split("\t");
      theme = isName(parts[0]) ? { id: parts[0], image: parts[1] || "" } : null;
      section = "theme";
    } else section = "";
  }
  flush();

  // Moods work only when this Aether can list its modes.
  out.aether = out.modes.length > 0;
  for (var id in byName) out.themes.push(byName[id]);
  out.themes.sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
  return out;
}

// `aether --list-modes --json` ({"modes": [{name, description}]}), or the
// plain "  name   description" lines older builds print. The named moods
// (fire, ocean, ...) describe themselves as "... mood: ..." and come first.
function parseModes(text) {
  var found = [];
  var body = String(text || "").trim();
  if (body.charAt(0) === "{") {
    try {
      var j = JSON.parse(body);
      (j.modes || []).forEach(function (m) {
        if (m && /^[a-z0-9-]+$/.test(m.name)) found.push({ id: m.name, description: String(m.description || "") });
      });
    } catch (e) { }
  } else {
    body.split("\n").forEach(function (line) {
      var m = line.match(/^\s*([a-z0-9-]+)\s+(.+)$/);
      if (m && m[1] !== "extraction") found.push({ id: m[1], description: m[2].trim() });
    });
  }
  var moods = [], others = [];
  found.forEach(function (mode) { (/\bmood:/i.test(mode.description) ? moods : others).push(mode); });
  return moods.concat(others);
}

// Mood batch output: "@@MODE name" followed by `aether --extract-palette --json`.
function parseMoods(text, modes, source) {
  var byId = {};
  var blocks = String(text || "").split(/^@@MODE /m);
  for (var i = 0; i < blocks.length; i++) {
    var nl = blocks[i].indexOf("\n");
    if (nl < 0) continue;
    var id = blocks[i].slice(0, nl).trim();
    try {
      var palette = aetherPalette(JSON.parse(blocks[i].slice(nl + 1)).colors);
      if (palette) byId[id] = palette;
    } catch (e) { }
  }
  var out = [];
  for (var j = 0; j < modes.length; j++) {
    var p = byId[modes[j].id];
    if (p) out.push({ kind: "mood", id: modes[j].id, source: source, description: modes[j].description, palette: p });
  }
  return out;
}

function fileUrl(path) {
  return "file://" + String(path || "").split("/").map(encodeURIComponent).join("/");
}
