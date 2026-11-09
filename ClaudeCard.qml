import QtQuick
import qs.Commons
import "Model.js" as Model

// The body of Claude's card: both limits, Fable on the left and the week on
// the right, their reset, then the last 90 days and tokens by day, as in My
// Agents.
Column {
  id: claudeCard
  required property var bar
  width: parent.width
  spacing: 6

  Row {
    spacing: 16
    GaugeColumn { bar: claudeCard.bar; name: "FABLE"; gauge: bar.gauges[1] || ({ known: false }) }
    GaugeColumn { bar: claudeCard.bar; name: "WEEKLY"; gauge: bar.gauges[0] || ({ known: false }) }
  }
  Row {
    visible: bar.resetText !== ""
    spacing: 8
    HudLabel { width: 44; text: "RESET"; color: bar.dim }
    HudLabel { text: bar.resetText; color: bar.bright; font.bold: false }
  }

  Column {
    id: aiGraphs
    readonly property var bars: Model.historyBars(bar.usageHistory, 90, bar.now.getTime())
    readonly property real peak: Math.max(1, bars.reduce(function(m, b) { return Math.max(m, b.tokens) }, 0))
    readonly property real total: bars.reduce(function(sum, b) { return sum + b.tokens }, 0)
    readonly property real dayPeak: Math.max(1, bar.usageRecent.reduce(function(m, d) { return Math.max(m, Number(d.messageCount) || 0) }, 0))
    readonly property string todayIso: Model.isoDay(bar.now)
    width: parent.width
    spacing: 4

    HudSection { ink: bar.hud; noteInk: bar.dim; title: "LAST 90 DAYS"; note: "total " + Model.tokenText(aiGraphs.total) }
    Item {
      id: historyPlot
      width: parent.width
      height: 48
      Repeater {
        model: aiGraphs.bars
        delegate: Rectangle {
          required property var modelData
          required property int index
          readonly property real slot: historyPlot.width / 90
          x: index * slot
          y: historyPlot.height - height
          width: Math.max(1, slot - 1)
          height: modelData.tokens > 0 ? Math.max(2, historyPlot.height * modelData.tokens / aiGraphs.peak) : 1
          color: modelData.tokens > 0 ? (modelData.today ? bar.bright : bar.dim) : Qt.alpha(Color.foreground, 0.1)
        }
      }
    }

    HudSection { ink: bar.hud; noteInk: bar.dim; title: "TOKENS BY DAY" }
    Repeater {
      model: bar.usageRecent
      delegate: Item {
        id: dayRow
        required property var modelData
        readonly property real count: Number(modelData.messageCount) || 0
        readonly property bool today: String(modelData.date) === aiGraphs.todayIso
        width: aiGraphs.width
        height: 16
        HudLabel {
          width: 44
          anchors.verticalCenter: parent.verticalCenter
          text: bar.weekDays[new Date(String(dayRow.modelData.date) + "T12:00:00").getDay()]
          color: dayRow.today ? bar.bright : bar.dim
        }
        Rectangle {
          x: 48
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - 48 - 52
          height: 6
          color: Qt.alpha(Color.foreground, 0.1)
          Rectangle {
            width: parent.width * dayRow.count / aiGraphs.dayPeak
            height: parent.height
            color: dayRow.today ? bar.bright : bar.hud
          }
        }
        HudLabel {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: Model.tokenText(dayRow.count)
          color: bar.bright
          font.bold: false
        }
      }
    }
  }
}
