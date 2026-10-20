import QtQuick
import QtQuick.Controls as C

Column {
  id: panel
  required property var controller
  spacing: 14
  property string selectedAppId: ""
  onChoicesChanged: {
    if (!appChoice) return
    var index = choices.findIndex(function(app) { return app.id === panel.selectedAppId })
    appChoice.currentIndex = index >= 0 ? index : choices.length ? 0 : -1
    selectedAppId = appChoice.currentIndex >= 0 ? choices[appChoice.currentIndex].id : ""
  }
  readonly property var choices: controller.keepRunningState.available.filter(function(app) {
    return (app.name + " " + app.id).toLowerCase().indexOf(search.text.toLowerCase()) >= 0
  })
  onVisibleChanged: if (visible) controller.refreshKeepRunning()
  Component.onCompleted: if (visible) controller.refreshKeepRunning()
  Timer { interval: 3000; repeat: true; running: panel.visible; onTriggered: panel.controller.refreshKeepRunning() }
  Text { text: "Stay running"; color: panel.controller.text; font.pixelSize: 22; font.bold: true }
  Text {
    width: parent.width; wrapMode: Text.WordWrap; color: panel.controller.muted
    text: "Start selected apps when you log in and reopen them if they exit. Existing instances are left alone. Ombre must be enabled in your desktop session."
  }
  C.TextField { id: search; width: parent.width; placeholderText: "Find an installed app…"; Accessible.name: "Find an installed app" }
  C.ComboBox {
    id: appChoice; objectName: "keepAppChoice"; width: parent.width; model: panel.choices; textRole: "name"; valueRole: "id"
    onActivated: { panel.selectedAppId = currentValue; windowClass.text = "" }
    displayText: count ? currentText : "No matching apps"
    Accessible.name: "Application to keep running"
  }
  C.TextField {
    id: windowClass; width: parent.width
    placeholderText: "Window class override (optional)"; Accessible.name: "Window class override"
  }
  Text {
    width: parent.width; wrapMode: Text.WordWrap; color: panel.controller.muted; font.pixelSize: 12
    text: "Usually leave the override empty. Use an exact Hyprland window class for apps with a shared launcher. Terminal jobs and conversations are not recreated."
  }
  C.Button {
    objectName: "keepAdd"
    text: "Add and keep running"; enabled: appChoice.count > 0 && !panel.controller.keepRunningBusy
    onClicked: panel.controller.keepRunningRequest({op:"set", id:appChoice.currentValue, enabled:true, class:windowClass.text})
  }
  Text {
    width: parent.width; wrapMode: Text.WordWrap; color: panel.controller.muted
    visible: panel.controller.keepRunningState.apps.length === 0
    text: "No apps selected yet. Choose an app above to enable it."
  }
  Repeater {
    model: panel.controller.keepRunningState.apps
    delegate: Rectangle {
      id: appRow
      required property var modelData
      width: panel.width; height: contents.implicitHeight + 24; radius: 6
      color: panel.controller.surface; border.color: panel.controller.subtle
      Column {
        id: contents; anchors.left: parent.left; anchors.right: parent.right
        anchors.top: parent.top; anchors.margins: 12; spacing: 6
        Flow {
          width: parent.width; spacing: 10
          C.Switch {
            objectName: "keepToggle-" + appRow.modelData.id
            checked: appRow.modelData.enabled; text: appRow.modelData.name
            enabled: !panel.controller.keepRunningBusy
            onClicked: panel.controller.keepRunningRequest({op:"set",id:appRow.modelData.id,enabled:checked,class:appRow.modelData.class})
          }
          C.Button {
            objectName: "keepRemove-" + appRow.modelData.id
            text: "Remove"; enabled: !panel.controller.keepRunningBusy
            onClicked: panel.controller.keepRunningRequest({op:"remove",id:appRow.modelData.id})
          }
        }
        Text { width: parent.width; wrapMode: Text.WordWrap; text: appRow.modelData.status; color: panel.controller.text }
        Text { width: parent.width; wrapMode: Text.WordWrap; text: appRow.modelData.error; visible: text.length > 0; color: panel.controller.muted }
      }
    }
  }
  Text {
    width: parent.width; wrapMode: Text.WordWrap; color: panel.controller.muted
    text: "Turning a switch off or removing an entry leaves the app open. Failed starts retry with increasing delays, up to ten minutes. Nothing launches while the desktop is unavailable."
  }
  Text { width: parent.width; wrapMode: Text.WordWrap; color: panel.controller.muted; text: panel.controller.keepRunningMessage || panel.controller.keepRunningState.error }
}
