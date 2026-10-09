// Run with: node --test tests/*.test.js
// Palette.js is a QML .pragma library file; it is loaded here as plain JS.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const src = fs.readFileSync(path.join(__dirname, "..", "Palette.js"), "utf8").replace(/^\.pragma library\s*/, "");
const P = {};
vm.runInNewContext(src + "\n" + [
  "HUES", "tintLook", "normalizeLook", "sameLook", "lookBackground", "lookAccent", "sequence", "isLight", "mix",
  "parseState", "terminals", "match", "parseCatalog", "parseModes", "parseMoods", "projectFor", "normalizeWallpaper",
  "agentState", "pulseColor", "borderCommand", "isImagePath", "themePalette", "parseToml"
].map((n) => `P.${n} = ${n};`).join("\n"), { P, JSON, Math });

test("tints mix into the theme background and stay dark on dark themes", () => {
  const bg = P.lookBackground(P.tintLook("blue"), "#000003");
  assert.match(bg, /^#[0-9a-f]{6}$/);
  assert.ok(!P.isLight(bg));
  assert.equal(P.lookAccent(P.tintLook("red")), "#e5484d");
  assert.equal(P.tintLook("#203040").id, "#203040");
  assert.equal(P.tintLook("nope"), null);
});

test("sequences set and reset the right OSC codes", () => {
  assert.equal(P.sequence(null, "#000003"), "\x1b]104\x1b\\\x1b]110\x1b\\\x1b]112\x1b\\\x1b]111\x1b\\");
  const seq = P.sequence(P.tintLook("blue"), "#000003");
  assert.ok(seq.endsWith("\x1b]11;" + P.lookBackground(P.tintLook("blue"), "#000003") + "\x1b\\"));
});

test("themes map colors.toml onto 16 ANSI colours", () => {
  const pal = P.themePalette(P.parseToml('background = "#1a1b26"\nforeground = "#a9b1d6"\nred = "#f7768e"\naccent = "#7aa2f7"\n'));
  assert.equal(pal.colors.length, 16);
  assert.equal(pal.colors[0], "#1a1b26");
  assert.equal(pal.colors[1], "#f7768e");
  assert.equal(pal.accent, "#7aa2f7");
});

test("looks and wallpapers are validated before use", () => {
  assert.equal(P.normalizeLook({ kind: "theme", id: "x;rm -rf", palette: {} }), null);
  assert.equal(P.normalizeWallpaper({ path: "relative.jpg" }), null);
  assert.equal(P.normalizeWallpaper({ path: "/a/b.PNG", strength: 9 }).strength, 1);
  assert.equal(P.isImagePath('/a/"quoted".jpg'), false);
});

test("terminals are found by pty, with saved looks tied to the pid", () => {
  const clients = JSON.stringify([
    { address: "0xaa", pid: 100, class: "foot", title: "one", workspace: { id: 1, name: "1" }, at: [0, 0], size: [10, 10], focusHistoryID: 0, monitor: 0 },
    { address: "0xbb", pid: 200, class: "foot", title: "two", workspace: { id: 1, name: "1" }, at: [10, 0], size: [10, 10], focusHistoryID: 1, monitor: 0 },
    { address: "0xcc", pid: 300, class: "nemo", title: "files", workspace: { id: 1, name: "1" }, at: [0, 0], size: [10, 10], focusHistoryID: 2, monitor: 0 }]);
  const ps = "100 1 ?\n101 100 pts/1\n200 1 ?\n201 200 pts/2\n300 1 ?\n";
  const state = 'pts-1 {"pid":"100","look":{"kind":"tint","id":"blue"}}\npts-2 {"pid":"999","look":{"kind":"tint","id":"red"}}\n';
  const mons = JSON.stringify([{ id: 0, name: "DP-1", x: 0, y: 0, activeWorkspace: { id: 1 }, specialWorkspace: { id: 0 } }]);
  const list = P.terminals(clients, ps, state, "", "/rt", mons, "101\t/home/u/proj\t/home/u/proj\n");
  assert.deepEqual([...list.map((t) => t.pty)], ["pts/1", "pts/2"]);
  assert.equal(list[0].look.id, "blue");
  assert.equal(list[1].look, null, "a reused pty starts clean");
  assert.equal(list[0].cwd, "/home/u/proj");
  assert.equal(list[0].visible, true);
  assert.deepEqual([...P.match(list, "title:TWO").map((t) => t.pty)], ["pts/2"]);
});

test("project rules prefer the deepest matching folder", () => {
  const rules = [{ path: "/p" }, { path: "/p/a" }];
  assert.equal(P.projectFor(rules, "/p/a/src").path, "/p/a");
  assert.equal(P.projectFor(rules, "/p/b").path, "/p");
  assert.equal(P.projectFor(rules, "/px"), null);
});

test("catalog parsing survives missing or old Aether", () => {
  assert.equal(P.parseCatalog("@@WALLPAPER /w.jpg\n").aether, false);
  assert.equal(P.parseCatalog("@@AETHER aether 3.0.0\n").aetherInstalled, true);
  const c = P.parseCatalog('@@AETHER aether 4.32.0\n@@MODES\n{"modes":[{"name":"fire","description":"Bonfire mood: warm"},{"name":"normal","description":"Auto"}]}\n');
  assert.equal(c.aether, true);
  assert.equal(c.modes[0].id, "fire", "moods come first");
});

test("agent state is read from the window title", () => {
  assert.equal(P.agentState("◐ working"), "working");
  assert.equal(P.agentState("✳ done"), "idle");
  assert.equal(P.agentState("🔔 ✳ done"), "idle");
  assert.equal(P.agentState("zsh"), "other");
});

test("Hyprland border commands quote the address and colour", () => {
  assert.equal(P.borderCommand("active_border_color", "ab12", "#3e63dd", "ff"),
    'hl.dsp.window.set_prop({ prop = "active_border_color", value = "rgba(3e63ddff)", window = "address:0xab12" })');
  assert.equal(P.borderCommand("active_border_color", "ab12", "", "ff").includes("value = -1"), true);
});
