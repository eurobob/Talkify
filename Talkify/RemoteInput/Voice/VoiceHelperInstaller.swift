import Foundation
import OSLog
import ServiceManagement

/// Installs and reports on the Siri Remote's voice helper.
///
/// The helper reads the Bluetooth link, which macOS allows only to root, so
/// it cannot live inside the app. It ships inside the app bundle instead
/// and is registered with launchd through `SMAppService`, which is the
/// supported way for an app to install a daemon: macOS asks the user once,
/// in System Settings, and never again.
///
/// Nothing here runs a script or asks for a password. The app offers a
/// button, the user approves it, and the microphone works from then on,
/// including after a reboot.
enum VoiceHelperInstaller {
  /// Must match the plist in `Contents/Library/LaunchDaemons/`, which is
  /// what `SMAppService.daemon(plistName:)` looks for by name.
  static let plistName = "digital.chaotic.talkify-remote-voiced.plist"

  enum State: Equatable, Sendable {
    /// Installed, approved, and running.
    case installed
    /// Registered, but the user has not approved it in System Settings yet.
    case awaitingApproval
    /// Never installed, or removed.
    case notInstalled
    /// The helper is missing from the app bundle, which means the build is
    /// incomplete rather than the user having done anything wrong.
    case missingFromBundle

    var title: String {
      switch self {
      case .installed: "Installed"
      case .awaitingApproval: "Waiting for your approval"
      case .notInstalled: "Not installed"
      case .missingFromBundle: "Missing from this build"
      }
    }
  }

  private static var service: SMAppService {
    SMAppService.daemon(plistName: plistName)
  }

  /// Where the last installed helper's build date is remembered.
  private static let installedStampKey = "voiceHelperInstalledStamp"

  /// The helper inside this app bundle, and when it was built.
  private static var bundledHelperDate: Date? {
    guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
      .appendingPathComponent("talkify-remote-voiced")
    else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: executable.path))?[.modificationDate] as? Date
  }

  /// Reinstalls the daemon when the app carries a newer helper than the one
  /// that was installed.
  ///
  /// launchd keeps running whatever it started, so a rebuilt app leaves the
  /// old helper serving audio indefinitely — five days, on the machine this
  /// was found on, with every change in between never executing. Nothing
  /// looks wrong: the daemon is loaded, its socket answers, and the audio
  /// it decodes is the old build's idea of the protocol.
  ///
  /// Re-registering needs no password, which is the point: the alternative
  /// is asking the user to run launchctl as root after every update.
  static func reinstallIfOutdated() {
    guard let built = bundledHelperDate else { return }

    let defaults = UserDefaults.standard
    let installed = defaults.object(forKey: installedStampKey) as? Date
    guard installed == nil || abs(built.timeIntervalSince(installed!)) > 1 else { return }

    RemoteInputLog.logger.info("installing a newer voice helper")
    try? service.unregister()

    // Registering immediately after unregistering is refused: the teardown
    // has not finished, and the failure reads as "Operation not permitted",
    // which sends you looking at entitlements rather than at timing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      do {
        try service.register()
        defaults.set(built, forKey: installedStampKey)
        RemoteInputLog.logger.info("voice helper updated")
      } catch {
        // Not fatal: the service is unregistered, so the next launch takes
        // the ordinary install path and succeeds there.
        RemoteInputLog.logger.error(
          "voice helper will install on next launch: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  static var state: State {
    switch service.status {
    case .enabled: .installed
    case .requiresApproval: .awaitingApproval
    case .notRegistered: .notInstalled
    case .notFound: .missingFromBundle
    @unknown default: .notInstalled
    }
  }

  /// Registers the helper with launchd. macOS shows its own approval
  /// prompt; `awaitingApproval` afterwards is the normal, successful path
  /// rather than a failure.
  @discardableResult
  static func install() -> Result<State, Error> {
    do {
      try service.register()
      if let built = bundledHelperDate {
        UserDefaults.standard.set(built, forKey: installedStampKey)
      }
      RemoteInputLog.logger.info("voice helper registered: \(state.title, privacy: .public)")
      return .success(state)
    } catch {
      RemoteInputLog.logger.error(
        "voice helper registration failed: \(error.localizedDescription, privacy: .public)"
      )
      return .failure(error)
    }
  }

  @discardableResult
  static func remove() -> Result<State, Error> {
    do {
      try service.unregister()
      return .success(state)
    } catch {
      return .failure(error)
    }
  }

  /// Opens the pane where the user approves or disables background items.
  /// The approval prompt is easy to dismiss and there is no way back to it
  /// from the app other than this.
  @MainActor
  static func openApprovalSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
