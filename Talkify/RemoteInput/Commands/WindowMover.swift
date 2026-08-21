import AppKit
import ApplicationServices
import OSLog

/// Moves and resizes the frontmost window.
///
/// Through the Accessibility API rather than by pressing a shortcut,
/// because there is no shortcut for this: window arrangement belongs to
/// whichever utility the user happens to have installed, and asking the
/// window itself where to be works whether they have one or not.
///
/// Accessibility is already required for inserting dictated text, so this
/// needs no permission the app does not already hold.
@MainActor
enum WindowMover {
  enum Failure: Error, Equatable {
    case noFocusedWindow
    case refused
  }

  static func arrange(_ arrangement: WindowArrangement) -> Result<String, Failure> {
    guard let window = focusedWindow() else { return .failure(.noFocusedWindow) }

    let screen = screenContaining(window) ?? NSScreen.main
    guard let screen else { return .failure(.noFocusedWindow) }

    var target = arrangement.frame(in: usableFrame(of: screen))
    if arrangement.keepsSize, let size = size(of: window) {
      // Centring keeps whatever size the window already had.
      target = CGRect(
        x: target.midX - size.width / 2,
        y: target.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
    }

    // Size first, then position. A window that is moved before it is
    // shrunk can be clamped by the system on the way, landing somewhere
    // neither the user nor the arrangement asked for.
    let sized = set(.size, of: window, to: target.size)
    let moved = set(.position, of: window, to: target.origin)
    // Sized again: an application that refuses a size while off screen
    // often accepts it once the window is where it is going.
    _ = set(.size, of: window, to: target.size)

    guard sized || moved else { return .failure(.refused) }
    return .success(arrangement.title)
  }

  /// The screen minus the menu bar and the Dock, in the coordinates the
  /// Accessibility API uses: origin top left, y increasing downwards,
  /// which is the opposite of how AppKit reports screens.
  private static func usableFrame(of screen: NSScreen) -> CGRect {
    let visible = screen.visibleFrame
    let height = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
    return CGRect(
      x: visible.minX,
      y: height - visible.maxY,
      width: visible.width,
      height: visible.height
    )
  }

  private static func focusedWindow() -> AXUIElement? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
    let application = AXUIElementCreateApplication(frontmost.processIdentifier)

    var value: AnyObject?
    let status = AXUIElementCopyAttributeValue(
      application, kAXFocusedWindowAttribute as CFString, &value
    )
    guard status == .success, let value else { return nil }
    return (value as! AXUIElement)
  }

  private static func size(of window: AXUIElement) -> CGSize? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(
      window, kAXSizeAttribute as CFString, &value
    ) == .success, let value else { return nil }

    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
  }

  private enum Attribute {
    case position
    case size
  }

  private static func set(_ attribute: Attribute, of window: AXUIElement, to value: Any) -> Bool {
    switch attribute {
    case .position:
      var point = value as! CGPoint
      guard let axValue = AXValueCreate(.cgPoint, &point) else { return false }
      return AXUIElementSetAttributeValue(
        window, kAXPositionAttribute as CFString, axValue
      ) == .success
    case .size:
      var size = value as! CGSize
      guard let axValue = AXValueCreate(.cgSize, &size) else { return false }
      return AXUIElementSetAttributeValue(
        window, kAXSizeAttribute as CFString, axValue
      ) == .success
    }
  }

  /// Whichever screen holds most of the window, so arranging on a second
  /// display does not throw the window back to the first.
  private static func screenContaining(_ window: AXUIElement) -> NSScreen? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(
      window, kAXPositionAttribute as CFString, &value
    ) == .success, let value else { return nil }

    var origin = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &origin) else { return nil }

    let height = NSScreen.screens.map(\.frame.maxY).max() ?? 0
    let flipped = CGPoint(x: origin.x, y: height - origin.y)
    return NSScreen.screens.first { $0.frame.contains(flipped) }
  }
}
