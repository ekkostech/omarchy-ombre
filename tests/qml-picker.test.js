// Real Qt model conversion, which cannot be reproduced by Node-only fixtures.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const quickshell = require('./quickshell');
const repo = path.resolve(__dirname, '..');
const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';
const available = quickshell.available(shell);

test('real mood/theme card clicks survive Qt modelData array conversion', {skip: !available}, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-picker-test-'));
  try {
    fs.symlinkSync(repo, path.join(dir, 'plugin'));
    for (const name of ['Commons', 'Ui', 'services']) {
      fs.symlinkSync(path.join(shell, 'shell', name), path.join(dir, name));
    }
    fs.writeFileSync(path.join(dir, 'shell.qml'), `
import QtQuick
import Quickshell
import "plugin" as Plugin
import "plugin/Palette.js" as Palette
ShellRoot {
 id: testRoot
 property int passed: 0
 function check(ok, message) { if (!ok) throw new Error(message) }
 Item {
  Repeater {
   model: [
    {kind: "mood", id: "fire", source: "/wallpaper.png", palette: Palette.themePalette({background: "#101010", foreground: "#eeaa77", accent: "#ff4400"})},
    {kind: "theme", id: "ocean", palette: Palette.themePalette({background: "#102030", foreground: "#aaddff", accent: "#00aaff"})}
   ]
   delegate: Plugin.LookChip {
    required property var modelData
    look: modelData
    onPicked: {
     // Exercise the conversion and normalization used by commitWithWallpaper.
     testRoot.check(!Array.isArray(modelData.palette.colors), "fixture must exercise a Qt sequence")
     var prior = Palette.foregroundLook(Palette.tintLook("#334455"), "#ff00ff")
     var full = Palette.normalizeLook(Palette.layerLook(prior, modelData, "all"))
     testRoot.check(full !== null && full.id === modelData.id, "card click cleared the preset")
     testRoot.check(Array.isArray(full.palette.colors), "saved palette must be a JS array")
     testRoot.check(Palette.lookForeground(full) === modelData.palette.foreground, "old text override survived preset")
     var text = Palette.normalizeLook(Palette.layerLook(prior, modelData, "text"))
     testRoot.check(text !== null && Palette.lookForeground(text) === modelData.palette.foreground, "text-only click lost palette")
     testRoot.check(Palette.lookBackground(text, "#000000") === "#334455", "text-only click changed background")
     testRoot.check(Palette.sequence(full, "#000000").indexOf("10;" + modelData.palette.foreground) >= 0, "foreground OSC missing")
     testRoot.check(Palette.ghosttyColors(full, "#000000").indexOf("palette=1=") >= 0, "persisted palette missing")
     testRoot.check(Palette.normalizeLook(JSON.parse(JSON.stringify(full))) !== null, "state roundtrip lost preset")
     testRoot.passed++
    }
    Component.onCompleted: picked()
   }
  }
 }
 Timer {
  interval: 300; running: true
  onTriggered: {
   if (testRoot.passed === 2) console.log("OMBRE_PICKER_QT_PASS")
   Qt.quit()
  }
 }
}
`);
    const result = quickshell.run(dir);
    const output = result.stdout + result.stderr;
    assert.equal(result.status, 0, output);
    assert.match(output, /OMBRE_PICKER_QT_PASS/, output);
    assert.doesNotMatch(output, /Error:|TypeError:|ReferenceError:/, output);
  } finally {
    fs.rmSync(dir, {recursive:true, force:true});
  }
});
