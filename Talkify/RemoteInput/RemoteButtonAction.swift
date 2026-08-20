import Foundation

/// What one Siri Remote button does.
///
/// The remote's buttons reach this app through IOKit HID, and the app opens
/// the device without seizing it, so macOS still receives every press. That
/// is why `none` is a real choice and the default for most buttons: volume,
/// mute and play already work on their own, and an action bound on top of
/// them would happen twice.
enum RemoteButtonAction: String, Sendable, Hashable, CaseIterable, Codable {
  case none
  case dictateHold
  case dictateToggle
  case cancelDictation
  case readAloud
  case missionControl
  case applicationWindows
  case showDesktop
  case spotlight

  var title: String {
    switch self {
    case .none: "Leave to macOS"
    case .dictateHold: "Dictate while held"
    case .dictateToggle: "Dictate, press to stop"
    case .cancelDictation: "Cancel dictation"
    case .readAloud: "Read Aloud"
    case .missionControl: "Mission Control"
    case .applicationWindows: "Application windows"
    case .showDesktop: "Show desktop"
    case .spotlight: "Spotlight"
    }
  }

  /// True when the action needs the release as well as the press. Only
  /// hold-to-talk does: everything else happens once, on the way down.
  var needsRelease: Bool { self == .dictateHold }
}

/// Which action each button runs.
///
/// Stored by the button's raw value, so a button this build does not know
/// is dropped rather than crashing an older map, and a button with no entry
/// falls back to its default.
struct RemoteButtonMap: Sendable, Equatable {
  private var actions: [SiriRemoteButtonMonitor.Button: RemoteButtonAction]

  /// Hold Siri to dictate, press Back to throw the take away. Everything
  /// else stays with macOS, which already does the sensible thing with the
  /// volume, mute and transport keys.
  static let standard = RemoteButtonMap(actions: [
    .siri: .dictateHold,
    .back: .cancelDictation,
  ])

  init(actions: [SiriRemoteButtonMonitor.Button: RemoteButtonAction] = [:]) {
    self.actions = actions
  }

  subscript(button: SiriRemoteButtonMonitor.Button) -> RemoteButtonAction {
    get { actions[button] ?? .none }
    set { actions[button] = newValue }
  }

  /// JSON, keyed by the button's raw value, for UserDefaults.
  init?(json: String) {
    guard let data = json.data(using: .utf8),
          let raw = try? JSONDecoder().decode([String: String].self, from: data)
    else { return nil }

    var decoded: [SiriRemoteButtonMonitor.Button: RemoteButtonAction] = [:]
    for (buttonName, actionName) in raw {
      guard let button = SiriRemoteButtonMonitor.Button(rawValue: buttonName),
            let action = RemoteButtonAction(rawValue: actionName)
      else { continue }
      decoded[button] = action
    }
    self.init(actions: decoded)
  }

  var json: String {
    let raw = actions.reduce(into: [String: String]()) { result, pair in
      result[pair.key.rawValue] = pair.value.rawValue
    }
    guard let data = try? JSONEncoder().encode(raw),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
