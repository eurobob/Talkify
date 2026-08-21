import Foundation

/// Turns a circling finger on the clickpad's rim into scrolling.
///
/// The pad reports where a finger is, from 0 to 1 in each axis, so the rim
/// is simply everything beyond a radius from the centre and the scroll is
/// the angle swept. Clockwise scrolls down, the way a wheel does.
///
/// Pure, so the geometry can be pinned by tests: an angle that wraps at the
/// twelve o'clock position is exactly the sort of thing that works all the
/// way round the circle except once per revolution.
struct RingScroll {
  /// How far from the centre a touch has to start to be a scroll rather
  /// than a pointer movement. The pad is small, so this leaves the middle
  /// two thirds for pointing.
  static let ringRadius: Double = 0.33

  /// How much angle makes one line of scrolling. A full turn is about
  /// twenty lines, which is roughly a page in most applications.
  private static let radiansPerLine: Double = .pi / 10

  /// Half a turn between two reports is not a finger: at the pad's report
  /// rate it is the angle wrapping, or a second finger being reported.
  private static let maximumStep: Double = .pi / 2

  private var lastAngle: Double?
  private var accumulated: Double = 0

  init() {}

  /// True when a touch at this position belongs to the rim.
  static func isOnRing(x: Double, y: Double) -> Bool {
    radius(x: x, y: y) >= ringRadius
  }

  static func radius(x: Double, y: Double) -> Double {
    let dx = x - 0.5
    let dy = y - 0.5
    return (dx * dx + dy * dy).squareRoot()
  }

  /// Feeds one position in and returns whole lines to scroll, positive for
  /// up. Fractions are kept, so a slow circle still scrolls smoothly
  /// instead of stalling.
  mutating func accept(x: Double, y: Double) -> Int {
    let angle = atan2(y - 0.5, x - 0.5)
    defer { lastAngle = angle }
    guard let lastAngle else { return 0 }

    // Shortest way round, so crossing the wrap point is a small step
    // rather than a full turn in the opposite direction.
    var delta = angle - lastAngle
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }

    guard abs(delta) < Self.maximumStep else { return 0 }

    // Clockwise on screen is a decreasing angle, because the pad measures
    // from the bottom and the screen from the top. Clockwise scrolls down.
    accumulated += delta
    let lines = (accumulated / Self.radiansPerLine).rounded(.towardZero)
    guard lines != 0 else { return 0 }
    accumulated -= lines * Self.radiansPerLine
    return Int(lines)
  }

  /// The finger left the pad, or the gesture became something else.
  mutating func reset() {
    lastAngle = nil
    accumulated = 0
  }
}
