import QtQuick
import qs.Commons

// A small version of the day tape's data card: a header with a status, a
// scale, a large title, rows of readings, a reticle, scan lines and target
// brackets. It opens like the day tape's, as a target lock, on one timeline
// `t` from 0 to 1: the panel wipes open from the rail, the brackets close in
// and blink, a scan line paints the content while the reticle spins down
// onto the target, and a flash marks the lock.
Item {
  id: hudCard
  required property var bar
  property color ink: bar.hud
  property string head: ""
  property string status: ""
  property color statusInk: ink
  property string title: ""
  property var rows: []
  property bool reticle: true
  default property alias content: hudExtra.data
  property real t: 1
  property real spin: 0
  property real spinFrom: 180
  property int spinMs: 1200
  readonly property real spread: (1 - seg(0.3, 0.6)) * 14
  readonly property real bracketOpacity: t < 0.3 ? 0 : (t > 0.62 && t < 0.66) || (t > 0.7 && t < 0.74) ? 0.15 : 1
  property bool shown: true
  // Faded: no background, only the text and the brackets, outlined to stay
  // readable over whatever is under it.
  property bool faded: false
  // Seeking: the reticle keeps turning, as it does before a lock, until
  // what it waits for comes; then it spins down onto the target.
  // Keys shown in the header, after its label: each one "SUPER + <key>".
  property var keys: []
  property bool seeking: false
  property real seekTurn: 0
  NumberAnimation on seekTurn {
    running: hudCard.seeking && hudCard.visible
    from: 0
    to: 360
    duration: 1400
    loops: Animation.Infinite
  }
  onSeekingChanged: {
    if (seeking) return
    var angle = ((spin * spinFrom + seekTurn) % 360 + 360) % 360
    seekTurn = 0
    // Still opening: its own lock is on the way.
    if (lockAnimation.running) return
    spinFrom = angle < 70 ? angle + 360 : angle
    spinMs = 600 + Math.random() * 600
    spin = 1
    relock.restart()
  }
  NumberAnimation {
    id: relock
    target: hudCard
    property: "spin"
    from: 1
    to: 0
    duration: bar.dur(hudCard.spinMs)
    easing.type: Easing.OutCubic
  }
  property real backdrop: faded ? 0 : 1
  // Back at once when Super is pressed, gently away when it is let go.
  Behavior on backdrop { NumberAnimation { duration: bar.dur(hudCard.faded ? 400 : 90) } }
  property bool clickable: false
  signal closed()
  signal clicked()
  width: 300
  height: hudBody.implicitHeight + 28

  function seg(a, b) {
    var p = Math.max(0, Math.min(1, (t - a) / (b - a)))
    return 1 - Math.pow(1 - p, 3)
  }
  function lock() {
    lockAnimation.stop()
    spinFrom = 70 + Math.random() * 220
    spinMs = 600 + Math.random() * 1200
    t = 0
    spin = 1
    lockAnimation.restart()
  }
  onVisibleChanged: if (visible && shown) lock()
  Component.onCompleted: if (visible && shown) lock()
  // Closing is the opening backwards, then `closed` lets the bar go home.
  onShownChanged: {
    if (shown) {
      closing.stop()
      lock()
    } else {
      lockAnimation.stop()
      closing.restart()
    }
  }

  NumberAnimation {
    id: closing
    target: hudCard
    property: "t"
    to: 0
    duration: bar.dur(140)
    onFinished: hudCard.closed()
  }

  ParallelAnimation {
    id: lockAnimation
    NumberAnimation { target: hudCard; property: "spin"; from: 1; to: 0; duration: bar.dur(hudCard.spinMs) }
    SequentialAnimation {
      NumberAnimation { target: hudCard; property: "t"; to: 0.74; duration: bar.dur(533) }
      PauseAnimation { duration: bar.dur(Math.max(0, hudCard.spinMs - 533)) }
      NumberAnimation { target: hudCard; property: "t"; to: 1; duration: bar.dur(187) }
    }
  }

  Item {
    id: hudWipe
    anchors.right: parent.right
    width: hudCard.width * hudCard.seg(0.1, 0.4)
    height: parent.height
    clip: true

    Item {
      x: hudWipe.width - hudCard.width
      width: hudCard.width
      height: hudCard.height

      Rectangle {
        anchors.fill: parent
        opacity: hudCard.backdrop
        color: bar.hudBlack
        border.width: 1
        border.color: bar.dim
      }
      Image {
        opacity: hudCard.backdrop
        anchors.fill: parent
        fillMode: Image.Tile
        verticalAlignment: Image.AlignTop
        horizontalAlignment: Image.AlignLeft
        source: "data:image/svg+xml," + encodeURIComponent(
          "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'><rect width='4' height='1' fill='"
          + bar.hud + "' fill-opacity='0.07'/></svg>")
      }

      // The content, painted down as the scan line passes.
      Item {
        id: hudPainted
        width: parent.width
        height: parent.height * hudCard.seg(0.35, 0.85)
        clip: true

        Column {
          id: hudBody
          x: 14
          y: 14
          width: hudCard.width - 28
          spacing: 6

          // The header. With keys: the keys that open the desk on the left,
          // Super then a column of the keys that go with it (Caps over 5),
          // and on the right the label over the status. Without: label and
          // status on one line.
          Item {
            id: hudHeader
            readonly property bool keyed: hudCard.keys.length > 0
            width: parent.width
            height: keyed ? Math.max(keysRow.height, headCol.height) : hudHead.implicitHeight

            component KeyCap: Rectangle {
              id: keyCap
              property string label: ""
              width: capLabel.implicitWidth + 14
              height: capLabel.implicitHeight + 6
              radius: 2
              color: hudCard.faded ? "transparent" : Qt.alpha(hudCard.ink, 0.08)
              border.width: 1
              border.color: hudCard.ink
              HudLabel {
                id: capLabel
                anchors.centerIn: parent
                text: keyCap.label
                color: hudCard.ink
                font.pixelSize: 14
                style: hudCard.faded ? Text.Outline : Text.Normal
                styleColor: bar.hudBlack
              }
            }

            Row {
              id: keysRow
              visible: hudHeader.keyed
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              KeyCap { label: "SUPER"; anchors.verticalCenter: parent.verticalCenter }
              HudLabel {
                anchors.verticalCenter: parent.verticalCenter
                text: "+"
                color: bar.dim
                font.pixelSize: 14
                style: hudCard.faded ? Text.Outline : Text.Normal
                styleColor: bar.hudBlack
              }
              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Repeater {
                  model: hudCard.keys
                  // Caps blinks: Super+Caps jumps to this desk, not another.
                  delegate: KeyCap {
                    id: cap
                    required property string modelData
                    label: modelData
                    readonly property bool blinks: modelData === "CAPS"
                    SequentialAnimation on opacity {
                      running: cap.blinks && hudCard.visible && bar.animate
                      loops: Animation.Infinite
                      onRunningChanged: if (!running) cap.opacity = 1
                      NumberAnimation { to: 0.2; duration: 420; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 1; duration: 420; easing.type: Easing.InOutSine }
                    }
                  }
                }
              }
            }

            Column {
              id: headCol
              anchors.right: parent.right
              anchors.verticalCenter: hudHeader.keyed ? parent.verticalCenter : undefined
              spacing: 4
              Item {
                anchors.right: hudHeader.keyed ? parent.right : undefined
                width: hudHeader.keyed ? hudHead.implicitWidth : hudHeader.width
                height: hudHead.implicitHeight
                HudLabel {
                  id: hudHead
                  anchors.right: hudHeader.keyed ? parent.right : undefined
                  text: "◆ " + hudCard.head
                  color: bar.hud
                  style: hudCard.faded ? Text.Outline : Text.Normal
                  styleColor: bar.hudBlack
                }
                HudLabel {
                  visible: !hudHeader.keyed
                  anchors.right: parent.right
                  text: hudStatus.text
                  color: hudStatus.color
                  opacity: hudStatus.opacity
                  style: hudStatus.style
                  styleColor: bar.hudBlack
                }
              }
              HudLabel {
                id: hudStatus
                visible: hudHeader.keyed
                anchors.right: parent.right
                text: hudCard.t < 0.75 ? "ACQUIRING" : hudCard.status
                color: hudCard.t < 0.75 ? bar.bright : hudCard.statusInk
                style: hudCard.faded ? Text.Outline : Text.Normal
                styleColor: bar.hudBlack
                opacity: hudCard.t >= 0.75 || Math.floor(hudCard.t * 24) % 2 ? 1 : 0.3
              }
            }
          }
          Item {
            id: hudScale
            width: parent.width
            height: 5
            Rectangle { width: parent.width; height: 1; color: bar.dim }
            Repeater {
              model: 25
              delegate: Rectangle {
                required property int index
                x: index * (hudScale.width - 1) / 24
                y: 1
                width: 1
                height: index % 4 === 0 ? 4 : 2
                color: bar.dim
              }
            }
          }

          Text {
            visible: hudCard.title !== ""
            width: parent.width - (hudCard.reticle ? 44 : 0)
            text: hudCard.title
            textFormat: Text.PlainText
            color: hudCard.ink
            style: hudCard.faded ? Text.Outline : Text.Normal
            styleColor: bar.hudBlack
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            font.family: Style.fontFamily
            font.pixelSize: 15
            font.bold: true
            font.capitalization: Font.AllUppercase
          }

          Repeater {
            model: hudCard.rows
            delegate: Row {
              required property var modelData
              spacing: 8
              HudLabel { width: 44; text: modelData.k; color: bar.dim }
              HudLabel { text: modelData.v; color: bar.bright; font.bold: false }
            }
          }

          Column {
            id: hudExtra
            width: parent.width
            spacing: 6
          }
        }

        // The reticle spins down onto the target and stops at the lock.
        Item {
          visible: hudCard.reticle
          x: hudCard.width - 14 - width
          // Level with the title, below the keys when they show.
          y: 40 + hudHeader.height - hudHead.implicitHeight
          width: 34
          height: 34
          scale: 1 + (1 - hudCard.seg(0.3, 0.75)) * 0.6

          Item {
            anchors.fill: parent
            rotation: hudCard.spin * hudCard.spinFrom + hudCard.seekTurn

            Rectangle { anchors.fill: parent; anchors.margins: 5; radius: width / 2; color: "transparent"; border.width: 1; border.color: bar.bright }
            Rectangle { x: parent.width / 2; width: 1; height: 9; color: bar.bright }
            Rectangle { x: parent.width / 2; y: parent.height - 9; width: 1; height: 9; color: bar.bright }
            Rectangle { y: parent.height / 2; width: 9; height: 1; color: bar.bright }
            Rectangle { x: parent.width - 9; y: parent.height / 2; width: 9; height: 1; color: bar.bright }
            Rectangle { x: parent.width / 2 - 3; y: 2; width: 7; height: 3; color: bar.bright }
          }
          Rectangle {
            anchors.centerIn: parent
            width: 10
            height: 10
            color: "transparent"
            border.width: 1
            border.color: bar.hud
            rotation: 45 - (hudCard.spin * hudCard.spinFrom + hudCard.seekTurn) * 0.75
          }
          Rectangle { anchors.centerIn: parent; width: 3; height: 3; color: bar.bright }
        }
      }

      // Worn tape: dark lines across everything, text included.
      Image {
        opacity: hudCard.backdrop
        anchors.fill: parent
        fillMode: Image.Tile
        verticalAlignment: Image.AlignTop
        horizontalAlignment: Image.AlignLeft
        source: "data:image/svg+xml," + encodeURIComponent(
          "<svg xmlns='http://www.w3.org/2000/svg' width='3' height='3'><rect width='3' height='1' fill='"
          + bar.hudBlack + "' fill-opacity='0.6'/></svg>")
      }

      // The scan line and its trail.
      Rectangle {
        visible: hudCard.t > 0.35 && hudCard.t < 0.74
        y: hudPainted.height - height
        width: parent.width
        height: 34
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.alpha(bar.hud, 0) }
          GradientStop { position: 1; color: Qt.alpha(bar.hud, 0.4) }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: bar.bright }
      }

      // The flash of the lock.
      Rectangle {
        anchors.fill: parent
        color: bar.bright
        opacity: hudCard.t >= 0.75 ? (1 - hudCard.seg(0.75, 1)) * 0.3 : 0
      }
    }
  }

  // The bright front edge of the wipe.
  Rectangle {
    visible: hudCard.t > 0.1 && hudCard.t < 0.42
    x: hudCard.width - hudWipe.width - 1
    width: 2
    height: parent.height
    color: bar.bright
  }

  HudBracket { ink: bar.bright; x: -4 - hudCard.spread; y: -4 - hudCard.spread; opacity: hudCard.bracketOpacity }
  HudBracket { ink: bar.bright; x: hudCard.width - width + 4 + hudCard.spread; y: -4 - hudCard.spread; onRight: true; opacity: hudCard.bracketOpacity }
  HudBracket { ink: bar.bright; x: -4 - hudCard.spread; y: hudCard.height - height + 4 + hudCard.spread; onBottom: true; opacity: hudCard.bracketOpacity }
  HudBracket { ink: bar.bright; x: hudCard.width - width + 4 + hudCard.spread; y: hudCard.height - height + 4 + hudCard.spread; onRight: true; onBottom: true; opacity: hudCard.bracketOpacity }

  MouseArea {
    visible: hudCard.clickable
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: hudCard.clicked()
  }
}
