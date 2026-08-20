import AppKit
import CoreGraphics
import OSLog

/// Performs a understood command.
///
/// Applications are matched by name against what is installed, because a
/// transcript says "safari", not "/Applications/Safari.app". A name that
/// matches nothing is reported rather than guessed at: launching the wrong
/// application because it started with the same letter is worse than doing
/// nothing.
@MainActor
enum RemoteCommandRunner {
  enum Outcome: Equatable, Sendable {
    case done(String)
    case notUnderstood
    case noSuchApp(String)
  }

  static func run(_ command: RemoteCommand) -> Outcome {
    switch command {
    case let .open(name), let .switchTo(name):
      guard let app = application(named: name) else { return .noSuchApp(name) }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
      return .done("\(command.confirmation.hasPrefix("Opening") ? "Opening" : "Switching to") \(app.name)")

    case let .quit(name):
      guard let app = application(named: name) else { return .noSuchApp(name) }
      // Asked to quit, not killed: an app with unsaved work must get its
      // chance to say so.
      let running = NSWorkspace.shared.runningApplications.first {
        $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
      }
      guard let running else { return .done("\(app.name) is not running") }
      running.terminate()
      return .done("Quitting \(app.name)")

    case let .press(binding):
      RemoteActionRunner.send(binding)
      return .done(binding.label)

    case .missionControl:
      RemoteWindowAction.run(.missionControl)
      return .done("Mission Control")

    case let .scroll(lines):
      scroll(lines: lines)
      return .done(lines < 0 ? "Scrolling down" : "Scrolling up")
    }
  }

  private struct Application {
    let name: String
    let url: URL
  }

  /// Finds an installed application whose name matches what was said.
  ///
  /// Exact first, then prefix, then contained: "mail" should find Mail
  /// rather than MailMate, and only fall to the longer name when nothing
  /// shorter matches.
  private static func application(named spoken: String) -> Application? {
    let wanted = spoken.lowercased()
    let installed = applications()

    if let exact = installed.first(where: { $0.name.lowercased() == wanted }) {
      return exact
    }
    if let prefixed = installed
      .filter({ $0.name.lowercased().hasPrefix(wanted) })
      .min(by: { $0.name.count < $1.name.count }) {
      return prefixed
    }
    return installed
      .filter { $0.name.lowercased().contains(wanted) }
      .min(by: { $0.name.count < $1.name.count })
  }

  private static func applications() -> [Application] {
    let folders = [
      "/Applications",
      "/Applications/Utilities",
      "/System/Applications",
      "/System/Applications/Utilities",
      NSHomeDirectory() + "/Applications",
    ]

    var found: [Application] = []
    for folder in folders {
      let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
      for entry in contents where entry.hasSuffix(".app") {
        found.append(
          Application(
            name: String(entry.dropLast(4)),
            url: URL(fileURLWithPath: folder).appendingPathComponent(entry)
          )
        )
      }
    }
    return found
  }

  private static func scroll(lines: Int) {
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
}
