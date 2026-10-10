.pragma library
.import "Palette.js" as Palette

// Pure feature state: no filesystem, compositor or terminal writes.
function key(term) { return term ? String(term.pid) + ":" + term.pty + ":" + term.address : ""; }
function snapshot(term) {
  return JSON.parse(JSON.stringify({ look: Palette.normalizeLook(term && term.look),
    wallpaper: Palette.normalizeWallpaper(term && term.wallpaper) }));
}
function same(a, b) { return JSON.stringify(snapshot(a)) === JSON.stringify(snapshot(b)); }
function name(value) {
  if (typeof value !== "string") return "";
  var n = value.trim();
  return n.length > 0 && n.length <= 64 && !/[\u0000-\u001f\u007f]/.test(n) ? n : "";
}
function library(values) {
  if (!Array.isArray(values)) return [];
  var out = [], seen = Object.create(null);
  for (var i = 0; i < values.length && out.length < 200; i++) {
    var v = values[i], n = name(v && v.name);
    if (!n || seen[n.toLowerCase()]) continue;
    if (v.look && !Palette.normalizeLook(v.look)) continue;
    if (v.wallpaper && !Palette.normalizeWallpaper(v.wallpaper)) continue;
    var state = snapshot(v);
    out.push({name: n, look: state.look, wallpaper: state.wallpaper, favorite: v.favorite === true});
    seen[n.toLowerCase()] = true;
  }
  return out;
}
function find(values, wanted) {
  var n = name(wanted).toLowerCase();
  for (var i = 0; i < values.length; i++) if (values[i].name.toLowerCase() === n) return i;
  return -1;
}
function sorted(values, favoritesOnly) {
  return values.filter(function (v) { return !favoritesOnly || v.favorite; }).slice().sort(function (a, b) {
    if (a.favorite !== b.favorite) return a.favorite ? -1 : 1;
    return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
  });
}
function filtered(terminals, query, workspace) {
  var words = String(query || "").trim().toLowerCase().split(/\s+/).filter(function (w) { return !!w; });
  var out = [];
  for (var i = 0; i < terminals.length; i++) {
    var t = terminals[i];
    if (workspace !== "" && String(t.workspace) !== String(workspace)) continue;
    var text = [t.title, t.cwd, t.root, t.workspace, t.cls].join(" ").toLowerCase();
    if (words.every(function (w) { return text.indexOf(w) >= 0; })) out.push(Object.assign({}, t, {sourceIndex: i}));
  }
  return out;
}
function targets(terminals, visible, marked, current) {
  var out = [];
  if (marked.length) {
    for (var i = 0; i < visible.length; i++) if (marked.indexOf(key(visible[i])) >= 0) out.push(visible[i].sourceIndex);
  } else {
    for (var j = 0; j < visible.length; j++) if (visible[j].sourceIndex === current) { out.push(current); break; }
  }
  return out;
}
function prune(histories, terminals) {
  var next = {};
  for (var i = 0; i < terminals.length; i++) {
    var k = key(terminals[i]);
    if (histories[k]) next[k] = histories[k];
  }
  return next;
}
function record(histories, term, before) {
  var after = snapshot(term);
  if (same(before, after)) return histories;
  var k = key(term), entry = histories[k] || {past: [], future: []}, next = Object.assign({}, histories);
  next[k] = {past: entry.past.concat([snapshot(before)]).slice(-50), future: []};
  return next;
}
function travel(histories, term, direction) {
  var k = key(term), entry = histories[k];
  if (!entry) return null;
  var undo = direction !== "redo", from = undo ? entry.past : entry.future;
  if (!from.length) return null;
  var next = Object.assign({}, histories), current = snapshot(term);
  next[k] = undo ? {past: from.slice(0, -1), future: entry.future.concat([current]).slice(-50)}
    : {past: entry.past.concat([current]).slice(-50), future: from.slice(0, -1)};
  return {histories: next, state: snapshot(from[from.length - 1])};
}
