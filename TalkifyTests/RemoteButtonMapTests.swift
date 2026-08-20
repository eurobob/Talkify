import Testing

@testable import Talkify

struct RemoteButtonMapTests {
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

  @Test func aChangedMapSurvivesItsJSONRoundTrip() {
    var map = RemoteButtonMap.standard
    map[.playPause] = .missionControl
    map[.tv] = .spotlight

    let restored = RemoteButtonMap(json: map.json)
    #expect(restored == map)
    #expect(restored?[.playPause] == .missionControl)
    #expect(restored?[.tv] == .spotlight)
  }

  /// A map written by a build that knew more buttons or more actions must
  /// lose only the parts this build cannot name, never fail to load.
  @Test func anUnknownButtonOrActionIsDroppedRatherThanFailingTheMap() {
    let json = """
    {"siri":"dictateHold","teleport":"dictateHold","tv":"summonADragon"}
    """
    let map = RemoteButtonMap(json: json)
    #expect(map?[.siri] == .dictateHold)
    // Spelled out: a bare `.none` here reads as Optional.none, which would
    // assert the whole map failed to load rather than that this one button
    // is unbound.
    #expect(map?[.tv] == RemoteButtonAction.none)
  }

  @Test func malformedJSONLoadsNothingSoTheDefaultCanTakeOver() {
    #expect(RemoteButtonMap(json: "not json at all") == nil)
  }

  /// Only hold-to-talk cares about the release. If another action did, one
  /// press would run it twice.
  @Test func onlyHoldToTalkActsOnTheRelease() {
    for action in RemoteButtonAction.allCases {
      #expect(action.needsRelease == (action == .dictateHold))
    }
  }
}
