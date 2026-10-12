// Aether palettes from one colour: bin/ombre-colour (with a stand-in aether) and Palette.colourLooks.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'Palette.js'), 'utf8').replace(/^\.pragma library\s*/, '');
const P = {};
vm.runInNewContext(src + '\nP.colourLooks = colourLooks; P.pretty = pretty; P.lookLabel = lookLabel; P.normalizeLook = normalizeLook; P.sameLook = sameLook;', {P, JSON, Math});

const classic = ['#0f121b','#dd3e3e','#3edd3e','#dddd3e','#3e63dd','#dd3edd','#3edddd','#e8e9ed','#4d597f','#eb6363','#63eb63','#ebeb63','#6383eb','#eb63eb','#63ebeb','#fafafa'];

test('colour palettes become moods whose accent is the chosen colour in every variant', () => {
  const vivid = classic.map((c, i) => i === 4 ? '#1c51ff' : c);
  const looks = P.colourLooks(JSON.stringify({base: '#3E63DD', variants: [
    {id: '', name: 'Classic', colors: classic}, {id: 'vivid', name: 'Vivid', colors: vivid},
    {id: 'bad id', name: 'X', colors: classic}, {id: 'short', name: 'Short', colors: classic.slice(0, 8)}]}));
  assert.equal(looks.length, 2);
  assert.equal(looks[0].id, 'colour-3e63dd');
  assert.equal(looks[1].id, 'colour-3e63dd-vivid');
  assert.equal(looks[0].palette.accent, '#3e63dd');
  assert.equal(looks[1].palette.accent, '#1c51ff', 'the accent follows the base colour slot into the variant');
  assert.equal(P.pretty(looks[0].id), '#3e63dd');
  assert.equal(P.pretty(looks[1].id), 'Vivid #3e63dd');
  assert.equal(P.lookLabel(looks[1]), 'Vivid #3e63dd', 'no wallpaper name for a colour palette');
  const saved = P.normalizeLook(JSON.parse(JSON.stringify(looks[1])));
  assert.ok(saved && P.sameLook(saved, looks[1]), 'colour palettes survive saving');
  assert.equal(P.colourLooks('not json').length, 0);
  assert.equal(P.colourLooks(JSON.stringify({base: 'blue', variants: []})).length, 0);
});

test('ombre-colour asks Aether for the classic palette and five adjustments', {skip: spawnSync('python3', ['--version']).status !== 0}, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-colour-test-'));
  try {
    const log = path.join(dir, 'calls');
    fs.writeFileSync(path.join(dir, 'aether'), `#!/usr/bin/env python3
import json, os, sys
with open(os.environ['OMBRE_TEST_LOG'], 'a') as f: f.write(' '.join(sys.argv[1:3]) + '\\n')
colors = ${JSON.stringify(classic)}
if sys.argv[1] == '--palette-from-color': print(json.dumps({'base': sys.argv[2], 'colors': colors}))
elif '--contrast' in sys.argv: sys.exit(1)
else: print(json.dumps({'input': json.loads(sys.argv[2]), 'output': colors}))
`);
    fs.chmodSync(path.join(dir, 'aether'), 0o755);
    const env = {...process.env, PATH: dir + ':' + process.env.PATH, OMBRE_TEST_LOG: log};
    const r = spawnSync('python3', ['-I', path.join(root, 'bin/ombre-colour'), '#3E63DD'], {encoding: 'utf8', env});
    assert.equal(r.status, 0, r.stderr);
    const out = JSON.parse(r.stdout);
    assert.equal(out.base, '#3e63dd');
    assert.deepEqual(out.variants.map(v => v.name), ['Classic', 'Vivid', 'Soft', 'Warm', 'Cool'], 'a variant Aether fails is left out');
    assert.match(fs.readFileSync(log, 'utf8'), /--palette-from-color #3e63dd/);
    const bad = spawnSync('python3', ['-I', path.join(root, 'bin/ombre-colour'), 'blue; rm -rf /'], {encoding: 'utf8', env});
    assert.equal(bad.status, 2);
  } finally {
    fs.rmSync(dir, {recursive: true, force: true});
  }
});
