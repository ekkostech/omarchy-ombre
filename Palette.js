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
  // Repeater modelData exposes nested arrays as Qt sequence objects. They
  // support indexed access but Array.isArray returns false. Validate the
  // shape and every entry, then copy into an ordinary JS array below.
  if (!p.colors || typeof p.colors !== "object" || p.colors.length !== 16) return false;
  for (var i = 0; i < 16; i++) if (!isHex(p.colors[i])) return false;
  return true;
}

function copyPalette(p) {
  var colors = [];
  for (var i = 0; i < 16; i++) colors.push(String(p.colors[i]).toLowerCase());
  return {
    background: p.background.toLowerCase(),
    foreground: p.foreground.toLowerCase(),
    cursor: p.cursor.toLowerCase(),
    accent: p.accent.toLowerCase(),
    colors: colors
  };
}

// Aether palettes are the 16 ANSI colors: 0 is the background, 7 the text. Aether
// keeps every mood's background near black (fire #0c0000, ocean #000312...), so on a
// dark theme the moods were telling each other apart only by their ANSI colors. The
// window background and text take a share of the mood's accent, the way a tint
// takes a hue, so Fire reads warm and Ocean blue in plain text too. ANSI color 0 stays.
var MOOD_BACKGROUND = 0.2;
var MOOD_FOREGROUND = 0.15;
function aetherPalette(colors) {
  if (!Array.isArray(colors) || colors.length < 16) return null;
  var c = colors.slice(0, 16).map(function (x) { return String(x).toLowerCase(); });
  for (var i = 0; i < 16; i++) if (!isHex(c[i])) return null;
  var accent = mostChromatic(c.slice(1, 7));
  return { background: mix(c[0], accent, MOOD_BACKGROUND), foreground: mix(c[7], accent, MOOD_FOREGROUND),
    cursor: c[15], accent: accent, colors: c };
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
  if (look && look.kind === "layers") {
    // Only base looks may be nested; saved state cannot grow recursive layers.
    var text = look.text && look.text.kind !== "layers" ? normalizeLook(look.text) : null;
    if (text && text.kind === "tint") text = null;
    var background = look.background && look.background.kind !== "layers" ? normalizeLook(look.background) : null;
    var foreground = isHex(look.foreground) ? look.foreground.toLowerCase() : "";
    if (!text && !background && !foreground) return null;
    return { kind: "layers", id: "custom", text: text, background: background, foreground: foreground };
  }
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
  if (a.kind === "layers" || b.kind === "layers") return JSON.stringify(normalizeLook(a)) === JSON.stringify(normalizeLook(b));
  return a.kind === b.kind && a.id === b.id && (a.kind !== "mood" || a.source === b.source);
}

function lookBackground(look, themeBackground) {
  if (!look) return "";
  if (look.kind === "layers") return lookBackground(look.background, themeBackground);
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
  if (look.kind === "layers") return lookAccent(look.text) || lookAccent(look.background) || look.foreground;
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
  if (look.kind === "layers") return textLabel(look) + " / " + backgroundLabel(look);
  if (look.kind === "tint") return hue(look.id) ? hue(look.id).name : look.id;
  if (look.kind === "mood") return pretty(look.id) + " · " + basename(look.source);
  return pretty(look.id);
}

// Text and background are independent. Legacy looks still load unchanged.
function textLook(look) {
  if (!look) return null;
  return look.kind === "layers" ? look.text : look.kind === "tint" ? null : look;
}
function backgroundLook(look) { return look && look.kind === "layers" ? look.background : look; }
function textLabel(look) {
  var t = textLook(look);
  return look && look.foreground ? look.foreground : t ? pretty(t.id) : "Terminal default";
}
function backgroundLabel(look) {
  var b = backgroundLook(look);
  return b ? (b.kind === "tint" ? lookLabel(b) : pretty(b.id)) : "Terminal default";
}
function layerLook(current, incoming, scope) {
  incoming = normalizeLook(incoming);
  if (scope === "all") return incoming;
  return normalizeLook({ kind: "layers", text: scope === "text" ? textLook(incoming) : textLook(current),
    background: scope === "background" ? backgroundLook(incoming) : backgroundLook(current),
    foreground: scope === "text" ? "" : current && current.foreground });
}
function foregroundLook(current, color) {
  return normalizeLook({ kind: "layers", text: textLook(current), background: backgroundLook(current), foreground: color });
}
function lookForeground(look) {
  var t = textLook(look);
  return (look && look.foreground) || (t ? t.palette.foreground : "");
}
// Persist colors alongside the wallpaper in Ghostty's per-window config. A config
// reload then preserves the look without depending on a timed OSC replay.
function ghosttyColors(look, themeBackground) {
  var t = textLook(look), lines = [];
  if (t) {
    for (var i = 0; i < 16; i++) lines.push("palette=" + i + "=" + t.palette.colors[i].slice(1));
    lines.push("cursor-color=" + t.palette.cursor.slice(1));
  }
  var fg = lookForeground(look), bg = lookBackground(look, themeBackground);
  if (fg) lines.push("foreground=" + fg.slice(1));
  if (look && isHex(look.foreground)) {
    lines.push("palette=7=" + look.foreground.slice(1));
    lines.push("palette=15=" + look.foreground.slice(1));
  }
  if (bg) lines.push("background=" + bg.slice(1));
  return lines.join(";") || "-";
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
  if (!look) return osc("104") + osc("110") + osc("112") + osc("111");
  var t = textLook(look), out = "";
  if (t) {
    for (var i = 0; i < 16; i++) out += osc("4;" + i + ";" + t.palette.colors[i]);
    out += osc("12;" + t.palette.cursor);
  } else out = osc("104") + osc("112");
  if (look && isHex(look.foreground)) out += osc("4;7;" + look.foreground) + osc("4;15;" + look.foreground);
  var fg = lookForeground(look), bg = lookBackground(look, themeBackground);
  return out + (fg ? osc("10;" + fg) : osc("110")) + (bg ? osc("11;" + bg) : osc("111"));
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

// With Hyprland's own border animation on, the pulse only sets its two end
// colours and the compositor tweens between them on the GPU.
function pulseEnds(accent, themeBackground) {
  return { dim: mix(themeBackground, accent, 0.3), bright: mix(accent, isLight(themeBackground) ? "#000000" : "#ffffff", 0.35) };
}
function pulseColor(accent, themeBackground, elapsedMs) {
  var t = 0.5 - 0.5 * Math.cos(2 * Math.PI * (elapsedMs % PULSE_PERIOD_MS) / PULSE_PERIOD_MS);
  var dim = mix(themeBackground, accent, 0.3);
  var bright = mix(accent, isLight(themeBackground) ? "#000000" : "#ffffff", 0.35);
  return mix(dim, bright, t);
}

// Hyprland's Lua dispatcher: set a per-window property. Hyprland 0.56 has no way to
// unset a window's border color (-1 empties it, leaving no border at all), so "no
// color" sets the theme's own border back, read from `hyprctl getoption`.
function borderCommand(prop, address, color, alpha, fallback) {
  var v = color ? JSON.stringify("rgba(" + color.replace(/^#/, "") + alpha + ")") : fallback ? JSON.stringify(fallback) : "-1";
  return "hl.dsp.window.set_prop({ prop = " + JSON.stringify(prop)
    + ", value = " + v + ", window = " + JSON.stringify("address:0x" + address) + " })";
}

// The theme's border color as `hyprctl -j getoption general:col.active_border` reports
// it ("ff788fff 0deg", colors as aarrggbb), in the form set_prop accepts: "rgba(788fffff)".
// Only the first color: a per-window value with an angle, or with several colors, is
// rejected by Hyprland 0.56 and leaves the border empty.
function themeGradient(text) {
  var g = "";
  try { g = String(JSON.parse(String(text || "").trim()).gradient || ""); } catch (e) { var m = String(text || "").match(/gradient data:\s*([^\n]+)/); g = m ? m[1] : ""; }
  var first = g.trim().split(/\s+/)[0] || "";
  return /^[0-9a-f]{8}$/i.test(first) ? "rgba(" + first.slice(2) + first.slice(0, 2) + ")" : "";
}

// Both window opacities in one Hyprland call (Omarchy's rule dims every window a little;
// 1 and 1 make it solid). Values are clamped to Hyprland's 0..1.
function opacityPair(address, active, inactive) {
  var w = JSON.stringify("address:0x" + address);
  var v = function (x) { var n = Number(x); return isFinite(n) ? String(Math.min(1, Math.max(0, n))) : "1"; };
  return "function() hl.dispatch(hl.dsp.window.set_prop({ prop = \"opacity\", value = " + v(active) + ", window = " + w + " }))"
    + " hl.dispatch(hl.dsp.window.set_prop({ prop = \"opacity_inactive\", value = " + v(inactive) + ", window = " + w + " })) end";
}

// Both border colors in one Hyprland call, so they can't be applied out of
// order with another update to the same window.
function borderPair(address, active, activeAlpha, inactive, inactiveAlpha, theme) {
  var t = theme || {};
  return "function() hl.dispatch(" + borderCommand("active_border_color", address, active, activeAlpha, t.active)
    + ") hl.dispatch(" + borderCommand("inactive_border_color", address, inactive, inactiveAlpha, t.inactive) + ") end";
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
// wallpaper when Ombre's launcher started it with its own config file.
function ghosttyPids(ghosttyText, runtimeDir) {
  var out = { all: {}, ready: {} };   // ready: pid -> directory of its config file
  var lines = String(ghosttyText || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var tab = lines[i].indexOf("\t");
    if (tab < 0) continue;
    var pid = lines[i].slice(0, tab).trim();
    var m = lines[i].slice(tab + 1).match(/--config-file=\?(\S+\/ghostty\/)(\d+)\.conf/);
    out.all[pid] = true;
    if (m && m[2] === pid) out.ready[pid] = m[1];
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

function cwdsByPid(cwdText) {
  var out = {};
  var lines = String(cwdText || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t");
    if (parts.length >= 3 && /^\d+$/.test(parts[0])) out[parts[0]] = { cwd: parts[1], root: parts[2] };
  }
  return out;
}

// The shell (or agent) a terminal window runs: its first child on a pty.
function childOnPty(pid, psText, pty) {
  var lines = String(psText || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var p = lines[i].trim().split(/\s+/);
    if (p.length >= 3 && p[1] === String(pid) && p[2] === pty) return p[0];
  }
  return "";
}

// The rule whose folder contains cwd, preferring the deepest folder.
function projectFor(rules, cwd) {
  var best = null;
  if (!cwd || !Array.isArray(rules)) return null;
  for (var i = 0; i < rules.length; i++) {
    var r = rules[i];
    if (!r || typeof r.path !== "string") continue;
    var path = r.path.replace(/\/+$/, "");
    if (cwd === path || cwd.indexOf(path + "/") === 0) {
      if (!best || path.length > best.path.length) best = r;
    }
  }
  return best;
}

function terminals(clientsText, psText, stateText, ghosttyText, runtimeDir, monitorsText, cwdText) {
  var clients;
  try { clients = JSON.parse(clientsText); } catch (e) { return []; }
  if (!Array.isArray(clients)) return [];
  var monitors = monitorsById(monitorsText);
  var cwds = cwdsByPid(cwdText);
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
    var shellPid = childOnPty(c.pid, psText, pty);
    var where = cwds[shellPid] || { cwd: "", root: "" };
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
      cwd: where.cwd,
      root: where.root,
      monitor: mon ? mon.name : "",
      lx: c.at && mon ? c.at[0] - mon.x : 0,
      ly: c.at && mon ? c.at[1] - mon.y : 0,
      visible: !!mon && c.hidden !== true && (wsId === mon.active || (mon.special !== null && wsId === mon.special)),
      ghostty: ghostty.all[String(c.pid)] === true,
      wallpaperReady: !!ghostty.ready[String(c.pid)],
      confDir: ghostty.ready[String(c.pid)] || "",
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
      : t.indexOf("workspace:") === 0 ? String(term.workspace) === t.slice(10)
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
//   @@LAUNCHER     Ombre's Ghostty launcher is set up
//   @@THEME <name>\t<background image>   then that theme's colors.toml
function parseCatalog(text) {
  var out = { wallpaper: "", aether: false, aetherInstalled: false, aetherVersion: "",
              ghostty: false, launcher: false, modes: [], wallpapers: [], themes: [], own: [] };
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
    else if (line.indexOf("@@OMBRE ") === 0) { out.own.push(line.slice(8).trim()); section = ""; }
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
