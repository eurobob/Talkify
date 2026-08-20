import AppKit
import CoreGraphics
import Foundation

/// Moves the pointer from the Siri Remote's clickpad.
///
/// Two things about GoatRemote's version were worth fixing, and both are
/// addressed here rather than left to taste.
///
/// It was too fast to aim with. The pad is about 35 mm across and the
/// screen is thousands of points wide, so a linear mapping has to be steep
/// enough that a slow, careful movement still crosses the screen. The
/// answer is acceleration: a slow finger moves the pointer slowly enough to
/// land on a button, and a fast one still crosses the display in one swipe.
///
/// Clicking moved the pointer. A finger cannot press without sliding a
/// little, so the click landed next to whatever it was aimed at. The press
/// arrives separately, as a HID button, so the pointer can be frozen the
/// moment it goes down and stay exactly where it was aimed.
@MainActor
final class RemoteCursor {
  /// How far the pointer travels for a given finger movement, before
  /// acceleration. One unit of pad is its full width.
  var speed: Double = 900

  /// How much a fast finger is amplified. At 0 the pointer is linear and
  /// hard to throw across a large display; too high and it is impossible to
  /// aim. This is the value that made a 6 x 12 sensor usable on a laptop
  /// display.
  private let acceleration: Double = 2.6

  /// Movement below this is the hand resting rather than pointing. The pad
  /// reports constantly while touched, and without a floor the pointer
  /// creeps under a stationary finger.
  private let noiseFloor: Double = 0.0015

  private var lastPosition: CGPoint?
  private var isFrozen = false
  private var isDragging = false

  /// Accepts one frame from the pad.
  func receive(_ touch: SiriRemoteTouchpad.Touch) {
    // No contacts means the finger lifted. The next touch starts a fresh
    // gesture rather than jumping the pointer by the distance between where
    // the finger left and where it landed.
    guard touch.contacts > 0 else {
      lastPosition = nil
      return
    }

    let position = CGPoint(x: Double(touch.x), y: Double(touch.y))
    defer { lastPosition = position }

    guard let lastPosition, !isFrozen else { return }

    var deltaX = position.x - lastPosition.x
    // The pad's origin is at the bottom, the screen's at the top.
    var deltaY = -(position.y - lastPosition.y)

    let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()
    guard distance > noiseFloor else { return }

    // Speed scales with how fast the finger is moving, so slow is precise
    // and fast is quick, from the same small pad.
    let gain = speed * (1 + acceleration * distance * 60)
    deltaX *= gain
    deltaY *= gain

    move(byX: deltaX, y: deltaY)
  }

  /// The clickpad went down or up. Called from the HID button monitor,
  /// which is the only place the press is visible.
  func setPressed(_ pressed: Bool) {
    isFrozen = pressed
    guard pressed != isDragging else { return }
    isDragging = pressed
    click(down: pressed)
  }

  /// True while the pad is held, so a release can be delivered even if the
  /// remote drops its connection mid-press.
  var isHoldingButton: Bool { isDragging }

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
