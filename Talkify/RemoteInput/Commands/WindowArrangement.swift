import CoreGraphics
import Foundation

/// Where a window should go.
///
/// This is the half of window management worth testing: given a screen and
/// an arrangement, the frame is arithmetic, and arithmetic that puts a
/// window slightly off screen is the difference between a feature people
/// use and one they stop trusting.
enum WindowArrangement: String, Sendable, CaseIterable {
  case leftHalf
  case rightHalf
  case topHalf
  case bottomHalf
  case leftThird
  case middleThird
  case rightThird
  case leftTwoThirds
  case rightTwoThirds
  case topLeft
  case topRight
  case bottomLeft
  case bottomRight
  case fill
  case centre

  /// The phrases that reach it. Several per arrangement, because people do
  /// not agree on what to call these and being made to learn one wording is
  /// what makes voice control feel like an obstacle.
  var phrases: [String] {
    switch self {
    case .leftHalf: ["left", "left half", "snap left", "move left"]
    case .rightHalf: ["right", "right half", "snap right", "move right"]
    case .topHalf: ["top half", "upper half", "snap up"]
    case .bottomHalf: ["bottom half", "lower half", "snap down"]
    case .leftThird: ["left third"]
    case .middleThird: ["middle third", "centre third", "center third"]
    case .rightThird: ["right third"]
    case .leftTwoThirds: ["left two thirds"]
    case .rightTwoThirds: ["right two thirds"]
    case .topLeft: ["top left", "upper left"]
    case .topRight: ["top right", "upper right"]
    case .bottomLeft: ["bottom left", "lower left"]
    case .bottomRight: ["bottom right", "lower right"]
    case .fill: ["fill the screen", "fill screen", "maximise", "maximize", "full width"]
    case .centre: ["centre", "center", "centre it", "center it"]
    }
  }

  var title: String {
    switch self {
    case .leftHalf: "Left half"
    case .rightHalf: "Right half"
    case .topHalf: "Top half"
    case .bottomHalf: "Bottom half"
    case .leftThird: "Left third"
    case .middleThird: "Middle third"
    case .rightThird: "Right third"
    case .leftTwoThirds: "Left two thirds"
    case .rightTwoThirds: "Right two thirds"
    case .topLeft: "Top left"
    case .topRight: "Top right"
    case .bottomLeft: "Bottom left"
    case .bottomRight: "Bottom right"
    case .fill: "Filling the screen"
    case .centre: "Centred"
    }
  }

  /// The frame this arrangement wants, inside the usable part of a screen.
  ///
  /// `visible` is the screen minus the menu bar and the Dock, so a filled
  /// window does not slide under either of them.
  func frame(in visible: CGRect) -> CGRect {
    // Boundaries are rounded to whole points and the frames are built
    // between them, rather than each frame being computed from a fraction
    // of the width. A screen whose width does not divide by three leaves a
    // visible strip of desktop between two windows otherwise, and the last
    // one runs off the edge.
    let left = visible.minX.rounded()
    let right = visible.maxX.rounded()
    let top = visible.minY.rounded()
    let bottom = visible.maxY.rounded()
    let middleX = visible.midX.rounded()
    let middleY = visible.midY.rounded()
    let oneThird = (visible.minX + visible.width / 3).rounded()
    let twoThirds = (visible.minX + visible.width * 2 / 3).rounded()

    func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
      CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    switch self {
    case .leftHalf: return rect(left, top, middleX, bottom)
    case .rightHalf: return rect(middleX, top, right, bottom)
    case .topHalf: return rect(left, top, right, middleY)
    case .bottomHalf: return rect(left, middleY, right, bottom)
    case .leftThird: return rect(left, top, oneThird, bottom)
    case .middleThird: return rect(oneThird, top, twoThirds, bottom)
    case .rightThird: return rect(twoThirds, top, right, bottom)
    case .leftTwoThirds: return rect(left, top, twoThirds, bottom)
    case .rightTwoThirds: return rect(oneThird, top, right, bottom)
    case .topLeft: return rect(left, top, middleX, middleY)
    case .topRight: return rect(middleX, top, right, middleY)
    case .bottomLeft: return rect(left, middleY, middleX, bottom)
    case .bottomRight: return rect(middleX, middleY, right, bottom)
    case .fill: return rect(left, top, right, bottom)
    case .centre:
      // Centring keeps the window's own size. Two thirds is the size it
      // takes when it has none worth keeping.
      let width = ((right - left) * 2 / 3).rounded()
      let height = ((bottom - top) * 2 / 3).rounded()
      let x0 = (visible.midX - width / 2).rounded()
      let y0 = (visible.midY - height / 2).rounded()
      return CGRect(x: x0, y: y0, width: width, height: height)
    }
  }

  /// Centring is the one arrangement that keeps the window's own size.
  var keepsSize: Bool { self == .centre }

  /// The arrangement a phrase names, or nil.
  static func named(_ phrase: String) -> WindowArrangement? {
    allCases.first { $0.phrases.contains(phrase) }
  }
}
