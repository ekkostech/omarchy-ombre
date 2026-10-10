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
  "layerLook", "foregroundLook", "textLook", "backgroundLook", "lookForeground", "ghosttyColors", "HUES", "tintLook", "normalizeLook", "sameLook", "lookBackground", "lookAccent", "sequence", "isLight", "mix",
  "parseState", "terminals", "match", "parseCatalog", "parseModes", "parseMoods", "projectFor", "normalizeWallpaper", "normalizeBlur", "sameWallpaper",
  "agentState", "pulseColor", "borderCommand", "opacityPair", "aetherPalette", "themeGradient", "borderPair", "isImagePath", "themePalette", "parseToml"
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

test("opacityPair sets both opacities in one call and clamps values", () => {
  const solid = P.opacityPair("5a1b", 1, 1);
  assert.match(solid, /^function\(\) hl\.dispatch\(/);
  assert.match(solid, /prop = "opacity", value = 1, window = "address:0x5a1b"/);
  assert.match(solid, /prop = "opacity_inactive", value = 1, window = "address:0x5a1b"/);
  const back = P.opacityPair("5a1b", 0.985, 0.96);
  assert.match(back, /prop = "opacity", value = 0\.985/);
  assert.match(back, /prop = "opacity_inactive", value = 0\.96/);
  assert.match(P.opacityPair("5a1b", 7, -2), /value = 1,.*value = 0,/);
  assert.match(P.opacityPair("5a1b", "x", NaN), /value = 1,.*value = 1,/);
});

test("a mood's background and text carry its accent so moods differ on black themes", () => {
  const fire = P.aetherPalette(["#0c0000", "#bd615b", "#928b58", "#aa9b69", "#8c66b2", "#b3608e", "#a27bc8", "#f4d8c5", "#68605f", "#eb8279", "#b7b16d", "#d1c27f", "#b485e6", "#e07fb9", "#cb9bfd", "#ffdfb4"]);
  const ocean = P.aetherPalette(["#000312", "#b75da6", "#4a9a7f", "#8c9a5a", "#5388dd", "#9b6fc9", "#4fa3c0", "#c4e5e9", "#5a6470", "#d47ac0", "#60b898", "#a8b870", "#6fa0f0", "#b58ae0", "#66c0dc", "#dff4f6"]);
  assert.equal(fire.accent, "#bd615b");
  assert.equal(fire.colors[0], "#0c0000");
  assert.notEqual(fire.background, "#0c0000");
  assert.notEqual(fire.background, ocean.background);
  const [fr, fg, fb] = [1, 3, 5].map((i) => parseInt(fire.background.slice(i, i + 2), 16));
  assert.ok(fr > fb && fr > fg, "fire is warm: " + fire.background);
  const [or, og, ob] = [1, 3, 5].map((i) => parseInt(ocean.background.slice(i, i + 2), 16));
  assert.ok(ob > or, "ocean is blue: " + ocean.background);
  assert.ok(P.isLight(fire.foreground) && !P.isLight(fire.background));
});

test("no look puts the theme's border back instead of emptying it", () => {
  assert.equal(P.themeGradient('{"option": "general:col.active_border", "gradient": "ff788fff 0deg", "set": true }'), "rgba(788fffff)");
  assert.equal(P.themeGradient("gradient data: ee33ccff ee00ff99 45deg\nset: true"), "rgba(33ccffee)");
  assert.equal(P.themeGradient("nonsense"), "");
  const theme = { active: "rgba(788fffff)", inactive: "rgba(595959aa)" };
  const back = P.borderPair("ab12", "", "ff", "", "ff", theme);
  assert.ok(back.includes('prop = "active_border_color", value = "rgba(788fffff)"'));
  assert.ok(back.includes('prop = "inactive_border_color", value = "rgba(595959aa)"'));
  assert.ok(!back.includes("-1"));
  assert.ok(P.borderPair("ab12", "#3e63dd", "ff", "#1a2a5a", "ff", theme).includes('value = "rgba(3e63ddff)"'));
});

const mood = (id, fg, bg) => ({kind: "mood", id, source: "/wall.jpg", palette: {
  foreground: fg, background: bg, cursor: "#abcdef", accent: "#6699aa",
  colors: Array.from({length: 16}, (_, i) => "#" + (0x112230 + i).toString(16))
}});

test("background changes preserve mood text, ANSI colors and foreground overrides", () => {
  const fire = mood("fire", "#eec8b0", "#301210");
  const custom = P.foregroundLook(fire, "#ffeedd");
  const changed = P.layerLook(custom, P.tintLook("blue"), "background");
  assert.equal(P.lookForeground(changed), "#ffeedd");
  assert.equal(P.textLook(changed).id, "fire");
  assert.equal(P.backgroundLook(changed).id, "blue");
  const seq = P.sequence(changed, "#101010");
  assert.ok(seq.includes("\x1b]4;1;#112231\x1b\\"));
  assert.ok(seq.includes("\x1b]10;#ffeedd\x1b\\"));
  assert.ok(!seq.includes("\x1b]104\x1b\\"));
});

test("text-only presets preserve background; each layer resets independently", () => {
  const fire = mood("fire", "#eec8b0", "#301210");
  const ocean = mood("ocean", "#b0d8ee", "#101830");
  const combined = P.layerLook(fire, ocean, "text");
  assert.equal(P.lookForeground(combined), "#b0d8ee");
  assert.equal(P.lookBackground(combined, "#000000"), "#301210");
  const defaultText = P.layerLook(combined, null, "text");
  assert.equal(P.textLook(defaultText), null);
  assert.equal(P.lookBackground(defaultText, "#000000"), "#301210");
  assert.equal(P.layerLook(defaultText, null, "background"), null);
  assert.equal(P.layerLook(combined, ocean, "all").kind, "mood");
});

test("layered looks survive state serialization and reject nested/invalid data", () => {
  const look = P.foregroundLook(P.layerLook(null, mood("fire", "#eec8b0", "#301210"), "text"), "#FfEeDd");
  const parsed = P.parseState('pts-3 ' + JSON.stringify({pid: "100", look}) + '\n');
  assert.equal(JSON.stringify(parsed["pts/3"].look), JSON.stringify(look));
  assert.equal(P.normalizeLook({kind: "layers", text: {kind: "layers"}, foreground: "x;command"}), null);
  assert.equal(P.normalizeLook({kind: "layers", text: P.tintLook("blue")}), null);
});

test("Ghostty config contains the same text/background colors as OSC and clears absent layers", () => {
  const look = P.layerLook(mood("fire", "#eec8b0", "#301210"), P.tintLook("#102030"), "background");
  const conf = P.ghosttyColors(look, "#000000").split(";");
  assert.ok(conf.includes("foreground=eec8b0"));
  assert.ok(conf.includes("background=102030"));
  assert.ok(conf.includes("palette=1=112231"));
  assert.equal(conf.filter(x => x.startsWith("palette=")).length, 16);
  assert.equal(P.ghosttyColors(null, "#000000"), "-");
  assert.equal(P.ghosttyColors(P.layerLook(look, null, "text"), "#000000"), "background=102030");
});

const qml = fs.readFileSync(path.join(__dirname, "..", "Ombre.qml"), "utf8");
function qmlFunction(name, context) {
  const start = qml.indexOf("  function " + name + "(");
  // Stop at the function's root indentation, retaining nested functions.
  const bodyEnd = qml.indexOf("\n  }", start) + 4;
  return vm.runInNewContext("(" + qml.slice(start, bodyEnd).trim() + ")", context);
}

test("wallpaper reload replay retains the active hover preview instead of resetting colors", () => {
  const preview = mood("ocean", "#b0d8ee", "#101830");
  const terminal = {pty: "pts/1", look: mood("fire", "#eec8b0", "#301210")};
  const shown = [];
  const root = {reshowPtys: ["pts/1"], terminals: [terminal], indexOf: () => 0,
    previewPty: "pts/1", previewLook: preview, show: (t, look) => shown.push(look)};
  qmlFunction("onReshow", {root})();
  assert.equal(shown[0], preview);
});

test("Ghostty writer shell parses and serializes the extra palette token", () => {
  const {spawnSync} = require("node:child_process");
  const expression = qml.split("readonly property string writerScript:")[1].split("\n  Process {")[0].trim();
  const script = vm.runInNewContext(expression);
  const result = spawnSync("sh", ["-n"], {input: script, encoding: "utf8"});
  assert.equal(result.status, 0, result.stderr);
  assert.ok(script.includes('colors=${rest%% *}'));
  assert.ok(script.includes('printf "%s\\n" "$colors" | tr ";" "\\n"'));
});


test("explicit text color updates default foreground and ANSI normal/bright white together", () => {
  for (const base of [null, mood("ocean", "#b0d8ee", "#101830")]) {
    const look = P.foregroundLook(base, "#ff66cc");
    const seq = P.sequence(look, "#000000");
    assert.ok(seq.includes("\x1b]10;#ff66cc\x1b\\"));
    assert.ok(seq.includes("\x1b]4;7;#ff66cc\x1b\\"));
    assert.ok(seq.includes("\x1b]4;15;#ff66cc\x1b\\"));
    const conf = P.ghosttyColors(look, "#000000").split(";");
    assert.equal(conf.filter(x => x.startsWith("palette=7=")).at(-1), "palette=7=ff66cc");
    assert.equal(conf.filter(x => x.startsWith("palette=15=")).at(-1), "palette=15=ff66cc");
    if (base) {
      assert.ok(seq.includes("\x1b]4;1;#112231\x1b\\"), "semantic red remains from the palette");
      assert.equal(P.lookBackground(look, "#000000"), "#101830");
    }
  }
});

test("wallpaper blur defaults off, clamps safely and participates in equality",()=>{
 assert.equal(P.normalizeWallpaper({path:"/a.png"}).blur,0);
 assert.equal(P.normalizeBlur(99),40);assert.equal(P.normalizeBlur(-4),0);assert.equal(P.normalizeBlur("bad"),0);
 assert.equal(P.sameWallpaper({path:"/a.png",strength:0.1},{path:"/a.png",strength:0.1,blur:0}),true);
 assert.equal(P.sameWallpaper({path:"/a.png",strength:0.1,blur:10},{path:"/a.png",strength:0.1,blur:20}),false);
});
