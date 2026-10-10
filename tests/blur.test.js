const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const available = spawnSync('python3', ['-c', 'import PIL']).status === 0;
test('blur renders privately, caches by source and amount, resets and preserves config on failure', {skip: !available}, () => {
 const qml = fs.readFileSync(path.join(root, 'Ombre.qml'), 'utf8');
 const expression = qml.split('readonly property string writerScript:')[1].split('\n\n  Process {')[0];
 const writer = vm.runInNewContext(expression);
 const result = spawnSync('python3', ['-c', String.raw`
import ctypes, hashlib, json, os, pathlib, runpy, signal, subprocess, sys, tempfile, time
from PIL import Image, ImageStat
payload=json.load(sys.stdin)
root=pathlib.Path(payload['root'])
render=runpy.run_path(str(root/'bin/ombre-blur'))['render']
with tempfile.TemporaryDirectory(prefix='ombre-blur-test-') as folder:
 d=pathlib.Path(folder); cache=d/'cache'; source=d/'wallpaper with spaces.png'
 image=Image.new('RGB',(192,128))
 image.putdata([(255,255,255) if (x//4+y//4)%2 else (0,0,0) for y in range(128) for x in range(192)])
 image.save(source); original=source.read_bytes()
 assert render(str(source),0,cache)==str(source)
 target=pathlib.Path(render(str(source),20,cache))
 assert target.parent==cache and target!=source
 assert ImageStat.Stat(Image.open(target).convert('RGB')).var[0]<ImageStat.Stat(image).var[0]
 assert source.read_bytes()==original
 assert target.stat().st_mode & 0o777 == 0o600
 assert cache.stat().st_mode & 0o777 == 0o700
 stamp=target.stat().st_mtime_ns
 assert render(str(source),20,cache)==str(target) and target.stat().st_mtime_ns==stamp
 assert render(str(source),30,cache)!=str(target)
 image.putpixel((0,0),(120,120,120)); image.save(source)
 assert render(str(source),20,cache)!=str(target)
 for amount in (-1,41,float('nan'),float('inf')):
  try: render(str(source),amount,cache)
  except ValueError: pass
  else: raise AssertionError('accepted invalid amount')
 target=pathlib.Path(render(str(source),20,cache)); target.unlink(); target.symlink_to(source)
 try: render(str(source),20,cache)
 except ValueError: pass
 else: raise AssertionError('accepted cache symlink')
 target.unlink()
 # An isolated dummy process receives reload signals; no live terminal is touched.
 child=subprocess.Popen([sys.executable,'-u','-c',"import ctypes,signal,time; ctypes.CDLL(None).prctl(15,b'ghostty',0,0,0); signal.signal(signal.SIGUSR2,lambda *a:None); print('ready',flush=True); time.sleep(30)"],stdout=subprocess.PIPE,text=True)
 try:
  assert child.stdout.readline().strip()=='ready'
  cdir=d/'runtime'/'ghostty'; cdir.mkdir(parents=True)
  config=cdir/(str(child.pid)+'.conf')
  env=dict(os.environ,XDG_CACHE_HOME=str(d/'writer-cache'))
  def write(amount, sourcepath):
   line=f'ghostty {child.pid} {cdir}/ - - 0.15 {amount} {sourcepath}\n'
   return subprocess.run(['sh','-c',payload['writer'],'sh',str(d/'runtime'),str(root)],input=line,text=True,capture_output=True,env=env,check=True)
  assert 'wallpaper-ok' in write(16,source).stdout
  blurred=config.read_text(); assert 'wallpaper-blur/' in blurred and 'background-image-opacity = 0.15' in blurred
  assert 'wallpaper-error' in write(20,d/'missing.png').stdout
  assert config.read_text()==blurred
  assert 'wallpaper-ok' in write(0,source).stdout
  assert str(source) in config.read_text() and 'wallpaper-blur/' not in config.read_text()
 finally:
  child.terminate(); child.wait()
print('image rendering, cache, reset, and writer failure checks passed')
`], {input: JSON.stringify({root, writer}), encoding:'utf8'});
 assert.equal(result.status, 0, result.stdout + result.stderr);
});
