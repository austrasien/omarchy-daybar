import QtQuick
import qs.Commons

// Worn tape: dark lines across a filled shape, as over the cards' text.
Image {
  anchors.fill: parent
  fillMode: Image.Tile
  verticalAlignment: Image.AlignTop
  horizontalAlignment: Image.AlignLeft
  source: "data:image/svg+xml," + encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' width='3' height='3'><rect width='3' height='1' fill='"
    + Qt.darker(Color.background, 1.6) + "' fill-opacity='0.6'/></svg>")
}
