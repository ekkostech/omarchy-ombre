const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const quickshell = require('./quickshell');
const repo = path.resolve(__dirname, '..');
const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';

test('session scanner, labels, independent project rules, styles and jump use stable identities', {skip:!quickshell.available(shell)}, () => {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'ombre-sessions-qt-'));
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
 function check(ok,msg) { if(!ok) throw new Error(msg) }
 Plugin.Ombre {
  id: picker
  manifest: ({id:"ekkostech.ombre",version:"2.1.0"})
  welcomed: true
  solid: false
  property var sent: []
  function scan() {}
  function sessionAction(req) { sent=sent.concat([req]) }
  function saveConfig() {}
  property var writes: []
  function send(line) { writes=writes.concat([line]) }
  function paintBorder(term,look) {}
  function checkAgentThemes(action) {}
 }
 Timer {
  interval:300; running:true
  onTriggered: {
   var a={sessionId:"server:1:pane0",pid:"10",pty:"pts/100",address:"",title:"one",label:"",backend:"tmux",command:"node",cwd:"/project/a",root:"/project/a",workspace:"",look:null,wallpaper:null,wallpaperReady:false,visible:false,w:16,h:9,clientPtys:[]}
   var b=Object.assign({},a,{sessionId:"server:1:pane1",pid:"11",pty:"pts/101",title:"two",cwd:"/project/b",root:"/project/b"})
   var scan='[]\\n@@PS@@\\n\\n@@STATE@@\\n\\n@@GHOSTTY@@\\n\\n@@MONITORS@@\\n[]\\n@@CWD@@\\n\\n@@SESSIONS@@\\n'+JSON.stringify({sessions:[a,b],starts:{}})
   var parsed=picker.parseScan(scan)
   check(parsed.length===2,"session marker parsing failed")
   picker.terminals=parsed; picker.current=0
   picker.sent=[]; picker.writes=[]
   picker.labelSession("API")
   check(picker.selectedTerm.label==="API" && picker.sent[0].op==="label","label not targeted")
   picker.searchText="API node"
   check(picker.filteredTerminals.length===1,"label/command search failed")
   picker.searchText=""
   picker.projects=[{path:"/project/a",look:Palette.tintLook("blue"),wallpaper:null},{path:"/project/b",look:Palette.tintLook("red"),wallpaper:null}]
   picker.applyProjects(picker.terminals)
   check(Palette.backgroundLook(picker.terminals[0].look).id==="blue" && Palette.backgroundLook(picker.terminals[1].look).id==="red","empty addresses collapsed project identities")
   check(picker.sent.some(function(r){return r.op==="style" && r.sessionId===b.sessionId && r.persist}),"style not saved per session")
   picker.current=1; picker.jumpSession()
   check(picker.sent[picker.sent.length-1].op==="focus" && picker.sent[picker.sent.length-1].sessionId===b.sessionId,"jump wrong session")
   var c=Object.assign({},a,{sessionId:"",address:"abc",started:"1234"})
   picker.terminals=[c];picker.current=0;picker.labelSession("Local")
   check(picker.sessionLabels[Workspace.key(c)]==="Local","window label not persisted")
   check(Workspace.key(c)!==Workspace.key(Object.assign({},c,{started:"9999"})),"reused process inherits identity")
   check(picker.writes.length===0,"ordinary pane styling wrote to host")
   var host={pid:"999",pty:"pts/90",confDir:"/tmp/ghostty/",wallpaperReady:true,look:null}
   var attached=Object.assign({},a,{wallpaperReady:true,wallpaperHosts:[host],wallpaper:{path:"/tmp/image.png",strength:0.4,blur:8}})
   picker.sendWallpaper(attached,attached.wallpaper)
   check(picker.writes[0].indexOf("ghostty 999 /tmp/ghostty/ ")===0,"wallpaper did not target host process")
   check(picker.writes[0].indexOf("0.4 8 /tmp/image.png")>0,"wallpaper controls lost")
   picker.persist(attached)
   check(picker.writes.some(function(line){return line.indexOf("save pts/90 ")===0}),"host wallpaper not persisted")
   check(!picker.sent.some(function(req){return req.op==="wallpaper"}),"ordinary tmux sent Omaguake action")
   picker.sendWallpaper(attached,null)
   check(picker.writes[picker.writes.length-1].endsWith("- 0 -"),"reset not forwarded")
   picker.projects=[]
   picker.terminals=[Object.assign({},attached,{title:"Matrix host"}),b];picker.current=0;picker.searchText="";picker.workspaceOnly=false;picker.markedKeys=[]
   picker.setMatrix({on:true,size:28,blur:3,opacity:0.4})
   check(picker.matrixFor(picker.terminals[0]).size===28,"Matrix setting not scoped to host")
   check(!picker.matrixFor(b).on,"Matrix changed unrelated terminal")
   check(picker.renderToken(host).indexOf("matrix:28:3:0.4")===0,"Matrix render token lost controls")
   picker.travelBatch(false)
   check(!picker.matrixFor(picker.terminals[0]).on,"batch undo lost Matrix state")
   picker.travelBatch(true)
   check(picker.matrixFor(picker.terminals[0]).on,"batch redo lost Matrix state")
   picker.saveNamedLook("Matrix test")
   check(picker.savedLooks.some(function(s){return s.name==="Matrix test" && s.matrix && s.matrix.on}),"saved look lost Matrix")
   picker.saveScene("Test scene")
   check(picker.scenes.length===1 && picker.scenes[0].entries[0].state.matrix.on,"scene lost effects")
   picker.deleteScene("Test scene")
   picker.togglePrivacy();check(picker.privacyKeys.length===1,"privacy target missing")
   picker.togglePrivacy();check(picker.privacyKeys.length===0,"privacy did not restore")
   var movedHost=Object.assign({},host,{pid:"1000",pty:"pts/91"})
   var moving=Object.assign({},picker.terminals[0],{displayed:true,profile:picker.styleState(picker.terminals[0]),wallpaperHosts:[movedHost]})
   picker.terminals=[moving,b]
   picker.followProfiles(picker.terminals)
   check(picker.matrixFor(movedHost).on && picker.matrixFor(movedHost).size===28,"session profile did not follow to a new host")
   check(!picker.matrixFor(b).on,"following changed an unrelated session")
   console.log("OMBRE_SESSIONS_QT_PASS")
   Qt.quit()
  }
 }
}
`);
  const run=quickshell.run(dir);
  const log=run.stdout+run.stderr;
  assert.equal(run.status,0,log);
  assert.match(log,/OMBRE_SESSIONS_QT_PASS/);
  assert.doesNotMatch(log,/Error:|TypeError:|ReferenceError:|Binding loop/);
 } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});
