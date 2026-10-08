import QtQuick
import qs.Commons
import "Palette.js" as Palette

// A mood or theme drawn in its own colors: its background, its name in its
// text color, and six of its ANSI colors. Themes also show their wallpaper.
Rectangle {
  id: chip

  property var look: null
  property string label: ""
  property string image: ""
  property bool chosen: false
  property color ring: Color.accent
  property color idle: Util.alpha(Color.menu.text, 0.14)
  property string fontFamily: Style.font.menuFamily
  readonly property bool hot: area.containsMouse
  readonly property var palette: look && look.palette ? look.palette : null

  signal hoverStarted()
  signal hoverEnded()
  signal picked()

  width: Style.space(image ? 172 : 128)
  height: Style.space(48)
  radius: Style.cornerRadius
  color: palette ? palette.background : "transparent"
  border.width: Math.max(1, Style.space(chosen || hot ? 2 : 1))
  border.color: chosen ? ring : hot && palette ? palette.foreground : idle
  clip: true

  Image {
    id: thumb
    visible: chip.image !== ""
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.margins: chip.border.width
    width: visible ? Math.round(height * 1.25) : 0
    source: chip.image ? Palette.fileUrl(chip.image) : ""
    sourceSize.height: Math.round(chip.height * 2)
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
  }

  Column {
    anchors.left: thumb.visible ? thumb.right : parent.left
    anchors.leftMargin: Style.space(8)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(5)

    Text {
      width: parent.width
      text: chip.label
      elide: Text.ElideRight
      color: chip.palette ? chip.palette.foreground : Color.menu.text
      font.family: chip.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Row {
      spacing: Style.space(3)

      Repeater {
        model: chip.palette ? chip.palette.colors.slice(1, 7) : []
        delegate: Rectangle {
          required property var modelData
          width: Style.space(10)
          height: width
          radius: Style.space(2)
          color: modelData
        }
      }
    }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: chip.hoverStarted()
    onExited: chip.hoverEnded()
    onClicked: chip.picked()
  }
}
