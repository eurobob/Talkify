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

  @Test func theStandardMapCancelsFromBack() {
    #expect(RemoteButtonMap.standard[.back] == .cancelDictation)
  }

  /// The Siri button is never in the map. It dictates, the AppDelegate
  /// routes it before the map is consulted, and an entry here would be a
  /// second opinion about a button that has none.
  @Test func theSiriButtonIsNotBindable() {
    #expect(RemoteButtonMap.standard[.siri] == .none)
    #expect(!RemoteButtonAction.Kind.allCases.map(\.title).contains { $0.contains("Dictate") })
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
    map[.tv] = .missionControl

    let restored = RemoteButtonMap(json: map.json)
    #expect(restored == map)
    #expect(restored?[.playPause].keyBinding == cmdShiftFour)
    #expect(restored?[.tv] == .missionControl)
  }

  /// A map written by a build that knew more buttons must lose only the
  /// parts this build cannot name, never fail to load.
  @Test func anUnknownButtonIsDroppedRatherThanFailingTheMap() {
    var map = RemoteButtonMap.standard
    map[.tv] = .sendKeys(cmdShiftFour)
    let json = map.json.replacingOccurrences(of: "\"tv\"", with: "\"teleport\"")

    let restored = RemoteButtonMap(json: json)
    #expect(restored?[.back] == .cancelDictation)
    // Spelled out: a bare `.none` here reads as Optional.none, which would
    // assert the whole map failed to load rather than that this one button
    // is unbound.
    #expect(restored?[.tv] == RemoteButtonAction.none)
  }

  /// Send-keys with nothing recorded would be a button that claims to do
  /// something and does nothing.
  @Test func sendKeysWithoutACombinationIsDropped() {
    let json = #"{"tv":{"kind":"sendKeys"},"back":{"kind":"cancelDictation"}}"#
    let restored = RemoteButtonMap(json: json)
    #expect(restored?[.back] == .cancelDictation)
    #expect(restored?[.tv] == RemoteButtonAction.none)
  }

  @Test func malformedJSONLoadsNothingSoTheDefaultCanTakeOver() {
    #expect(RemoteButtonMap(json: "not json at all") == nil)
  }

  /// The named actions must resolve to a real combination, or the button
  /// would be bound to nothing. Only the two app actions press no keys.
  @Test func everyNamedActionResolvesToAShortcut() {
    #expect(RemoteButtonAction.missionControl.keyBinding == .missionControl)
    #expect(RemoteButtonAction.sendKeys(cmdShiftFour).keyBinding == cmdShiftFour)
    #expect(RemoteButtonAction.none.keyBinding == nil)
    #expect(RemoteButtonAction.cancelDictation.keyBinding == nil)
  }

  /// A named action's shortcut is this app's, not the user's, so it must
  /// never be stored as if they had recorded it.
  @Test func onlyARecordedCombinationIsStored() {
    #expect(RemoteButtonAction.missionControl.recordedKeyBinding == nil)
    #expect(RemoteButtonAction.sendKeys(cmdShiftFour).recordedKeyBinding == cmdShiftFour)
  }

  /// Switching a button to another action and back must not make the user
  /// record the same combination twice.
  @Test func switchingKindAwayAndBackKeepsTheRecordedCombination() {
    let sending = RemoteButtonAction.sendKeys(cmdShiftFour)
    let parked = sending.withKind(.missionControl, recorded: cmdShiftFour)
    #expect(parked == .missionControl)

    // The view passes the button's own recording back in, which is what
    // makes the combination survive the detour.
    let returned = sending.withKind(.sendKeys, recorded: .optionEscape)
    #expect(returned.keyBinding == cmdShiftFour)
  }
}
