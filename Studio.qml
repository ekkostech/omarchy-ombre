import QtQuick
import QtQuick.Controls as C
import qs.Commons
Item {
  id: studio
  required property var controller
  C.ScrollView {
    anchors.fill: parent
    clip: true
    Column {
      width: studio.width - 24
      spacing: 14
      Text { text: "Session studio"; color: studio.controller.text; font.pixelSize: 22 }
      Text { text: studio.controller.selectedTerm ? "Selected: " + studio.controller.selectedTerm.title : "Select a terminal first"; color: studio.controller.muted; width: parent.width; elide: Text.ElideRight }
      Flow {
        width: parent.width; spacing: 8
        C.Button { text: "Back to styling"; onClicked: studio.controller.view="style" }
        C.Button { text: studio.controller.focusMode ? "Exit focus mode" : "Focus mode"; onClicked: studio.controller.focusMode=!studio.controller.focusMode }
        C.Button { text: "Privacy curtain"; onClicked: studio.controller.togglePrivacy() }
        C.Button { text: "Reveal all"; onClicked: studio.controller.clearPrivacy() }
        C.Button { text: "Readable Glass"; onClicked: studio.controller.readableGlass() }
        C.Button { text: "Undo batch"; enabled: studio.controller.batchPast.length>0; onClicked: studio.controller.travelBatch(false) }
        C.Button { text: "Hold to compare"; enabled:studio.controller.batchPast.length>0; onPressed:studio.controller.comparePrevious(true);onReleased:studio.controller.comparePrevious(false);onCanceled:studio.controller.comparePrevious(false) }
        C.Button { text: "Redo batch"; enabled: studio.controller.batchFuture.length>0; onClicked: studio.controller.travelBatch(true) }
      }
      Row {
        spacing: 12
        C.CheckBox { text: "Looks follow tmux sessions"; checked: studio.controller.followSessions; onClicked: {studio.controller.followSessions=checked;studio.controller.saveConfig()} }
        C.Button { text: "Jump to next signal"; onClicked: studio.controller.jumpSignal() }
      }
      Text { text: "Matrix rain"; color: studio.controller.text; font.pixelSize: 18 }
      Text { text: "Ghostty windows and their tmux sessions. Each host window has its own controls."; color: studio.controller.muted }
      Row {
        spacing: 12
        C.CheckBox { text: "Enabled"; checked: studio.controller.selectedMatrix.on; onClicked: studio.controller.setMatrix({on:checked}) }
        C.CheckBox { text: "Paused"; checked: studio.controller.selectedMatrix.paused; onClicked: studio.controller.setMatrix({paused:checked}) }
      }
      Repeater {
        model: [{key:"size",title:"Character size",min:8,max:64,step:1},
                {key:"blur",title:"Blur",min:0,max:12,step:0.5},
                {key:"opacity",title:"Opacity",min:0,max:1,step:0.01},
                {key:"speed",title:"Speed",min:0.1,max:4,step:0.1},
                {key:"density",title:"Density",min:0.05,max:1,step:0.05}]
        delegate: Row {
          required property var modelData
          spacing: 12
          Text { width: 130; anchors.verticalCenter: parent.verticalCenter; text: modelData.title; color: studio.controller.text }
          C.Slider {
            id: slider; width: 300; from: modelData.min; to: modelData.max; stepSize: modelData.step
            value: studio.controller.selectedMatrix[modelData.key]
            onPressedChanged: if (!pressed) {var patch={};patch[modelData.key]=value;studio.controller.setMatrix(patch)}
          }
          Text { anchors.verticalCenter: parent.verticalCenter; text: Number(slider.value).toFixed(2); color: studio.controller.muted }
        }
      }
      Text { text: "Project scenes"; color: studio.controller.text; font.pixelSize: 18 }
      Row {
        spacing: 8
        C.TextField { id: sceneName; placeholderText: "Scene name"; width: 240 }
        C.Button { text: "Save visible sessions"; onClicked: studio.controller.saveScene(sceneName.text) }
      }
      Repeater {
        model: studio.controller.scenes
        delegate: Row {
          required property var modelData
          spacing: 8
          Text { width: 240; anchors.verticalCenter: parent.verticalCenter; text: modelData.name+" · "+modelData.entries.length+" sessions"; color: studio.controller.text }
          C.Button { text: "Restore"; onClicked: studio.controller.restoreScene(modelData.name) }
          C.Button { text: "Delete"; onClicked: studio.controller.deleteScene(modelData.name) }
        }
      }
      Text { text: "Session map"; color: studio.controller.text; font.pixelSize: 18 }
      Repeater {
        model: studio.controller.terminals
        delegate: Rectangle {
          required property var modelData
          width: studio.width-24; height: 72; radius: 5
          color: studio.controller.surface
          border.color: studio.controller.subtle
          Column {
            anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
            width: parent.width-150
            Text { width:parent.width; elide:Text.ElideRight; text: (modelData.label || modelData.title)+" · "+studio.controller.signalFor(modelData);color:studio.controller.text }
            Text { width:parent.width; elide:Text.ElideMiddle; text: (modelData.root || modelData.cwd || "")+" · workspace "+(modelData.workspace || "detached");color:studio.controller.muted }
          }
          C.Button { anchors.right:parent.right;anchors.rightMargin:8;anchors.verticalCenter:parent.verticalCenter;text:"Select / Jump";onClicked:studio.controller.selectSession(modelData) }
        }
      }
      Text { width: parent.width; color:studio.controller.muted; text:"Ghostty privacy hides the rendered window too. Other terminal types use a desktop curtain that individual-app sharing may bypass.";wrapMode:Text.WordWrap }
      Text { width: parent.width; wrapMode: Text.WordWrap; text: studio.controller.studioMessage+"\n"+studio.controller.sessionMessage; color: studio.controller.muted }
    }
  }
}
