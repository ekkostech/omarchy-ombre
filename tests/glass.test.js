// Glass: the per-window Ghostty config the writer produces, the shader
// compiling, and the token the picker sends for each setting combination.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const quickshell = require('./quickshell');
const root = path.resolve(__dirname, '..');
const qml = fs.readFileSync(path.join(root, 'Ombre.qml'), 'utf8');
const writer = vm.runInNewContext(qml.split('readonly property string writerScript:')[1].split('\n\n  Process {')[0]);
const python = spawnSync('python3', ['--version']).status === 0;

test('writer puts glass first, only on windows with a wallpaper', {skip: !python}, () => {
  const result = spawnSync('python3', ['-c', String.raw`
import json, os, pathlib, subprocess, sys, tempfile
payload = json.load(sys.stdin)
with tempfile.TemporaryDirectory(prefix='ombre-glass-test-') as folder:
  d = pathlib.Path(folder)
  # An isolated dummy process named ghostty takes the reload signal; no real terminal is touched.
  child = subprocess.Popen([sys.executable, '-u', '-c', "import ctypes,signal,time; ctypes.CDLL(None).prctl(15,b'ghostty',0,0,0); signal.signal(signal.SIGUSR2,lambda *a:None); print('ready',flush=True); time.sleep(30)"], stdout=subprocess.PIPE, text=True)
  try:
    assert child.stdout.readline().strip() == 'ready'
    cdir = d/'runtime'/'ghostty'; cdir.mkdir(parents=True)
    out = {}
    for token, wallpaper in [('glass-dark', '0.15 0 /w/a b.png'), ('glass', '0.15 0 /w/a.png'), ('glass-light', '- 0 -'), ('dark', '0.15 0 /w/a.png'), ('-', '0.15 0 /w/a.png')]:
      line = f'ghostty {child.pid} {cdir}/ {token} - {wallpaper}\n'
      run = subprocess.run(['sh', '-c', payload['writer'], 'sh', str(d/'runtime'), payload['root']], input=line, text=True, capture_output=True, check=True)
      assert 'wallpaper-ok' in run.stdout, run
      out[token] = (cdir/(str(child.pid)+'.conf')).read_text()
    print(json.dumps(out))
  finally:
    child.terminate(); child.wait()
`], {input: JSON.stringify({root, writer}), encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  const out = JSON.parse(result.stdout);
  const shaders = (conf) => conf.split('\n').filter((l) => l.startsWith('custom-shader =')).map((l) => path.basename(l.split('"')[1]));
  assert.deepEqual(shaders(out['glass-dark']), ['glass.glsl', 'text-shadow-dark.glsl']);
  assert.match(out['glass-dark'], /^background-opacity = 0\.5$/m);
  assert.match(out['glass-dark'], /^background-opacity-cells = true$/m);
  assert.equal(out['glass-dark'].match(/custom-shader-animation = false/g).length, 1);
  assert.match(out['glass-dark'], /background-image = "\/w\/a b\.png"/);
  assert.deepEqual(shaders(out.glass), ['glass.glsl']);
  assert.match(out.glass, /custom-shader-animation = false/);
  // No wallpaper, nothing to see through: glass stays off, and so does the window's opacity.
  assert.deepEqual(shaders(out['glass-light']), ['text-shadow-light.glsl']);
  assert.doesNotMatch(out['glass-light'], /background-opacity/);
  assert.deepEqual(shaders(out.dark), ['text-shadow-dark.glsl']);
  assert.doesNotMatch(out.dark, /background-opacity/);
  assert.deepEqual(shaders(out['-']), []);
  assert.doesNotMatch(out['-'], /custom-shader-animation|background-opacity/);
});

const glslang = spawnSync('glslangValidator', ['--version']).status === 0;

test('shaders compile as Ghostty custom shaders', {skip: !glslang}, () => {
  const prelude = '#version 430 core\nuniform sampler2D iChannel0;\nuniform vec3 iResolution;\nlayout(location = 0) out vec4 _fragColor;\n'
    + 'void mainImage(out vec4 fragColor, in vec2 fragCoord);\nvoid main() { mainImage(_fragColor, gl_FragCoord.xy); }\n';
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-glsl-'));
  try {
    for (const name of ['glass.glsl', 'text-shadow-dark.glsl', 'text-shadow-light.glsl']) {
      const file = path.join(dir, name.replace('.glsl', '.frag'));
      fs.writeFileSync(file, prelude + fs.readFileSync(path.join(root, 'shaders', name), 'utf8'));
      const r = spawnSync('glslangValidator', [file], {encoding: 'utf8'});
      assert.equal(r.status, 0, name + '\n' + r.stdout + r.stderr);
    }
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';
test('the picker sends glass with or without the text shadow, and remembers it', {skip: !quickshell.available(shell)}, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-qml-glass-'));
  try {
    fs.symlinkSync(root, path.join(dir, 'plugin'));
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
 Timer {
  interval: 200; running: true
  onTriggered: {
   var t = {pid: "1", pty: "pts/9", look: null, wallpaper: null}
   check(picker.shadowVariant(t) === "-", "plain: " + picker.shadowVariant(t))
   check(picker.setGlass(true) === "ok" && picker.glass && picker.reshadowAll, "setGlass did not take")
   check(picker.shadowVariant(t) === "glass", "glass alone: " + picker.shadowVariant(t))
   picker.textShadow = true
   check(/^glass-(dark|light)$/.test(picker.shadowVariant(t)), "glass with shadow: " + picker.shadowVariant(t))
   picker.setGlass("false")
   check(/^(dark|light)$/.test(picker.shadowVariant(t)), "shadow alone: " + picker.shadowVariant(t))
   picker.onConfig(JSON.stringify({glass: true}))
   check(picker.glass === true, "config did not restore glass")
   console.log("OMBRE_GLASS_QT_PASS")
   Qt.quit()
  }
 }
 Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
`);
    const result = quickshell.run(dir, {XDG_CONFIG_HOME: dir});
    const output = result.stdout + result.stderr;
    assert.match(output, /OMBRE_GLASS_QT_PASS/, output);
    assert.doesNotMatch(output, /Error:|TypeError:|ReferenceError:|Binding loop/, output);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});
