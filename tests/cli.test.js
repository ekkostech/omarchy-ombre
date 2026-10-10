const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const cli=path.resolve(__dirname,'../bin/ombre');
const available=spawnSync('jq',['--version']).status===0 && spawnSync('python3',['--version']).status===0;
test('saved look and history CLI safely serializes names, workspace targets and renames', {skip:!available},()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'ombre-cli-test-'));
 try {
  const log=path.join(dir,'calls.json'), mock=path.join(dir,'omarchy-shell');
  fs.writeFileSync(mock,`#!/usr/bin/env python3
import json,os,sys
with open(os.environ['OMBRE_TEST_CALLS'],'w') as f: json.dump(sys.argv[1:],f)
print(json.dumps({'saved':[{'name':'Deep Ocean','favorite':True}]}) if sys.argv[-2]=='looks' else 'ok')
`);fs.chmodSync(mock,0o755);
  function run(args) {
   const r=spawnSync(cli,args,{encoding:'utf8',env:{...process.env,PATH:dir+':'+process.env.PATH,OMBRE_TEST_CALLS:log}});
   assert.equal(r.status,0,r.stdout+r.stderr);return {args:JSON.parse(fs.readFileSync(log)),out:r.stdout};
  }
  let call=run(['save','Ocean $(literal) "name"','--workspace','2']);
  assert.deepEqual(JSON.parse(call.args[4]),{value:'save:Ocean $(literal) "name"',target:'workspace:2'});
  call=run(['look','Deep Ocean','--all']);assert.deepEqual(JSON.parse(call.args[4]),{value:'saved:Deep Ocean',target:'all'});
  call=run(['undo','--title','Claude API']);assert.deepEqual(JSON.parse(call.args[4]),{value:'undo',target:'title:Claude API'});
  call=run(['saved','rename','Deep Ocean','Night Study']);assert.equal(call.args[3],'renameSaved');assert.deepEqual(JSON.parse(call.args[4]),{from:'Deep Ocean',to:'Night Study'});
  assert.match(run(['--saved']).out,/★ Deep Ocean/);
 } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
