const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const quickshell = require('./quickshell');
const repo = path.resolve(__dirname, '..');
const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';
test('Stay running renders saved state and sends explicit app changes without losing selection', {skip: !quickshell.available(shell)}, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ombre-running-qt-'));
  try {
    fs.symlinkSync(repo, path.join(dir, 'plugin'));
    fs.writeFileSync(path.join(dir, 'shell.qml'), `
import QtQuick
import Quickshell
import "plugin" as Plugin
ShellRoot {
  Item {
    id: control
    property color text: "#eeeeee"
    property color muted: "#999999"
    property color surface: "#202020"
    property color subtle: "#444444"
    property bool keepRunningBusy: false
    property string keepRunningMessage: ""
    property var requests: []
    property var keepRunningState: ({available:[{id:"one.desktop",name:"One",class:""},{id:"two.desktop",name:"Two",class:""}], apps:[{id:"one.desktop",name:"One",enabled:true,class:"",status:"Running",error:""}],error:""})
    function refreshKeepRunning() {}
    function keepRunningRequest(req) { requests=requests.concat([req]) }
  }
  Plugin.StayRunning { id: panel; width:600; controller:control }
  function check(value, message) { if(!value) throw new Error(message) }
  function find(item, name) {
    if(item.objectName===name) return item
    for(var child of item.children || []) { var found=find(child,name); if(found) return found }
    return null
  }
  Timer {
    interval:300; running:true
    onTriggered: {
      var choice=find(panel,"keepAppChoice")
      check(choice && choice.count===2,"app selector missing")
      choice.currentIndex=1; choice.activated(1)
      control.keepRunningState=JSON.parse(JSON.stringify(control.keepRunningState))
      check(choice.currentValue==="two.desktop","status refresh changed the chosen app")
      find(panel,"keepAdd").clicked()
      check(control.requests[0].id==="two.desktop" && control.requests[0].enabled===true,"add request wrong")
      var toggle=find(panel,"keepToggle-one.desktop")
      check(toggle && toggle.checked,"saved enabled state missing")
      toggle.checked=false; toggle.clicked()
      check(control.requests[1].enabled===false,"disable request wrong")
      find(panel,"keepRemove-one.desktop").clicked()
      check(control.requests[2].op==="remove","remove request wrong")
      console.log("OMBRE_STAY_RUNNING_QT_PASS")
      Qt.quit()
    }
  }
  Timer { interval:5000; running:true; onTriggered:Qt.quit() }
}
`);
    const result=quickshell.run(dir,{XDG_CONFIG_HOME:dir});
    const output=result.stdout+result.stderr;
    assert.equal(result.status,0,output);
    assert.match(output,/OMBRE_STAY_RUNNING_QT_PASS/,output);
    assert.doesNotMatch(output,/Error:|TypeError:|ReferenceError:|Binding loop/,output);
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
