import QtQuick
import qs.Commons
import "Model.js" as Model

// The body of the battery's card, as in austraz.power: the power chart and
// the busiest apps.
Column {
  id: batteryCard
  required property var bar
  width: parent.width
  spacing: 6

  HudSection {
    ink: bar.hud
    noteInk: bar.dim
    visible: bar.wattHistory.length > 1
    title: bar.batteryMode === "discharging" ? "POWER DRAW" : "CHARGE RATE"
    note: "max " + Model.formatWatts(bar.wattScale.peak)
  }
  PowerChart {
    visible: bar.wattHistory.length > 1
    width: parent.width
    height: 64
    points: bar.wattHistory
    t0: bar.wattWindow.t0
    t1: bar.wattWindow.t1
    wattsMax: bar.wattScale.axis
    lineColor: bar.hud.toString()
    fillColor: Qt.alpha(bar.hud, 0.16).toString()
    gridColor: Qt.alpha(Color.foreground, 0.12).toString()
    fontFamily: Style.fontFamily
  }
  HudSection { ink: bar.hud; noteInk: bar.dim; visible: bar.cpuSegments.length > 0; title: "TOP CPU" }
  Row {
    id: cpuBar
    visible: bar.cpuSegments.length > 0
    width: parent.width
    height: 10
    spacing: 2
    Repeater {
      model: bar.cpuSegments
      delegate: Rectangle {
        required property var modelData
        width: Math.max(2, (cpuBar.width - 2 * (bar.cpuSegments.length - 1)) * modelData.share)
        height: parent.height
        color: modelData.color
      }
    }
  }
  Repeater {
    model: bar.cpuSegments
    delegate: Item {
      id: cpuRow
      required property var modelData
      width: batteryCard.width
      height: 16
      Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; color: cpuRow.modelData.color }
      HudLabel {
        x: 14
        width: parent.width - 70
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: cpuRow.modelData.name + (cpuRow.modelData.pids > 1 ? " ×" + cpuRow.modelData.pids : "")
        color: bar.bright
        font.bold: false
      }
      HudLabel {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(cpuRow.modelData.cpu) + " %"
        color: bar.bright
        font.bold: false
      }
    }
  }
}
