import QtQuick

// A section of a card: a heading and something on its right.
Item {
  property string title: ""
  property string note: ""
  property color ink
  property color noteInk
  width: parent.width
  height: sectionTitle.implicitHeight + 4
  HudLabel { id: sectionTitle; y: 4; text: parent.title; color: parent.ink }
  HudLabel { y: 4; anchors.right: parent.right; text: parent.note; color: parent.noteInk; font.bold: false }
}
