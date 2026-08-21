import Foundation
import OSLog
import ServiceManagement

/// Registers the app to start when the user logs in.
///
/// The voice helper is a daemon and starts at boot on its own, but a daemon
/// serving nobody is not a working remote: the app is what reads the
/// buttons, moves the pointer and runs the commands. Without this, every
/// restart leaves the remote dead until the user remembers to open a
/// menu-bar app that has no window.
///
/// `SMAppService.mainApp` is the supported way to do this. It needs no
/// helper and no separate approval beyond the one macOS asks for itself.
enum LoginItem {
  enum State: Equatable, Sendable {
    case enabled
    case awaitingApproval
    case disabled

    var title: String {
      switch self {
      case .enabled: "On"
      case .awaitingApproval: "Waiting for approval"
      case .disabled: "Off"
      }
    }
  }

  static var state: State {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .awaitingApproval
    default: .disabled
    }
  }

  /// Brings registration into line with the setting. Idempotent, so it can
  /// run on every launch without asking macOS to do anything twice.
  static func setEnabled(_ enabled: Bool) {
    let current = state
    do {
      if enabled {
        guard current == .disabled else { return }
        try SMAppService.mainApp.register()
        RemoteInputLog.logger.info("registered to start at login")
      } else {
        guard current != .disabled else { return }
        try SMAppService.mainApp.unregister()
        RemoteInputLog.logger.info("no longer starts at login")
      }
    } catch {
      RemoteInputLog.logger.error(
        "login item change failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
