import QtQuick
import qs.Commons

// A text that types itself out, a word every 45 ms within 1.6 s, as the day
// tape's card does: the cursor sits still while typing, then blinks a while.
Text {
  id: typedText
  required property var bar
  property string full: ""
  property real typed: 0
  property bool cursorOn: true
  readonly property var words: full.match(/\S+/g) || []
  readonly property int count: words.length
  readonly property bool done: Math.floor(typed) >= count
  visible: full !== ""
  textFormat: Text.PlainText
  wrapMode: Text.Wrap
  font.family: Style.fontFamily
  text: {
    var left = Math.floor(typed), re = /\S+/g, end = 0
    while (left-- > 0 && re.exec(full)) end = re.lastIndex
    var out = full.slice(0, end)
    return showCursor && cursorOn ? out + " █" : out
  }
  // Blinks for three seconds once typed, then goes.
  property bool showCursor: false
  // The word count is taken here: `count` may not have caught up yet.
  function start() {
    typing.stop()
    var n = (full.match(/\S+/g) || []).length
    typed = 0
    showCursor = n > 0
    cursorOn = true
    if (!n) return
    typing.to = n
    typing.duration = bar.dur(Math.min(1600, n * 45))
    typing.restart()
  }
  onFullChanged: start()
  Component.onCompleted: start()
  NumberAnimation {
    id: typing
    target: typedText
    property: "typed"
    from: 0
    onFinished: cursorEnd.restart()
  }
  Timer {
    interval: 450
    repeat: true
    running: typedText.showCursor && typedText.done
    onRunningChanged: typedText.cursorOn = true
    onTriggered: typedText.cursorOn = !typedText.cursorOn
  }
  Timer { id: cursorEnd; interval: 3000; onTriggered: typedText.showCursor = false }
}
