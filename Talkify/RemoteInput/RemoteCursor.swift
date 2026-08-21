import AppKit
import CoreGraphics
import Foundation

/// Moves the pointer from the Siri Remote's clickpad.
///
/// Three things about the obvious implementation make it unusable, and all
/// three are handled here rather than left to the speed setting.
///
/// **The first frames of a touch are wrong.** The sensor's estimate of
/// where a finger is settles over the first few reports, so the frame after
/// contact often sits some distance from the real position. Acting on that
/// difference throws the pointer across the screen the instant the pad is
/// touched, which is exactly what makes clicking impossible: the thing you
/// were aiming at is gone before you can press.
///
/// **A linear mapping cannot work.** The pad is about 35 mm across and the
/// screen is thousands of points wide, so a single ratio is either too slow
/// to cross the screen or too fast to aim. Speed scales with how fast the
/// finger moves instead.
///
/// **Pressing moves the finger.** A finger cannot press without sliding, so
/// the pointer is frozen while the pad is down and the click lands where it
/// was aimed.
@MainActor
final class RemoteCursor {
  /// How far the pointer travels for a given finger movement, before
  /// acceleration.
  var speed: Double = 620

  /// Whether a quick touch with no travel counts as a click.
  var isTapToClickEnabled = true

  /// Whether circling the pad's rim scrolls, the way a click wheel does.
  var isRingScrollEnabled = true

  /// How much a fast finger is amplified. Kept gentle: the pad is small
  /// enough that a steep curve makes the last few points of travel
  /// impossible to control.
  private let acceleration: Double = 1.1

  /// Reports to discard after contact, while the sensor's estimate of the
  /// finger's position settles. Costs about 40 ms, which is not
  /// perceptible, and is what stops a rested finger throwing the pointer.
  private let settlingFrames = 5

  /// The furthest a finger can credibly travel between two reports. The pad
  /// reports about every 8 ms, so anything approaching a quarter of its
  /// width in one step is not a finger: it is the sensor re-estimating, or
  /// the first contact swapping to a different finger. Acting on it throws
  /// the pointer across the screen, so the gesture resynchronises instead.
  private let discontinuity: Double = 0.12

  /// Movement below this is the hand resting rather than pointing. The pad
  /// reports constantly while touched, and without a floor the pointer
  /// creeps under a stationary finger.
  private let noiseFloor: Double = 0.004

  /// A touch shorter than this, that travelled less than `tapTravelLimit`,
  /// is a tap rather than a swipe.
  private let tapDuration: TimeInterval = 0.3
  private let tapTravelLimit: Double = 0.07

  private var lastPosition: CGPoint?
  private var lastIdentifier: Int?
  private var ring = RingScroll()
  /// Whether this gesture is scrolling, decided where the finger landed and
  /// kept until it lifts. Switching mode mid-stroke would mean a hand
  /// drifting inwards silently stopped scrolling and started pointing.
  private var isRingGesture = false
  private var framesSinceContact = 0
  /// The state filter is based on a layout that is not published, so it is
  /// checked rather than trusted: if no frame ever reports the settled
  /// state, the assumption was wrong and the filter turns itself off. A
  /// wrong guess must cost some jitter, never a pointer that cannot move.
  private var hasSeenSettledState = false
  private var framesInspected = 0
  private let framesBeforeTrustingState = 60
  private var touchBegan: Date?
  private var travelled: Double = 0
  private var isFrozen = false
  private var isDragging = false

  func receive(_ touch: SiriRemoteTouchpad.Touch) {
    guard touch.contacts > 0 else {
      endTouch()
      return
    }

    // One finger only. Which contact is reported first is not stable across
    // frames, so with two fingers down the "first" one swaps between them
    // and the difference between two different fingers reads as an enormous
    // movement. A second finger ends the gesture rather than corrupting it.
    guard touch.contacts == 1 else {
      resynchronise()
      return
    }

    // A different finger, even alone: the pad reuses the first slot when
    // one contact ends and another begins, and the gap between where the
    // old finger left and the new one landed is not a movement.
    if let lastIdentifier, lastIdentifier != touch.identifier {
      resynchronise()
    }
    lastIdentifier = touch.identifier

    // A landing or lifting finger has a position the pad is still
    // estimating. This is the one that matters: it is why a thumb placed
    // cleanly on an untouched pad still threw the pointer.
    framesInspected += 1
    if touch.isSettled { hasSeenSettledState = true }
    let trustState = hasSeenSettledState || framesInspected < framesBeforeTrustingState
    if trustState, !touch.isSettled {
      lastPosition = nil
      return
    }

    let position = CGPoint(x: Double(touch.x), y: Double(touch.y))
    defer { lastPosition = position }

    if touchBegan == nil {
      touchBegan = Date()
      travelled = 0
      framesSinceContact = 0
      // Where the finger lands decides what the gesture is, and it does not
      // change afterwards.
      isRingGesture = isRingScrollEnabled
        && RingScroll.isOnRing(x: position.x, y: position.y)
      ring.reset()
    }
    framesSinceContact += 1

    guard let lastPosition else { return }

    var deltaX = position.x - lastPosition.x
    // The pad's origin is at the bottom, the screen's at the top.
    var deltaY = -(position.y - lastPosition.y)
    let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()
    travelled += distance

    if isRingGesture {
      // The rim scrolls rather than points. Still subject to settling, so a
      // finger landing on the rim does not fling the page.
      guard framesSinceContact > settlingFrames, !isFrozen else { return }
      let lines = ring.accept(x: position.x, y: position.y)
      if lines != 0 { scroll(lines: lines) }
      return
    }

    // A step this large is not a finger. Resynchronising to the new
    // position, rather than moving by the difference, is what turns a
    // sensor glitch into a missed frame instead of a pointer that has left
    // the screen.
    guard distance < discontinuity else { return }

    // Discarded, not acted on: this is the settling period, and the
    // difference across it is the sensor changing its mind rather than the
    // finger moving.
    guard framesSinceContact > settlingFrames else { return }
    guard !isFrozen, distance > noiseFloor else { return }

    let gain = speed * (1 + acceleration * distance * 60)
    deltaX *= gain
    deltaY *= gain
    move(byX: deltaX, y: deltaY)
  }

  /// The clickpad went down or up, as a HID button. This is the physical
  /// click, and it is separate from a tap.
  func setPressed(_ pressed: Bool) {
    isFrozen = pressed
    guard pressed != isDragging else { return }
    isDragging = pressed
    click(down: pressed)
  }

  var isHoldingButton: Bool { isDragging }

  /// Drops the reference point without ending the gesture, so the next
  /// frame measures from somewhere real instead of moving by a difference
  /// that was never a movement.
  private func resynchronise() {
    lastPosition = nil
    framesSinceContact = 0
  }

  /// A finger lifting ends the gesture, and may itself have been a click.
  private func endTouch() {
    defer {
      lastPosition = nil
      lastIdentifier = nil
      touchBegan = nil
      framesSinceContact = 0
      travelled = 0
      isRingGesture = false
      ring.reset()
    }

    // A circle is not a tap, however briefly it was drawn.
    guard !isRingGesture else { return }

    guard isTapToClickEnabled,
          !isDragging,
          let touchBegan,
          Date().timeIntervalSince(touchBegan) < tapDuration,
          travelled < tapTravelLimit
    else { return }

    // A tap clicks where the pointer already is. It cannot have moved:
    // a touch this short and this still never left the settling period.
    click(down: true)
    click(down: false)
  }

  private func move(byX deltaX: Double, y deltaY: Double) {
    let current = CGEvent(source: nil)?.location ?? .zero
    let target = clamp(
      CGPoint(x: current.x + deltaX, y: current.y + deltaY),
      startingFrom: current
    )

    // A moved event rather than a warp: warping relocates the pointer
    // without telling anything, so hover states and drags do not follow it.
    let type: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
    guard let event = CGEvent(
      mouseEventSource: nil,
      mouseType: type,
      mouseCursorPosition: target,
      mouseButton: .left
    ) else { return }
    event.post(tap: .cghidEventTap)
  }

  private func scroll(lines: Int) {
    guard let event = CGEvent(
      scrollWheelEvent2Source: nil,
      units: .line,
      wheelCount: 1,
      wheel1: Int32(lines),
      wheel2: 0,
      wheel3: 0
    ) else { return }
    event.post(tap: .cghidEventTap)
  }

  private func click(down: Bool) {
    let position = CGEvent(source: nil)?.location ?? .zero
    guard let event = CGEvent(
      mouseEventSource: nil,
      mouseType: down ? .leftMouseDown : .leftMouseUp,
      mouseCursorPosition: position,
      mouseButton: .left
    ) else { return }
    event.post(tap: .cghidEventTap)
  }

  /// Keeps the pointer on a screen that exists.
  ///
  /// Displays are not one rectangle: clamping to the union would let the
  /// pointer sit in the gap between two screens of different heights, where
  /// it is invisible and unrecoverable without a mouse.
  private func clamp(_ point: CGPoint, startingFrom origin: CGPoint) -> CGPoint {
    let screens = NSScreen.screens.map(\.frame)
    guard !screens.isEmpty else { return point }

    // Flipped, because AppKit measures screens from the bottom and events
    // from the top.
    let height = screens.map(\.maxY).max() ?? 0
    let flipped = screens.map {
      CGRect(x: $0.minX, y: height - $0.maxY, width: $0.width, height: $0.height)
    }

    if flipped.contains(where: { $0.contains(point) }) { return point }

    // Off every screen: slide along whichever axis still lands somewhere,
    // so running the pointer into an edge stops it there rather than
    // freezing both axes.
    let horizontal = CGPoint(x: point.x, y: origin.y)
    if flipped.contains(where: { $0.contains(horizontal) }) { return horizontal }
    let vertical = CGPoint(x: origin.x, y: point.y)
    if flipped.contains(where: { $0.contains(vertical) }) { return vertical }
    return origin
  }
}
