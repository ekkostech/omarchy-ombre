const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const repo = path.resolve(__dirname,'..');
const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';
const available = fs.existsSync(path.join(shell,'shell/Commons')) && spawnSync('quickshell',['--version']).status===0;
test('real picker library, batch scope, filtering and atomic undo/redo work together', {skip:!available}, () => {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'ombre-workspace-test-'));
 try {
  fs.symlinkSync(repo,path.join(dir,'plugin'));
  for(const n of ['Commons','Ui','services']) fs.symlinkSync(path.join(shell,'shell',n),path.join(dir,n));
  fs.writeFileSync(path.join(dir,'shell.qml'), `
import QtQuick
import Quickshell
import "plugin" as Plugin
import "plugin/Palette.js" as Palette
import "plugin/Workspace.js" as Workspace
ShellRoot {
 function check(ok,message) { if(!ok) throw new Error(message) }
 Plugin.Ombre {
  id: picker
  manifest: ({id:"ekkostech.ombre",version:"1.5.0"})
  welcomed: true
  solid: false
  function scan() {}
  function parseScan(output) { return JSON.parse(output) }
  function reapply() {}
  function loadCatalog() { catalogLoaded=true }
  function saveConfig() {}
  function send(line) {}
  function persist(term) {}
  function paintBorder(term,look) {}
  function checkAgentThemes(action) {}
 }
 Timer {
  interval:300; running:true
  onTriggered: {
   var a={pid:"123",pty:"pts/1",address:"a1",title:"API",workspace:"1",look:null,wallpaper:null,wallpaperReady:true,confDir:"/rt/ghostty/",visible:true,w:900,h:600}
   var b={pid:"456",pty:"pts/2",address:"b2",title:"Web",workspace:"2",look:null,wallpaper:null,wallpaperReady:false,visible:true,w:900,h:600}
   var fire={kind:"mood",id:"fire",source:"/fire.png",palette:Palette.themePalette({background:"#321000",foreground:"#ffcc99",accent:"#ff5500"})}
   picker.terminals=[a,b]; picker.current=0
   picker.commitWithWallpaper(0,fire)
   check(picker.histories[Workspace.key(a)].past.length===1,"combined palette/wallpaper created multiple undo steps")
   check(picker.terminals[0].wallpaper.path==="/fire.png","mood wallpaper missing")
   picker.travelHistory(0,"undo")
   check(picker.terminals[0].look===null && picker.terminals[0].wallpaper===null,"undo did not restore both layers and wallpaper")
   picker.travelHistory(0,"redo")
   check(picker.terminals[0].look.id==="fire" && picker.terminals[0].wallpaper.path==="/fire.png","redo incomplete")
   var count=picker.histories[Workspace.key(a)].past.length
   picker.preview(0,Palette.tintLook("blue")); picker.endPreview()
   check(picker.histories[Workspace.key(a)].past.length===count,"hover polluted history")
   check(picker.saveNamedLook("Warm API"),"save failed")
   picker.favoriteNamedLook("Warm API")
   var saved=JSON.stringify({savedLooks:picker.savedLooks,welcomed:true})
   picker.savedLooks=[]; picker.onConfig(saved)
   check(picker.savedLooks.length===1 && picker.favoriteLooks.length===1,"library reload lost favourite")
   picker.markedKeys=[Workspace.key(a),Workspace.key(b)]
   picker.applySavedTargets(picker.savedLooks[0])
   check(picker.terminals[1].look.id==="fire" && picker.terminals[1].wallpaper===null,"mixed batch did not apply colours safely")
   picker.setLayerColor("text","#ffeecc")
   check(Palette.lookForeground(picker.terminals[0].look)==="#ffeecc" && Palette.lookForeground(picker.terminals[1].look)==="#ffeecc","text batch failed")
   picker.searchText="web"
   check(picker.markedKeys.length===0 && picker.current===1 && picker.actionTargets[0]===1,"filter selection was not reset")
   picker.markedKeys=[Workspace.key(a)]
   var previous=JSON.stringify(Workspace.snapshot(picker.terminals[0])); var other=JSON.stringify(Workspace.snapshot(picker.terminals[1]))
   picker.applyTintTargets("blue")
   check(JSON.stringify(Workspace.snapshot(picker.terminals[0]))===previous && JSON.stringify(Workspace.snapshot(picker.terminals[1]))===other,"hidden selection leaked to current target")
   picker.searchText=""; picker.current=1
   var reversed=[picker.terminals[1],picker.terminals[0]]
   picker.onScan(JSON.stringify(reversed))
   check(picker.selectedTerm.pid==="456","scan reorder moved active selection")
   picker.applySaved(0,{look:Palette.tintLook("blue"),wallpaper:null},"all")
   check(Palette.lookForeground(picker.terminals[0].look)==="","complete saved tint kept stale text override")
   check(picker.renameNamedLook("Warm API","Fire favourite"),"rename failed")
   check(picker.favoriteLooks[0].name==="Fire favourite","rename lost favourite")
   console.log("OMBRE_WORKSPACE_QT_PASS")
   Qt.quit()
  }
 }
 Timer { interval:5000; running:true; onTriggered:Qt.quit() }
}
`);
  const result=spawnSync('quickshell',['-p',dir],{encoding:'utf8',timeout:10000,env:{...process.env,XDG_CONFIG_HOME:dir}});
  const output=result.stdout+result.stderr;
  assert.equal(result.status,0,output);
  assert.match(output,/OMBRE_WORKSPACE_QT_PASS/,output);
  assert.doesNotMatch(output,/Error:|TypeError:|ReferenceError:|Binding loop/,output);
 } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});

test('saved library persists rapid edits and loads alongside existing settings after restart', {skip:!available},()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'ombre-library-test-'));
 try {
  fs.symlinkSync(repo,path.join(dir,'plugin'));
  for(const n of ['Commons','Ui','services']) fs.symlinkSync(path.join(shell,'shell',n),path.join(dir,n));
  fs.mkdirSync(path.join(dir,'omarchy'));
  const config=path.join(dir,'omarchy/ombre.json');
  fs.writeFileSync(config,JSON.stringify({welcomed:true,pulse:false,newTerminals:{mode:'auto'},projects:[{path:'/Projects/demo',look:null,wallpaper:null}]}));
  function run(body) {
   fs.writeFileSync(path.join(dir,'shell.qml'),`
import QtQuick
import Quickshell
import "plugin" as Plugin
import "plugin/Palette.js" as Palette
ShellRoot {
 Plugin.Ombre {
  id: picker
  welcomed:true
  function scan() {}
  function reapply() {}
  function loadCatalog() { catalogLoaded=true }
  function send(line) {}
  function persist(term) {}
  function paintBorder(term,look) {}
  function checkAgentThemes(action) {}
 }
 Timer { interval:300; running:true; onTriggered:{ ${body} } }
 Timer { interval:1000; running:true; onTriggered:Qt.quit() }
}
`);
   const result=spawnSync('quickshell',['-p',dir],{encoding:'utf8',timeout:10000,env:{...process.env,XDG_CONFIG_HOME:dir}});
   assert.equal(result.status,0,result.stdout+result.stderr);
   assert.doesNotMatch(result.stdout+result.stderr,/Error:|TypeError:|ReferenceError:|Binding loop/);
   return result.stdout+result.stderr;
  }
  run(`picker.terminals=[{pid:"123",pty:"pts/1",address:"a1",title:"demo",workspace:"1",look:Palette.tintLook("blue"),wallpaper:{path:"/demo/ocean.png",strength:0.15},wallpaperReady:true}];picker.current=0;picker.saveNamedLook("Ocean");picker.favoriteNamedLook("Ocean");picker.renameNamedLook("Ocean","Deep Ocean");`);
  const stored=JSON.parse(fs.readFileSync(config));
  assert.equal(stored.savedLooks[0].name,'Deep Ocean');assert.equal(stored.savedLooks[0].favorite,true);
  assert.equal(stored.savedLooks[0].wallpaper.strength,0.15);
  assert.equal(stored.pulse,false);assert.equal(stored.newTerminals.mode,'auto');assert.equal(stored.projects[0].path,'/Projects/demo');
  assert.equal(fs.statSync(config).mode & 0o777,0o600);
  assert.match(run(`if(picker.savedLooks.length!==1||picker.savedLooks[0].name!=="Deep Ocean"||!picker.savedLooks[0].favorite||picker.savedLooks[0].wallpaper.strength!==0.15)throw new Error("library reload failed");console.log("OMBRE_LIBRARY_RELOAD_PASS");Qt.quit();`),/OMBRE_LIBRARY_RELOAD_PASS/);
 } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
