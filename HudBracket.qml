import QtQuick

// A corner of a card's target frame.
Item {
  property color ink
  property bool onRight: false
  property bool onBottom: false
  width: 14
  height: 14
  Rectangle { y: parent.onBottom ? parent.height - 2 : 0; width: parent.width; height: 2; color: parent.ink }
  Rectangle { x: parent.onRight ? parent.width - 2 : 0; width: 2; height: parent.height; color: parent.ink }
}
