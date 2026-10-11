// Images added from anywhere: the scanner, the foldable sections and the CLI.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const scanner = path.join(root, 'bin/ombre-images');

const src = fs.readFileSync(path.join(root, 'Palette.js'), 'utf8').replace(/^\.pragma library\s*/, '');
const P = {};
vm.runInNewContext(src + '\n' + ['normalizeImageSources', 'parseImageScan', 'imageSections', 'addedImages', 'visibleImages',
  'cleanSourcePath', 'tildePath', 'folderName', 'parseCatalog', 'MAX_IMAGE_SOURCES'].map((n) => `P.${n} = ${n};`).join('\n'), {P, JSON, Math});

// Values made inside the vm context have their own Array prototype.
const plain = (v) => JSON.parse(JSON.stringify(v));

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0]);
const WEBP = Buffer.from('RIFF0000WEBPVP8 ');

function tree() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-images-test-'));
  const w = path.join(dir, 'walls');
  for (const d of ['nature/deep/deeper/deepest', 'empty/inner', '.hidden']) fs.mkdirSync(path.join(w, d), {recursive: true});
  fs.writeFileSync(path.join(w, 'b.png'), PNG);
  fs.writeFileSync(path.join(w, 'A.JPG'), JPEG);
  fs.writeFileSync(path.join(w, 'renamed.jpg'), WEBP);
  fs.writeFileSync(path.join(w, 'notes.txt'), 'x');
  fs.writeFileSync(path.join(w, 'photo.webp'), WEBP);
  fs.writeFileSync(path.join(w, 'quote".png'), PNG);
  fs.writeFileSync(path.join(w, 'nature/c.jpeg'), JPEG);
  fs.writeFileSync(path.join(w, 'nature/deep/d.png'), PNG);
  fs.writeFileSync(path.join(w, 'nature/deep/deeper/deepest/too-deep.png'), PNG);
  fs.writeFileSync(path.join(w, '.hidden/h.png'), PNG);
  fs.symlinkSync(w, path.join(w, 'nature/loop'));
  return {dir, w};
}

function scan(...args) {
  const r = spawnSync('python3', ['-I', scanner, ...args], {encoding: 'utf8'});
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout).sources;
}

const python = spawnSync('python3', ['--version']).status === 0;

test('scanner lists only real PNG/JPEG files, folder by folder, and never loops', {skip: !python}, () => {
  const {dir, w} = tree();
  try {
    const [folder, file, renamed, missing] = scan(w, path.join(w, 'b.png'), path.join(w, 'renamed.jpg'), path.join(dir, 'gone'));
    assert.equal(folder.kind, 'folder');
    assert.deepEqual(folder.groups.map((g) => [path.relative(w, g.dir), g.depth, g.images.map((p) => path.basename(p)), g.total]), [
      ['', 0, ['A.JPG', 'b.png'], 4],
      ['nature', 1, ['c.jpeg'], 2],
      ['nature/deep', 2, ['d.png'], 1],
    ]);
    assert.equal(folder.truncated, true, 'a folder below the depth limit is reported');
    assert.deepEqual(folder.images.map((p) => path.basename(p)), ['A.JPG', 'b.png', 'c.jpeg', 'd.png']);
    assert.deepEqual([file.kind, file.images.length], ['file', 1]);
    assert.equal(renamed.kind, 'unsupported', 'a WebP named .jpg is not an image Ghostty can show');
    assert.equal(missing.kind, 'missing');
    assert.equal(scan(path.join(w, 'photo.webp'))[0].kind, 'unsupported');
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

test('scanner stops at its image budget', {skip: !python}, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-images-many-'));
  try {
    for (let i = 0; i < 405; i++) fs.writeFileSync(path.join(dir, `w${String(i).padStart(3, '0')}.png`), PNG);
    const [s] = scan(dir);
    assert.equal(s.images.length, 400);
    assert.equal(s.truncated, true);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

test('sources are cleaned, capped and parsed defensively', () => {
  assert.deepEqual(plain(P.normalizeImageSources(['/a/', '/a', 'rel', '/b\nc', '/q"', '/', 7, '/c'])), ['/a', '/', '/c']);
  assert.equal(P.normalizeImageSources(Array.from({length: 99}, (_, i) => '/s' + i)).length, P.MAX_IMAGE_SOURCES);
  assert.equal(P.tildePath('/home/u/Pictures', '/home/u'), '~/Pictures');
  assert.equal(P.tildePath('/home/user2/x', '/home/u'), '/home/user2/x');
  assert.equal(P.folderName('/'), '/');
  const parsed = P.parseImageScan(JSON.stringify({sources: [
    {path: '/w', kind: 'folder', images: ['/w/a.png', 'rel.png', '/w/x.gif'], groups: [{dir: '/w', depth: 99, images: ['/w/a.png'], total: -3}]},
    {path: '/odd', kind: 'weird'}]}));
  assert.deepEqual(plain(parsed['/w'].images), ['/w/a.png']);
  assert.deepEqual([parsed['/w'].groups[0].depth, parsed['/w'].groups[0].total], [8, 1]);
  assert.equal(parsed['/odd'].kind, 'missing');
  assert.deepEqual(plain(P.parseImageScan('not json')), {});
  const c = P.parseCatalog('@@PLACE /home/u/Pictures\n@@PLACE relative\n@@PLACE /home/u/Pictures/\n');
  assert.deepEqual(plain(c.places), ['/home/u/Pictures']);
});

test('folding a folder hides its images and every folder inside it', () => {
  const scanned = P.parseImageScan(JSON.stringify({sources: [
    {path: '/w', kind: 'folder', images: ['/w/a.png', '/w/n/b.jpg', '/w/n/d/c.png', '/w/m/e.png'], truncated: false, groups: [
      {dir: '/w', depth: 0, images: ['/w/a.png'], total: 4},
      {dir: '/w/n', depth: 1, images: ['/w/n/b.jpg'], total: 2},
      {dir: '/w/n/d', depth: 2, images: ['/w/n/d/c.png'], total: 1},
      {dir: '/w/m', depth: 1, images: ['/w/m/e.png'], total: 1}]},
    {path: '/x.png', kind: 'file', images: ['/x.png'], groups: []},
    {path: '/gone', kind: 'missing', images: [], groups: []},
    {path: '/empty', kind: 'folder', images: [], groups: [{dir: '/empty', depth: 0, images: [], total: 0}]}]}));
  const sources = ['/w', '/x.png', '/gone', '/empty', '/pending'];
  const keys = (folded, hidden = []) => plain(P.imageSections(['/t.png'], sources, scanned, folded, hidden, false, '/home/u')
    .map((s) => s.key + ':' + s.images.length + (s.collapsed ? ':folded' : '')));
  assert.deepEqual(keys([]), ['@files:1', '/w:1', '/w/n:1', '/w/n/d:1', '/w/m:1', '/gone:0', '/empty:0', '/pending:0', '@builtin:1']);
  assert.deepEqual(keys(['/w/n']), ['@files:1', '/w:1', '/w/n:0:folded', '/w/m:1', '/gone:0', '/empty:0', '/pending:0', '@builtin:1']);
  assert.deepEqual(keys(['/w', '@builtin']), ['@files:1', '/w:0:folded', '/gone:0', '/empty:0', '/pending:0', '@builtin:0:folded']);
  assert.deepEqual(keys([], ['/x.png', '/w/a.png', '/t.png']), ['/w:0', '/w/n:1', '/w/n/d:1', '/w/m:1', '/gone:0', '/empty:0', '/pending:0', '@builtin:0']);
  const all = P.imageSections([], sources, scanned, [], [], false, '/home/u');
  const by = Object.fromEntries(all.map((s) => [s.key, s]));
  assert.equal(by['/w'].count, 4);
  assert.equal(by['/w'].source, '/w');
  assert.equal(by['/w/n'].source, '', 'only the added folder itself can be removed');
  assert.match(by['/gone'].note, /Not found/);
  assert.match(by['/empty'].note, /No PNG or JPEG/);
  assert.match(by['/pending'].note, /Reading/);
  assert.equal(by['@files'].removableImages, true);
  assert.deepEqual(plain(P.visibleImages(P.imageSections([], sources, scanned, ['/w/n'], [], false, ''))), ['/x.png', '/w/a.png', '/w/m/e.png']);
  assert.deepEqual(plain(P.addedImages(['/w', '/x.png', '/w'], scanned)), ['/w/a.png', '/w/n/b.jpg', '/w/n/d/c.png', '/w/m/e.png', '/x.png']);
});

const cliTools = python && spawnSync('jq', ['--version']).status === 0 && spawnSync('realpath', ['--version']).status === 0;

test('images CLI checks files before adding and passes plain absolute paths', {skip: !cliTools}, () => {
  const {dir, w} = tree();
  try {
    const log = path.join(dir, 'calls'), mock = path.join(dir, 'omarchy-shell');
    fs.writeFileSync(mock, `#!/usr/bin/env python3
import json,os,sys
with open(os.environ['OMBRE_TEST_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+"\\n")
print(json.dumps({'imageSources':[{'path':'/w','kind':'folder','count':3}]}) if sys.argv[-2]=='looks' else 'ok')
`);
    fs.chmodSync(mock, 0o755);
    const run = (...args) => spawnSync(path.join(root, 'bin/ombre'), args, {cwd: dir, encoding: 'utf8',
      env: {...process.env, PATH: dir + ':' + process.env.PATH, OMBRE_TEST_CALLS: log}});
    let r = run('images', 'add', 'walls', path.join(w, 'nature'));
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /added .*walls \(4 images\)/);
    assert.match(r.stdout, /added .*nature \(3 images\)/);
    const calls = fs.readFileSync(log, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    assert.deepEqual(calls.map((c) => [c[3], c[4]]), [['addImageSource', w], ['addImageSource', path.join(w, 'nature')]]);
    r = run('images', 'add', path.join(w, 'renamed.jpg'));
    assert.equal(r.status, 1);
    assert.match(r.stderr, /not a PNG or JPEG/);
    r = run('images', 'add', path.join(dir, 'nowhere'));
    assert.equal(r.status, 1);
    assert.match(r.stderr, /was not found/);
    assert.equal(run('images', 'list').stdout, '/w\tfolder\t3\n');
    r = run('images', 'remove', w + '/');
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(fs.readFileSync(log, 'utf8').trim().split('\n').pop()).slice(3), ['removeImageSource', w]);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});
