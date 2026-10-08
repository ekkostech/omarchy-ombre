.pragma library

// Hues are vivid accents. A terminal background is the theme background with
// a little of the hue mixed in, so every tint stays readable on light and dark
// themes alike; the window border gets the full-strength hue.
var HUES = [
  { id: "red",    name: "Red",    hex: "#e5484d", key: "1" },
  { id: "orange", name: "Orange", hex: "#f76b15", key: "2" },
  { id: "amber",  name: "Amber",  hex: "#ffc53d", key: "3" },
  { id: "green",  name: "Green",  hex: "#46a758", key: "4" },
  { id: "teal",   name: "Teal",   hex: "#12a594", key: "5" },
  { id: "blue",   name: "Blue",   hex: "#3e63dd", key: "6" },
  { id: "purple", name: "Purple", hex: "#8e4ec6", key: "7" },
  { id: "pink",   name: "Pink",   hex: "#d6409f", key: "8" }
];

var DARK_STRENGTH = 0.18;
var LIGHT_STRENGTH = 0.14;

function isHex(value) {
  return /^#[0-9a-fA-F]{6}$/.test(String(value || ""));
}

function hue(id) {
  for (var i = 0; i < HUES.length; i++) if (HUES[i].id === id) return HUES[i];
  return null;
}

function hueIndex(id) {
  for (var i = 0; i < HUES.length; i++) if (HUES[i].id === id) return i;
  return -1;
}

// A tint value is a hue id or a "#rrggbb" color; anything else is no tint.
function isValue(value) {
  return hue(value) !== null || isHex(value);
}

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

// Terminal background for a tint value on the given theme background.
function background(value, themeBackground) {
  if (isHex(value)) return String(value).toLowerCase();
  var h = hue(value);
  if (!h) return "";
  return mix(themeBackground, h.hex, isLight(themeBackground) ? LIGHT_STRENGTH : DARK_STRENGTH);
}

// Full-strength color used for the window border and the swatch ring.
function accent(value) {
  if (isHex(value)) return String(value).toLowerCase();
  var h = hue(value);
  return h ? h.hex : "";
}

function label(value) {
  var h = hue(value);
  if (h) return h.name;
  return isHex(value) ? String(value).toLowerCase() : "None";
}

// Hyprland's Lua dispatcher: set or clear a per-window property.
function borderCommand(prop, address, color, alpha) {
  var v = color ? JSON.stringify("rgba(" + color.replace(/^#/, "") + alpha + ")") : "-1";
  return "hl.dsp.window.set_prop({ prop = " + JSON.stringify(prop)
    + ", value = " + v + ", window = " + JSON.stringify("address:0x" + address) + " })";
}

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

// State lines look like "pts-5 1234 blue": the pty, the terminal pid that owned
// it when tinted, and the tint value. A pty reused by a new terminal is ignored.
function parseState(text) {
  var out = {};
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/);
    if (parts.length < 3 || !/^pts-[0-9]+$/.test(parts[0])) continue;
    if (!isValue(parts[2])) continue;
    out["pts/" + parts[0].slice(4)] = { pid: parts[1], value: parts[2] };
  }
  return out;
}

function terminals(clientsText, psText, stateText) {
  var clients;
  try { clients = JSON.parse(clientsText); } catch (e) { return []; }
  if (!Array.isArray(clients)) return [];
  var procs = processes(psText);
  var state = parseState(stateText);
  var out = [];
  for (var i = 0; i < clients.length; i++) {
    var c = clients[i];
    if (c.mapped === false || !c.pid || c.pid < 0) continue;
    var pty = ptyFor(c.pid, procs);
    if (!pty) continue;
    var saved = state[pty];
    out.push({
      address: String(c.address || "").replace(/^0x/, ""),
      pid: String(c.pid),
      pty: pty,
      title: String(c.title || c.class || "Terminal"),
      cls: String(c["class"] || ""),
      workspace: c.workspace ? c.workspace.name || String(c.workspace.id) : "",
      focused: c.focusHistoryID === 0,
      x: c.at ? c.at[0] : 0,
      y: c.at ? c.at[1] : 0,
      w: c.size ? c.size[0] : 16,
      h: c.size ? c.size[1] : 9,
      value: saved && saved.pid === String(c.pid) ? saved.value : ""
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
