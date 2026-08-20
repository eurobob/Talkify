import Foundation

/// What one Siri Remote button does.
///
/// Anything the Mac can be told to do with the keyboard is reachable through
/// `sendKeys`, which carries a combination the user recorded rather than a
/// name this app had to think of first. The other cases exist only because
/// they have no keyboard equivalent to record: a dictation session that
/// lasts exactly as long as the button is held cannot be expressed as a
/// keystroke.
///
/// The remote is read without being seized, so macOS still receives every
/// press. That is why `none` is a real choice and the default for most
/// buttons: volume, mute and the transport keys already work, and an action
/// bound on top of one of them would happen twice.
enum RemoteButtonAction: Sendable, Equatable {
  case none
  case dictateHold
  case dictateToggle
  case cancelDictation
  case readAloud
  case sendKeys(KeyBinding)

  /// The choice shown in the picker, without the recorded combination.
  enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
    case none
    case dictateHold
    case dictateToggle
    case cancelDictation
    case readAloud
    case sendKeys

    var title: String {
      switch self {
      case .none: "Leave to macOS"
      case .dictateHold: "Dictate while held"
      case .dictateToggle: "Dictate, press to stop"
      case .cancelDictation: "Cancel dictation"
      case .readAloud: "Read Aloud"
      case .sendKeys: "Send keys…"
      }
    }
  }

  var kind: Kind {
    switch self {
    case .none: .none
    case .dictateHold: .dictateHold
    case .dictateToggle: .dictateToggle
    case .cancelDictation: .cancelDictation
    case .readAloud: .readAloud
    case .sendKeys: .sendKeys
    }
  }

  /// The combination this action sends, or nil when it sends none.
  var keyBinding: KeyBinding? {
    if case let .sendKeys(binding) = self { return binding }
    return nil
  }

  /// True when the action needs the release as well as the press. Only
  /// hold-to-talk does: everything else happens once, on the way down.
  var needsRelease: Bool { self == .dictateHold }

  /// Rebuilds the action for a newly picked kind, keeping any combination
  /// the user already recorded so switching away and back does not lose it.
  func withKind(_ kind: Kind, recorded: KeyBinding) -> RemoteButtonAction {
    switch kind {
    case .none: .none
    case .dictateHold: .dictateHold
    case .dictateToggle: .dictateToggle
    case .cancelDictation: .cancelDictation
    case .readAloud: .readAloud
    case .sendKeys: .sendKeys(keyBinding ?? recorded)
    }
  }
}

/// One button's action as it is stored: the kind by name, plus the recorded
/// combination when there is one.
private struct StoredAction: Codable {
  var kind: RemoteButtonAction.Kind
  var binding: KeyBinding?
}

/// Which action each button runs.
///
/// Stored by the button's raw value, so a button this build does not know is
/// dropped rather than failing an otherwise good map, and a button with no
/// entry falls back to its default.
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
          let raw = try? JSONDecoder().decode([String: StoredAction].self, from: data)
    else { return nil }

    var decoded: [SiriRemoteButtonMonitor.Button: RemoteButtonAction] = [:]
    for (buttonName, stored) in raw {
      guard let button = SiriRemoteButtonMonitor.Button(rawValue: buttonName) else { continue }
      switch stored.kind {
      case .none: decoded[button] = RemoteButtonAction.none
      case .dictateHold: decoded[button] = .dictateHold
      case .dictateToggle: decoded[button] = .dictateToggle
      case .cancelDictation: decoded[button] = .cancelDictation
      case .readAloud: decoded[button] = .readAloud
      case .sendKeys:
        // A send-keys entry with no combination recorded would be a button
        // that does nothing while claiming otherwise.
        guard let binding = stored.binding else { continue }
        decoded[button] = .sendKeys(binding)
      }
    }
    self.init(actions: decoded)
  }

  var json: String {
    let raw = actions.reduce(into: [String: StoredAction]()) { result, pair in
      result[pair.key.rawValue] = StoredAction(
        kind: pair.value.kind,
        binding: pair.value.keyBinding
      )
    }
    guard let data = try? JSONEncoder().encode(raw),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
