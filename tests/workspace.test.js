const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repo = path.resolve(__dirname, '..');
function moduleFile(file, context) {
  const src = fs.readFileSync(path.join(repo, file), 'utf8').replace(/^\.(?:pragma|import).*$/gm, '');
  const names = [...src.matchAll(/^function (\w+)\(/gm)].map(m => m[1]);
  const out = {};
  vm.runInNewContext(src + '\n' + names.map(n => `out.${n}=${n};`).join('\n'), {...context, out});
  return out;
}
const P = moduleFile('Palette.js', {JSON, Math});
const W = moduleFile('Workspace.js', {Palette:P, JSON, Math});
const plain = value => JSON.parse(JSON.stringify(value));
const term = (id, extras = {}) => ({pid:String(id), pty:`pts/${id}`, address:`a${id}`, title:`Terminal ${id}`, workspace:'1', look:null, wallpaper:null, ...extras});

test('saved looks round-trip complete layers, custom foreground, wallpaper and strength', () => {
  const look = P.foregroundLook(P.tintLook('blue'), '#eeccaa');
  const saved = W.library([{name:'  Deep Ocean  ', look, wallpaper:{path:'/a/ocean.png',strength:0.15}, favorite:true}]);
  assert.equal(saved[0].name, 'Deep Ocean');
  assert.equal(P.lookForeground(saved[0].look), '#eeccaa');
  assert.equal(P.backgroundLook(saved[0].look).id, 'blue');
  assert.deepEqual(plain(W.library(plain(saved))), plain(saved));
});

test('library rejects unsafe values and duplicates without losing valid unusual names', () => {
  const saved = W.library([{name:'constructor',look:null},{name:'__proto__',look:null},
    {name:'Ocean',look:P.tintLook('blue')},{name:'ocean',look:P.tintLook('red')},
    {name:'Bad\nName',look:null},{name:'Unsafe',look:{kind:'theme',id:'bad;command'}},
    {name:'Relative',wallpaper:{path:'x.png'}},{name:'x'.repeat(65)}]);
  assert.deepEqual(plain(saved.map(v => v.name)), ['constructor','__proto__','Ocean']);
  assert.equal(W.find(saved,' OCEAN '),2);
});

test('favourites sort first without mutating the stored order', () => {
  const values = [{name:'Zulu',favorite:false},{name:'Ocean',favorite:true},{name:'Amber',favorite:true}];
  assert.deepEqual(plain(W.sorted(values,false).map(v=>v.name)), ['Amber','Ocean','Zulu']);
  assert.deepEqual(plain(W.sorted(values,true).map(v=>v.name)), ['Amber','Ocean']);
  assert.equal(values[0].name,'Zulu');
});

test('undo and redo isolate terminals and restore complete snapshots', () => {
  const a=term(1), b=term(2), before=W.snapshot(a);
  a.look=P.tintLook('blue'); a.wallpaper={path:'/a.png',strength:0.08};
  let h=W.record({},a,before);
  b.look=P.tintLook('red'); h=W.record(h,b,{look:null,wallpaper:null});
  const u=W.travel(h,a,'undo');
  assert.equal(u.state.look,null); assert.equal(u.state.wallpaper,null);
  assert.equal(u.histories[W.key(b)].past.length,1);
  Object.assign(a,u.state);
  const r=W.travel(u.histories,a,'redo');
  assert.equal(r.state.look.id,'blue'); assert.equal(r.state.wallpaper.strength,0.08);
  assert.equal(r.histories[W.key(a)].future.length,0);
});

test('no-op changes preserve redo; new changes clear it and history is bounded', () => {
  const a=term(1); let h={};
  for(let i=0;i<75;i++) { const old=W.snapshot(a); a.look=P.tintLook(i%2?'red':'blue'); h=W.record(h,a,old); }
  assert.equal(h[W.key(a)].past.length,50);
  const u=W.travel(h,a,'undo'); Object.assign(a,u.state);
  h=W.record(u.histories,a,W.snapshot(a));
  assert.equal(h[W.key(a)].future.length,1);
  const old=W.snapshot(a); a.look=P.tintLook('green'); h=W.record(h,a,old);
  assert.equal(h[W.key(a)].future.length,0);
});

test('reused ptys and changed process identities never inherit previous history', () => {
  const a=term(1), before=W.snapshot(a); a.look=P.tintLook('blue');
  const h=W.record({},a,before), replacement={...a,pid:'999'};
  assert.equal(W.travel(h,replacement,'undo'),null);
  assert.deepEqual(plain(W.prune(h,[replacement])),{});
});

test('search combines title, project and workspace matches while preserving source indices', () => {
  const values=[term(1,{title:'Claude API',root:'/Projects/Urban',workspace:'2'}),
    term(2,{title:'Codex Web',cwd:'/Projects/Urban/site',workspace:'3'}),term(3,{title:'Claude API',root:'/Projects/Other',workspace:'2'})];
  assert.deepEqual(plain(W.filtered(values,'urban CLAUDE','').map(t=>t.sourceIndex)),[0]);
  assert.deepEqual(plain(W.filtered(values,'urban','3').map(t=>t.sourceIndex)),[1]);
  assert.deepEqual(plain(W.filtered(values,'nothing','')),[]);
});

test('batch targeting cannot style hidden selections or an invisible active card', () => {
  const values=[term(1),term(2),term(3)], visible=W.filtered(values,'Terminal 2','');
  assert.deepEqual(plain(W.targets(values,visible,[W.key(values[0]),W.key(values[1])],0)),[1]);
  assert.deepEqual(plain(W.targets(values,visible,[W.key(values[0])],1)),[]);
  assert.deepEqual(plain(W.targets(values,visible,[],0)),[]);
  assert.deepEqual(plain(W.targets(values,visible,[],1)),[1]);
});

test('workspace CLI targeting matches numeric and named workspaces exactly',()=>{
 const values=[term(1,{workspace:'2'}),term(2,{workspace:'20'}),term(3,{workspace:'agents'})];
 assert.deepEqual(plain(P.match(values,'workspace:2').map(t=>t.pid)),['1']);
 assert.deepEqual(plain(P.match(values,'workspace:agents').map(t=>t.pid)),['3']);
});
