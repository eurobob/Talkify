import CoreGraphics
import Foundation
import Testing

@testable import Talkify

struct RemoteButtonMapTests {
  private let cmdShiftFour = KeyBinding(
    keyCode: 21,
    modifierFlags: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
    isModifierKey: false,
    label: "⌘ ⇧ 4",
    keyEquivalent: "4"
  )

  @Test func theStandardMapDictatesFromSiriAndCancelsFromBack() {
    let map = RemoteButtonMap.standard
    #expect(map[.siri] == .dictateHold)
    #expect(map[.back] == .cancelDictation)
  }

  /// Every other button belongs to macOS. Talkify reads the remote without
  /// seizing it, so a bound action on the volume or transport keys would
  /// happen on top of the one macOS already performs.
  @Test func theStandardMapLeavesEveryOtherButtonToMacOS() {
    let map = RemoteButtonMap.standard
    let bound: Set<SiriRemoteButtonMonitor.Button> = [.siri, .back]
    for button in SiriRemoteButtonMonitor.Button.allCases where !bound.contains(button) {
      #expect(map[button] == .none, "\(button.rawValue) should be unbound")
    }
  }

  @Test func aRecordedCombinationSurvivesItsJSONRoundTrip() {
    var map = RemoteButtonMap.standard
    map[.playPause] = .sendKeys(cmdShiftFour)
    map[.tv] = .readAloud

    let restored = RemoteButtonMap(json: map.json)
    #expect(restored == map)
    #expect(restored?[.playPause].keyBinding == cmdShiftFour)
    #expect(restored?[.tv] == .readAloud)
  }

  /// A map written by a build that knew more buttons must lose only the
  /// parts this build cannot name, never fail to load.
  @Test func anUnknownButtonIsDroppedRatherThanFailingTheMap() {
    var map = RemoteButtonMap.standard
    map[.tv] = .sendKeys(cmdShiftFour)
    let json = map.json.replacingOccurrences(of: "\"tv\"", with: "\"teleport\"")

    let restored = RemoteButtonMap(json: json)
    #expect(restored?[.siri] == .dictateHold)
    // Spelled out: a bare `.none` here reads as Optional.none, which would
    // assert the whole map failed to load rather than that this one button
    // is unbound.
    #expect(restored?[.tv] == RemoteButtonAction.none)
  }

  /// Send-keys with nothing recorded would be a button that claims to do
  /// something and does nothing.
  @Test func sendKeysWithoutACombinationIsDropped() {
    let json = #"{"tv":{"kind":"sendKeys"},"siri":{"kind":"dictateHold"}}"#
    let restored = RemoteButtonMap(json: json)
    #expect(restored?[.siri] == .dictateHold)
    #expect(restored?[.tv] == RemoteButtonAction.none)
  }

  @Test func malformedJSONLoadsNothingSoTheDefaultCanTakeOver() {
    #expect(RemoteButtonMap(json: "not json at all") == nil)
  }

  /// Only hold-to-talk cares about the release. If another action did, one
  /// press would run it twice.
  @Test func onlyHoldToTalkActsOnTheRelease() {
    let actions: [RemoteButtonAction] = [
      .none, .dictateHold, .dictateToggle, .cancelDictation, .readAloud,
      .sendKeys(cmdShiftFour),
    ]
    for action in actions {
      #expect(action.needsRelease == (action == .dictateHold))
    }
  }

  /// Switching a button to another action and back must not make the user
  /// record the same combination twice.
  @Test func switchingKindAwayAndBackKeepsTheRecordedCombination() {
    let sending = RemoteButtonAction.sendKeys(cmdShiftFour)
    let parked = sending.withKind(.readAloud, recorded: cmdShiftFour)
    #expect(parked == .readAloud)

    // The view passes the button's own recording back in, which is what
    // makes the combination survive the detour.
    let returned = sending.withKind(.sendKeys, recorded: .optionEscape)
    #expect(returned.keyBinding == cmdShiftFour)
  }
}
