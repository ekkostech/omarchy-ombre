// Glass: the per-window shader Ombre writes (colour, tint, blur), the Ghostty
// config around it, the colour settings, and the shader compiling.
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

const src = fs.readFileSync(path.join(root, 'Palette.js'), 'utf8').replace(/^\.pragma library\s*/, '');
const P = {};
vm.runInNewContext(src + '\n' + ['glassColor', 'glassLevel', 'glassToken', 'glassSwatches', 'mix'].map((n) => `P.${n} = ${n};`).join('\n'), {P, JSON, Math});

test('glass colours, levels and tokens', () => {
  assert.equal(P.glassColor('auto'), 'auto');
  assert.equal(P.glassColor(' #2A1040 '), '#2a1040');
  assert.equal(P.glassColor('2a1040'), '#2a1040');
  assert.equal(P.glassColor('smoke'), '#000000');
  assert.equal(P.glassColor('purple'), P.mix('#8e4ec6', '#000000', 0.55));
  for (const bad of ['', 'nope', '#12345', '#1234567', null, undefined]) assert.equal(P.glassColor(bad), '', String(bad));
  assert.equal(P.glassSwatches().length, 9);
  assert.deepEqual([P.glassLevel(150, 100, 86), P.glassLevel(-3, 100, 86), P.glassLevel('abc', 100, 86), P.glassLevel('', 60, 36), P.glassLevel('12', 60, 36)], [100, 0, 86, 36, 12]);
  assert.equal(P.glassToken('auto', 86, 36, '#1A0B0C', '-'), 'glass:1a0b0c:86:36');
  assert.equal(P.glassToken('auto', 86, 36, '#ff1a0b0c', 'dark'), 'glass:1a0b0c:86:36-dark', 'Qt colour strings may carry alpha');
  assert.equal(P.glassToken('#2a1040', 70, 20, '#ffffff', 'light'), 'glass:2a1040:70:20-light');
  assert.equal(P.glassToken('auto', 86, 36, 'garbage', '-'), 'glass:000000:86:36');
});

test('glass helper writes a private, hash-named shader per window', {skip: !python}, () => {
  const r = spawnSync('python3', ['-c', String.raw`
import json, os, pathlib, runpy, sys, tempfile
root = pathlib.Path(sys.argv[1])
mod = runpy.run_path(str(root/'bin/ombre-glass'))
template = (root/'shaders/glass.glsl').read_text()
text = mod['render'](template, '2A1040', 70, 20)
assert 'const vec3 TINT = vec3(0.02315, 0.00518, 0.05127);' in text, [l for l in text.splitlines() if 'TINT =' in l]
assert 'const float AMOUNT = 0.70;' in text and 'const float RADIUS = 20.0;' in text
for bad in [('zzzzzz', 70, 20), ('2a1040', 101, 20), ('2a1040', 70, 61), ('2a1040', -1, 20), ('2a104', 70, 20)]:
  try: mod['render'](template, *bad)
  except ValueError: pass
  else: raise AssertionError('accepted ' + repr(bad))
with tempfile.TemporaryDirectory() as d:
  os.umask(0o022)
  folder = pathlib.Path(d) / 'ghostty'; folder.mkdir(mode=0o700)
  first = mod['write'](folder, '4242', text)
  assert first.name.startswith('4242-glass-') and first.stat().st_mode & 0o777 == 0o600
  assert mod['write'](folder, '4242', text) == first
  second = mod['write'](folder, '4242', mod['render'](template, '000000', 86, 0))
  assert second != first and not first.exists(), 'old shader left behind'
  other = mod['write'](folder, '77', text)
  assert second.exists() and other.exists(), 'another window lost its shader'
  link = pathlib.Path(d) / 'link'; link.symlink_to(folder)
  for args in [(link, '4242'), (folder, '42x')]:
    try: mod['write'](args[0], args[1], text)
    except ValueError: pass
    else: raise AssertionError('accepted ' + repr(args))
print('ok')
`, root], {encoding: 'utf8'});
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test('writer puts the window glass shader first, and never half-applies it', {skip: !python}, () => {
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
    for name, token, wallpaper in [('both', 'glass:2a1040:70:20-dark', '0.15 0 /w/a b.png'), ('glass', 'glass:000000:86:36', '0.15 0 /w/a.png'),
                                   ('nowall', 'glass:2a1040:70:20-light', '- 0 -'), ('bad', 'glass:zzzzzz:70:20', '0.15 0 /w/a.png'),
                                   ('dark', 'dark', '0.15 0 /w/a.png'), ('none', '-', '0.15 0 /w/a.png')]:
      line = f'ghostty {child.pid} {cdir}/ {token} - {wallpaper}\n'
      run = subprocess.run(['sh', '-c', payload['writer'], 'sh', str(d/'runtime'), payload['root']], input=line, text=True, capture_output=True, check=True)
      assert 'wallpaper-ok' in run.stdout, run
      conf = (cdir/(str(child.pid)+'.conf')).read_text()
      shaders = [l.split('"')[1] for l in conf.splitlines() if l.startswith('custom-shader =')]
      out[name] = {'conf': conf, 'shaders': shaders, 'bodies': [pathlib.Path(s).read_text() if s.startswith(str(cdir)) else '' for s in shaders],
                   'files': sorted(p.name for p in cdir.glob('*-glass-*.glsl'))}
    print(json.dumps(out))
  finally:
    child.terminate(); child.wait()
`], {input: JSON.stringify({root, writer}), encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  const out = JSON.parse(result.stdout);
  const names = (o) => o.shaders.map((s) => path.basename(s).replace(/-glass-[0-9a-f]{12}\.glsl$/, '-glass.glsl'));
  assert.deepEqual(names(out.both), [`${names(out.both)[0].split('-')[0]}-glass.glsl`, 'text-shadow-dark.glsl']);
  assert.match(out.both.bodies[0], /TINT = vec3\(0\.02315, 0\.00518, 0\.05127\)/);
  assert.match(out.both.bodies[0], /AMOUNT = 0\.70;/);
  assert.match(out.both.conf, /^background-opacity = 0\.5$/m);
  assert.match(out.both.conf, /^background-opacity-cells = true$/m);
  assert.equal(out.both.conf.match(/custom-shader-animation = false/g).length, 1);
  assert.match(out.both.conf, /background-image = "\/w\/a b\.png"/);
  assert.match(out.glass.bodies[0], /AMOUNT = 0\.86;/);
  assert.equal(out.glass.files.length, 1, 'old glass shaders pile up: ' + out.glass.files);
  // No wallpaper, nothing to see through: no glass, and the window keeps its opacity.
  assert.deepEqual(names(out.nowall), ['text-shadow-light.glsl']);
  assert.doesNotMatch(out.nowall.conf, /background-opacity/);
  // A shader that can't be written must not leave the window half see-through.
  assert.deepEqual(names(out.bad), []);
  assert.doesNotMatch(out.bad.conf, /background-opacity|custom-shader-animation/);
  assert.deepEqual(names(out.dark), ['text-shadow-dark.glsl']);
  assert.doesNotMatch(out.dark.conf, /background-opacity/);
  assert.deepEqual(names(out.none), []);
  assert.doesNotMatch(out.none.conf, /custom-shader-animation|background-opacity/);
});

const glslang = spawnSync('glslangValidator', ['--version']).status === 0;

test('shaders compile as Ghostty custom shaders, including written glass', {skip: !glslang || !python}, () => {
  const prelude = '#version 430 core\nuniform sampler2D iChannel0;\nuniform vec3 iResolution;\nlayout(location = 0) out vec4 _fragColor;\n'
    + 'void mainImage(out vec4 fragColor, in vec2 fragCoord);\nvoid main() { mainImage(_fragColor, gl_FragCoord.xy); }\n';
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-glsl-'));
  try {
    const written = spawnSync('python3', ['-c', `import runpy,pathlib,sys; m=runpy.run_path(sys.argv[1]+'/bin/ombre-glass'); print(m['render'](pathlib.Path(sys.argv[1]+'/shaders/glass.glsl').read_text(), 'ff8800', 40, 0))`, root], {encoding: 'utf8'});
    assert.equal(written.status, 0, written.stderr);
    const sources = {'glass-written': written.stdout};
    for (const name of ['glass', 'text-shadow-dark', 'text-shadow-light']) sources[name] = fs.readFileSync(path.join(root, 'shaders', name + '.glsl'), 'utf8');
    for (const [name, body] of Object.entries(sources)) {
      const file = path.join(dir, name + '.frag');
      fs.writeFileSync(file, prelude + body);
      const r = spawnSync('glslangValidator', [file], {encoding: 'utf8'});
      assert.equal(r.status, 0, name + '\n' + r.stdout + r.stderr);
    }
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';
test('the picker sends glass colour, tint and blur, follows the look on auto, and remembers them', {skip: !quickshell.available(shell)}, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-qml-glass-'));
  try {
    fs.symlinkSync(root, path.join(dir, 'plugin'));
    for (const n of ['Commons', 'Ui', 'services']) fs.symlinkSync(path.join(shell, 'shell', n), path.join(dir, n));
    fs.writeFileSync(path.join(dir, 'shell.qml'), `
import QtQuick
import Quickshell
import "plugin" as Plugin
import "plugin/Palette.js" as Palette
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
   var plain = {pid: "1", pty: "pts/9", look: null, wallpaper: null}
   var red = {pid: "2", pty: "pts/8", look: Palette.tintLook("red"), wallpaper: null}
   check(picker.shadowVariant(plain) === "-", "plain: " + picker.shadowVariant(plain))
   check(picker.setGlass(true) === "ok" && picker.glass && picker.reshadowAll, "setGlass did not take")
   var redBg = Palette.lookBackground(red.look, picker.themeBackground).slice(1).toLowerCase()
   check(picker.shadowVariant(red) === "glass:" + redBg + ":86:36", "auto should follow the look: " + picker.shadowVariant(red))
   check(picker.shadowVariant(plain) !== picker.shadowVariant(red), "auto gave two looks the same glass")
   check(picker.setGlassColor("purple") === "ok" && picker.glassColor === Palette.glassColor("purple"), "swatch name")
   check(picker.setGlassColor("nope").indexOf("error") === 0 && picker.glassColor === Palette.glassColor("purple"), "bad colour changed the setting")
   picker.setGlassColor("#2A1040"); picker.setGlassTint(150); picker.setGlassBlur("12")
   picker.textShadow = true
   check(/^glass:2a1040:100:12-(dark|light)$/.test(picker.shadowVariant(red)), "fixed colour with shadow: " + picker.shadowVariant(red))
   picker.setGlassBlur("abc")
   check(picker.glassBlur === 12, "bad blur changed the setting")
   check(JSON.parse(picker.looks("")).glass.color === "#2a1040", "looks() lacks glass")
   picker.resetGlass()
   check(picker.glassColor === "auto" && picker.glassTint === 86 && picker.glassBlur === 36, "reset")
   picker.setGlass("false")
   check(/^(dark|light)$/.test(picker.shadowVariant(plain)), "shadow alone: " + picker.shadowVariant(plain))
   picker.onConfig(JSON.stringify({glass: true, glassColor: "#112233", glassTint: 40, glassBlur: 0}))
   check(picker.glass && picker.glassColor === "#112233" && picker.glassTint === 40 && picker.glassBlur === 0, "config did not restore glass")
   picker.onConfig(JSON.stringify({glassColor: "rm -rf", glassTint: "x"}))
   check(picker.glassColor === "#112233" && picker.glassTint === 40, "bad config values were taken")
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
