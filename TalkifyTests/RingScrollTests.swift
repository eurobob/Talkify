import Foundation
import Testing

@testable import Talkify

/// Circling the clickpad's rim scrolls. The geometry is worth pinning: an
/// angle that wraps at twelve o'clock works all the way round the circle
/// except once per revolution, which is exactly the kind of fault that
/// reaches a user rather than a test.
struct RingScrollTests {
  /// A point on the rim at a given angle, measured the way the pad does.
  private func point(atDegrees degrees: Double, radius: Double = 0.4) -> (Double, Double) {
    let radians = degrees * .pi / 180
    return (0.5 + radius * cos(radians), 0.5 + radius * sin(radians))
  }

  @Test func theMiddleOfThePadIsNotTheRing() {
    #expect(!RingScroll.isOnRing(x: 0.5, y: 0.5))
    #expect(!RingScroll.isOnRing(x: 0.6, y: 0.55))
    #expect(RingScroll.isOnRing(x: 0.9, y: 0.5))
    #expect(RingScroll.isOnRing(x: 0.5, y: 0.1))
  }

  @Test func aStationaryFingerScrollsNothing() {
    var ring = RingScroll()
    let (x, y) = point(atDegrees: 0)
    #expect(ring.accept(x: x, y: y) == 0)
    #expect(ring.accept(x: x, y: y) == 0)
  }

  /// Opposite directions scroll opposite ways, whichever they are.
  @Test func thetwoDirectionsDisagree() {
    var forward = RingScroll()
    var backward = RingScroll()
    var forwardTotal = 0
    var backwardTotal = 0

    for step in stride(from: 0.0, through: 90, by: 5) {
      let (fx, fy) = point(atDegrees: step)
      forwardTotal += forward.accept(x: fx, y: fy)
      let (bx, by) = point(atDegrees: -step)
      backwardTotal += backward.accept(x: bx, y: by)
    }

    #expect(forwardTotal != 0)
    #expect(backwardTotal != 0)
    #expect((forwardTotal > 0) != (backwardTotal > 0))
  }

  /// The whole point of keeping the remainder: a slow circle must still
  /// scroll rather than stalling below the threshold forever.
  @Test func aSlowCircleStillScrolls() {
    var ring = RingScroll()
    var total = 0
    for step in stride(from: 0.0, through: 180, by: 1) {
      let (x, y) = point(atDegrees: step)
      total += ring.accept(x: x, y: y)
    }
    #expect(total != 0)
  }

  /// Twelve o'clock is where the angle wraps. A full turn through it must
  /// scroll the same as a full turn anywhere else.
  @Test func crossingTheWrapPointIsNotAFullTurnBackwards() {
    var ring = RingScroll()
    var total = 0
    // 150 degrees through to 210, straight across the wrap at 180.
    for step in stride(from: 150.0, through: 210, by: 5) {
      let (x, y) = point(atDegrees: step)
      total += ring.accept(x: x, y: y)
    }
    // Sixty degrees is a handful of lines, not the dozens a mistaken
    // full turn would produce.
    #expect(abs(total) < 8)
    #expect(total != 0)
  }

  /// A jump halfway round between two reports is not a finger. Acting on it
  /// would fling the page.
  @Test func anImpossibleJumpIsIgnored() {
    var ring = RingScroll()
    let (x1, y1) = point(atDegrees: 0)
    _ = ring.accept(x: x1, y: y1)
    let (x2, y2) = point(atDegrees: 170)
    #expect(ring.accept(x: x2, y: y2) == 0)
  }

  @Test func resettingForgetsWhereTheFingerWas() {
    var ring = RingScroll()
    let (x1, y1) = point(atDegrees: 0)
    _ = ring.accept(x: x1, y: y1)
    ring.reset()
    let (x2, y2) = point(atDegrees: 90)
    #expect(ring.accept(x: x2, y: y2) == 0)
  }
}
