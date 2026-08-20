import CoreGraphics
import Foundation

/// What one Siri Remote button does.
///
/// The Siri button is not here. It holds to dictate, always, and nothing
/// else: that is the whole point of a microphone on a remote, so making it
/// configurable would only be a way to break it.
///
/// Almost everything is a keystroke. `sendKeys` carries a combination the
/// user recorded, and the named cases carry one this app already knows,
/// because macOS swallows those combinations before a recorder can see
/// them — press ⌃↑ into the recorder and Mission Control opens instead of
/// the key being captured. Naming them is the only way to bind them.
///
/// The remote is read without being seized, so macOS still receives every
/// press. That is why `none` is a real choice and the default for most
/// buttons: volume, mute and the transport keys already work, and an action
/// bound on top of one of them would happen twice.
enum RemoteButtonAction: Sendable, Equatable {
  case none
  case cancelDictation
  case missionControl
  case applicationWindows
  case showDesktop
  case spotlight
  case sendKeys(KeyBinding)

  /// The choice shown in the picker, without the recorded combination.
  enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
    case none
    case cancelDictation
    case missionControl
    case applicationWindows
    case showDesktop
    case spotlight
    case sendKeys

    var title: String {
      switch self {
      case .none: "Leave to macOS"
      case .cancelDictation: "Cancel dictation"
      case .missionControl: "Mission Control"
      case .applicationWindows: "Application windows"
      case .showDesktop: "Show desktop"
      case .spotlight: "Spotlight"
      case .sendKeys: "Send keys…"
      }
    }
  }

  var kind: Kind {
    switch self {
    case .none: .none
    case .cancelDictation: .cancelDictation
    case .missionControl: .missionControl
    case .applicationWindows: .applicationWindows
    case .showDesktop: .showDesktop
    case .spotlight: .spotlight
    case .sendKeys: .sendKeys
    }
  }

  /// The combination this action presses, or nil when it presses none.
  ///
  /// The named actions resolve to the shortcut macOS ships for them, so
  /// every keystroke in this file leaves through one function.
  var keyBinding: KeyBinding? {
    switch self {
    case .none, .cancelDictation: nil
    case .missionControl: .missionControl
    case .applicationWindows: .applicationWindows
    case .showDesktop: .showDesktop
    case .spotlight: .spotlight
    case let .sendKeys(binding): binding
    }
  }

  /// The combination the user recorded, which is only the `sendKeys` one.
  /// A named action's shortcut is not theirs to keep.
  var recordedKeyBinding: KeyBinding? {
    if case let .sendKeys(binding) = self { return binding }
    return nil
  }

  /// Rebuilds the action for a newly picked kind, keeping any combination
  /// the user already recorded so switching away and back does not lose it.
  func withKind(_ kind: Kind, recorded: KeyBinding) -> RemoteButtonAction {
    switch kind {
    case .none: .none
    case .cancelDictation: .cancelDictation
    case .missionControl: .missionControl
    case .applicationWindows: .applicationWindows
    case .showDesktop: .showDesktop
    case .spotlight: .spotlight
    case .sendKeys: .sendKeys(recordedKeyBinding ?? recorded)
    }
  }
}

extension KeyBinding {
  /// The shortcuts macOS ships for the window and search commands. Virtual
  /// key codes are positions on the keyboard, not letters, so they hold for
  /// every layout.
  static let missionControl = KeyBinding(
    keyCode: 126, modifierFlags: CGEventFlags.maskControl.rawValue,
    isModifierKey: false, label: "⌃ ↑", keyEquivalent: ""
  )
  static let applicationWindows = KeyBinding(
    keyCode: 125, modifierFlags: CGEventFlags.maskControl.rawValue,
    isModifierKey: false, label: "⌃ ↓", keyEquivalent: ""
  )
  static let showDesktop = KeyBinding(
    keyCode: 103, modifierFlags: 0,
    isModifierKey: false, label: "F11", keyEquivalent: ""
  )
  static let spotlight = KeyBinding(
    keyCode: 49, modifierFlags: CGEventFlags.maskCommand.rawValue,
    isModifierKey: false, label: "⌘ space", keyEquivalent: " "
  )
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

  /// Press Back to throw the take away. Everything else stays with macOS,
  /// which already does the sensible thing with the volume, mute and
  /// transport keys. The Siri button is not in here: it always dictates.
  static let standard = RemoteButtonMap(actions: [.back: .cancelDictation])

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
      case .cancelDictation: decoded[button] = .cancelDictation
      case .missionControl: decoded[button] = .missionControl
      case .applicationWindows: decoded[button] = .applicationWindows
      case .showDesktop: decoded[button] = .showDesktop
      case .spotlight: decoded[button] = .spotlight
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
        binding: pair.value.recordedKeyBinding
      )
    }
    guard let data = try? JSONEncoder().encode(raw),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
