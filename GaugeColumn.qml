import QtQuick
import qs.Commons

// One limit on Claude's card, in the colour of its gauge.
Column {
  required property var bar
  property var gauge: ({ known: false })
  property string name: ""
  readonly property color ink: bar.gaugeInk(gauge)
  width: (272 - 16) / 2
  spacing: 4

  HudLabel { text: parent.name; color: parent.ink }
  Text {
    text: parent.gauge.known ? Math.round(parent.gauge.used * 100) + " % → " + Math.round(parent.gauge.forecast * 100) + " %" : "—"
    textFormat: Text.PlainText
    color: parent.ink
    font.family: Style.fontFamily
    font.pixelSize: 15
    font.bold: true
  }
  Repeater {
    model: bar.gaugeRows(parent.gauge)
    delegate: Row {
      required property var modelData
      spacing: 6
      HudLabel { width: 40; text: modelData.k; color: bar.dim }
      HudLabel { text: modelData.v; color: bar.bright; font.bold: false }
    }
  }
}
