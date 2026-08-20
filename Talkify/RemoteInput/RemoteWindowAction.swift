import AppKit
import OSLog

/// Runs the window-management actions macOS handles itself.
///
/// These are not sent as keystrokes. Mission Control and its neighbours are
/// handled by the window server, which ignores a synthetic shortcut however
/// carefully it is assembled: the modifiers were posted as their own key
/// events, paced, with the flags a real keyboard reports, and it still did
/// nothing — while the same code sends Return to an ordinary app perfectly.
///
/// Opening the system app that performs the action works, and works whether
/// or not the user has rebound or disabled the shortcut. Verified on
/// 2026-08-20.
enum RemoteWindowAction {
  private static let missionControl = URL(
    fileURLWithPath: "/System/Applications/Mission Control.app"
  )

  /// True when this action is performed by opening a system app rather than
  /// by pressing keys.
  static func isHandledHere(_ action: RemoteButtonAction) -> Bool {
    action == .missionControl
  }

  @MainActor
  static func run(_ action: RemoteButtonAction) {
    guard action == .missionControl else { return }

    let configuration = NSWorkspace.OpenConfiguration()
    // The app is the mechanism, not a window to focus: activating it would
    // steal focus from whatever the user was typing in, which is the thing
    // dictation spends its whole life protecting.
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: missionControl, configuration: configuration) { _, error in
      if let error {
        RemoteInputLog.logger.error(
          "Mission Control failed: \(error.localizedDescription, privacy: .public)"
        )
      } else {
        RemoteInputLog.logger.info("opened Mission Control")
      }
    }
  }
}
