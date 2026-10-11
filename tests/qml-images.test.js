// Images from anywhere, end to end in real Qt: the scanner process, foldable
// sections, rejection of files that aren't PNG/JPEG, removal and settings.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const quickshell = require('./quickshell');
const repo = path.resolve(__dirname, '..');
const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';
const available = quickshell.available(shell);

test('added folders are read, folded and removed in the real picker', {skip: !available}, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-qml-images-'));
  try {
    const w = path.join(dir, 'My Walls');
    fs.mkdirSync(path.join(w, 'nature'), {recursive: true});
    fs.writeFileSync(path.join(w, 'a.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    fs.writeFileSync(path.join(w, 'nature/b.jpg'), Buffer.from([0xff, 0xd8, 0xff, 0xe0]));
    fs.writeFileSync(path.join(dir, 'fake.jpg'), 'RIFF0000WEBPVP8 ');
    fs.symlinkSync(repo, path.join(dir, 'plugin'));
    for (const n of ['Commons', 'Ui', 'services']) fs.symlinkSync(path.join(shell, 'shell', n), path.join(dir, n));
    fs.writeFileSync(path.join(dir, 'shell.qml'), `
import QtQuick
import Quickshell
import "plugin" as Plugin
ShellRoot {
 function check(ok, message) { if (!ok) throw new Error(message) }
 Plugin.Ombre {
  id: picker
  manifest: ({id: "ekkostech.ombre", version: "test"})
  welcomed: true
  solid: false
  function scan() {}
  function reapply() {}
  function loadCatalog() { catalogLoaded = true }
  function saveConfig() {}
  function send(line) {}
  function checkAgentThemes(action) {}
 }
 property int step: 0
 property string walls: ${JSON.stringify(w)}
 property string fake: ${JSON.stringify(path.join(dir, 'fake.jpg'))}
 Timer {
  interval: 100; repeat: true; running: true
  onTriggered: {
   if (picker.imagesProc_running) return
   if (step === 0) {
    check(picker.addImageSource(walls + "/") === "ok", "add refused")
    check(picker.imageSources.length === 1 && picker.imageSources[0] === walls, "path not cleaned: " + picker.imageSources)
    picker.addImageSource(fake)   // added at once: each addition must still be read and reported
    step = 1
   } else if (step === 1 && picker.imagesAdding.length === 0) {
    var keys = picker.wallpaperSections.map(function (s) { return s.key + ":" + s.images.length + (s.collapsed ? ":folded" : "") })
    check(keys.join(",") === walls + ":1," + walls + "/nature:0:folded,@builtin:0", "sections: " + keys)
    check(picker.imageSources.indexOf(fake) < 0, "a WebP named .jpg was kept")
    check(picker.wallpaperMessage.indexOf("not a PNG or JPEG") >= 0, "no reason given: " + picker.wallpaperMessage)
    check(picker.wallpaperChoices.indexOf(walls + "/nature/b.jpg") >= 0, "folded image left out of apply choices")
    check(picker.shownWallpapers.join() === walls + "/a.png", "Space would step into a folded folder")
    picker.toggleSection(walls + "/nature")
    check(picker.shownWallpapers.length === 2, "unfolding did not show the inner folder")
    picker.toggleSection(walls)
    check(picker.wallpaperSections.length === 2 && picker.shownWallpapers.length === 0, "folding the folder kept its insides: " + picker.wallpaperSections.length)
    check(JSON.parse(picker.looks("")).imageSources[0].count === 2, "looks() lacks the added folder")
    check(picker.removeImageSource(walls) === "ok" && picker.imageSources.length === 0, "remove failed")
    check(picker.collapsedFolders.length === 0, "fold state outlived its folder: " + picker.collapsedFolders)
    check(picker.removeImageSource(walls).indexOf("error") === 0, "removing twice should say so")
    picker.onConfig(JSON.stringify({imageSources: [walls, "relative", walls + "/", "/x\\"y"], collapsedFolders: ["@builtin", "rel", walls], browseFolder: walls + "/"}))
    check(picker.imageSources.join() === walls, "config sources: " + picker.imageSources)
    check(picker.collapsedFolders.join() === "@builtin," + walls, "config folds: " + picker.collapsedFolders)
    check(picker.browseFolder === walls, "browse folder: " + picker.browseFolder)
    picker.browseUp()
    check(picker.browseFolder === ${JSON.stringify(dir)}, "up went to " + picker.browseFolder)
    picker.browseTo("~/Pictures")
    check(picker.browseFolder === picker.home + "/Pictures", "~ not expanded: " + picker.browseFolder)
    picker.browseTo("/"); picker.browseUp()
    check(picker.browseFolder === "/", "went above /")
    console.log("OMBRE_IMAGES_QT_PASS")
    Qt.quit()
   }
  }
 }
 Timer { interval: 8000; running: true; onTriggered: Qt.quit() }
}
`.replace('   if (picker.imagesProc_running) return\n', ''));
    const result = quickshell.run(dir, {XDG_CONFIG_HOME: dir, HOME: dir});
    const output = result.stdout + result.stderr;
    assert.match(output, /OMBRE_IMAGES_QT_PASS/, output);
    assert.doesNotMatch(output, /Error:|TypeError:|ReferenceError:|Binding loop|Cannot assign|Unable to assign/, output);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});
