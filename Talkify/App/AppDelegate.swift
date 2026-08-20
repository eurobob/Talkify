import OSLog
import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var settings: AppSettings?
  private var statusItemController: StatusItemController?
  private var hudStage: HUDStage?
  private var hudController: DictationHUDController?
  private var dropTranscriptionController: DropTranscriptionController?
  private var dictationController: DirectDictationController?
  private var readAloudController: ReadAloudController?
  private var settingsWindowController: SettingsWindowController?
  private var usageTracker: UsageTracker?
  private var remoteButtonMonitor: SiriRemoteButtonMonitor?
  private let settingsRuntimeState = SettingsRuntimeState()
  private let updaterService = SparkleUpdaterService()

  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
 
 

  /// True while this process hosts the test suite rather than a user.
  ///
  /// The live launch path requests microphone and speech permissions and
  /// installs the event tap, which pops system permission dialogs over every
  /// automated test run on a machine that has not granted them. Hosting
  /// tests skips the launch entirely: tests build the objects they exercise,
  /// and a test that means to see a permission prompt drives
  /// PermissionService itself, on purpose.
  private static var isHostingTests: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestSessionIdentifier"] != nil
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !Self.isHostingTests else { return }

    // Before anything can be staged: a crash or a force-quit while a
    // transcript card was on screen leaves the user's speech in cleartext
    // under $TMPDIR, and nothing else ever removes it.
    StagedTranscript.sweep()

    let settings = AppSettings()
    self.settings = settings
    // One shape, two features. The stage owns the window and hands it out;
    // each feature's HUD controller only decides what its surface says.
    let stage = HUDStage(settings: settings)
    self.hudStage = stage
    let hudController = DictationHUDController(stage: stage, settings: settings)
    let usageTracker = UsageTracker()
    let dictationController = DirectDictationController(
      settings: settings,
      hudController: hudController,
      usageTracker: usageTracker
    )
    self.hudController = hudController
    self.dictationController = dictationController
    self.usageTracker = usageTracker

    let readAloudController = ReadAloudController(
      settings: settings,
      hudController: hudController
    )
    self.readAloudController = readAloudController

    let dropTranscriptionController = DropTranscriptionController(
      settings: settings,
      hud: DropHUDController(stage: stage)
    )
    self.dropTranscriptionController = dropTranscriptionController
    dropTranscriptionController.start()
    dropTranscriptionController.onProgressChange = { [weak self, weak settings] fraction in
      self?.statusItemController?.setTranscriptionProgress(
        fraction,
        accent: settings?.sessionSettings.dropAccent ?? SettingsTheme.accentColor
      )
    }

    let statusItemController = StatusItemController(
      toggleDictation: { dictationController.toggleFromMenu() },
      toggleReadAloud: { readAloudController.toggle() },
      transcribeFile: { dropTranscriptionController.pickFile() },
      openSettings: { [weak self] in self?.showSettings() },
      checkForUpdates: { [weak self] in self?.updaterService.checkForUpdates() }
    )
    self.statusItemController = statusItemController

    dictationController.onRecordingStateChange = {
      [weak statusItemController, weak settingsRuntimeState] isRecording, session in
      let accent = session.flatMap {
        $0.voiceVisual == .glow ? $0.glowPalette.statusAccent : nil
      }
      statusItemController?.setRecording(isRecording, accent: accent)
      settingsRuntimeState?.isDictating = isRecording
    }
    dictationController.onLanguageDownloadChange = {
      [weak settingsRuntimeState] identifier, fraction in
      settingsRuntimeState?.setDownload(identifier: identifier, fraction: fraction)
    }
    readAloudController.onSpeakingStateChange = {
      [weak statusItemController] isSpeaking in
      statusItemController?.setSpeaking(isSpeaking)
    }
    // Option+Escape toggles Read Aloud; the dictation controller owns
    // the event tap and fires this only while no session is active.
    dictationController.onReadAloudTriggered = { [weak readAloudController] in
      readAloudController?.toggle()
    }

    // Compiles the HUD's shaders now, so the cost does not land on the first
    // frames of the first dictation.
    HUDShaderWarmUp.start()

    // Requests permissions and prepares the selected Speech Model
    // shortly after launch (CONTEXT.md).
    dictationController.start()

    applyKeyBindings()
    observeKeyBindings()
    observeLanguages()
    applyRemoteInput()
    observeRemoteInput()

    // A background check is postponed while a session is running, so an update
    // window can never take focus mid-dictation and move the insertion target.
    updaterService.isBusy = { [weak settingsRuntimeState] in
      settingsRuntimeState?.isDictating ?? false
    }

    // Last: a scheduled check can show a window, and it must never land
    // before the status item and dictation are wired.
    updaterService.start()
  }

  /// Rebinding in Settings updates the event tap and the status menu
  /// hints immediately; Observation re-arms after every change. The same
  /// loop pauses trigger handling while a key recorder is armed.
  private func observeKeyBindings() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.dictationTriggerBinding
      _ = settings.secondaryTriggerBinding
      _ = settings.readAloudBinding
      _ = settings.isRecordingKeybind
      // The second trigger is only installed once a second language exists,
      // so the pick that enables it belongs in this loop too.
      _ = settings.secondaryRecognitionLocaleIdentifier
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.applyKeyBindings()
        self?.observeKeyBindings()
      }
    }
  }

  /// Changing a language in Settings re-resolves and re-warms both, so the
  /// next keypress meets a prepared analyzer rather than a cold one.
  private func observeLanguages() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.recognitionLocaleIdentifier
      _ = settings.secondaryRecognitionLocaleIdentifier
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.dictationController?.applyLanguages()
        self?.observeLanguages()
      }
    }
  }

  /// Starts or stops the Siri Remote monitor to match the setting.
  ///
  /// The remote's side button drives the same reducer events the keyboard
  /// trigger does, so a remote session is an ordinary session that records
  /// from a different microphone. Only the microphone differs.
  private func applyRemoteInput() {
    guard let settings else { return }

    guard settings.siriRemoteEnabled else {
      remoteButtonMonitor?.stop()
      remoteButtonMonitor = nil
      return
    }
    guard remoteButtonMonitor == nil else { return }

    // The remote's microphone needs a privileged helper, and asking for it
    // the moment the feature is switched on is the only honest time: the
    // user has just said they want the remote, and the alternative is a
    // button they have to find before dictation works.
    let helperState = VoiceHelperInstaller.state
    RemoteInputLog.logger.info(
      "voice helper state: \(helperState.title, privacy: .public)"
    )
    // Attempted even when the status reads "missing": that status is
    // reported for several unrelated reasons, and the error from an actual
    // attempt names the real one.
    if helperState != .installed, helperState != .awaitingApproval {
      if case let .failure(error) = VoiceHelperInstaller.install() {
        RemoteInputLog.logger.error(
          "voice helper install failed: \(String(describing: error), privacy: .public)"
        )
      }
    }

    let monitor = SiriRemoteButtonMonitor { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handleRemoteButton(event)
      }
    }
    let result = monitor.start()
    remoteButtonMonitor = monitor

    // Silence here is the worst outcome: the switch reads on, the remote
    // does nothing, and nothing on screen says why. Every failure has a
    // different fix, so each one names itself.
    guard result != .started else { return }
    hudController?.showMessage(Self.message(for: result), on: nil)
  }

  private static func message(for result: SiriRemoteButtonMonitor.StartResult) -> String {
    switch result {
    case .started:
      "Siri Remote ready"
    case .permissionDenied:
      "Talkify needs Input Monitoring for the Siri Remote"
    case .buttonsHeldByAnotherApp:
      "Another app holds the Siri Remote's buttons"
    case .noRemoteFound:
      "No Siri Remote found — wake it and try again"
    }
  }

  private func observeRemoteInput() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.siriRemoteEnabled
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.applyRemoteInput()
        self?.observeRemoteInput()
      }
    }
  }

  /// Runs whatever the user bound to the button that moved.
  ///
  /// A release only matters to hold-to-talk. Everything else happens once,
  /// on the way down, so a bound button cannot fire twice per press.
  private func handleRemoteButton(_ event: SiriRemoteButtonMonitor.Event) {
    guard let settings, let dictationController else { return }

    let button: SiriRemoteButtonMonitor.Button
    let isPress: Bool
    switch event {
    case let .pressed(pressedButton):
      button = pressedButton
      isPress = true
    case let .released(releasedButton):
      button = releasedButton
      isPress = false
    }

    // The Siri button dictates and is not configurable. It is the only
    // button with a microphone behind it, and it needs the release as well
    // as the press, which no bound keystroke does.
    guard button != .siri else {
      dictationController.handle(
        isPress ? .triggerPressed(.primary) : .triggerReleased(.primary),
        source: .siriRemote
      )
      return
    }

    // Every other button acts on the way down only, so one press cannot run
    // its action twice.
    guard isPress else { return }

    let action = settings.siriRemoteButtonMap[button]
    RemoteInputLog.logger.info(
      "routing \(button.rawValue, privacy: .public) to \(action.kind.rawValue, privacy: .public)"
    )
    switch action {
    case .cancelDictation:
      dictationController.handle(.cancelPressed, source: .siriRemote)
    case .none:
      break
    case .missionControl, .applicationWindows, .showDesktop, .spotlight, .sendKeys:
      guard let binding = action.keyBinding else { return }
      RemoteActionRunner.send(binding)
    }
  }

  private func applyKeyBindings() {
    guard let settings else { return }
    dictationController?.applyKeyBindings()
    statusItemController?.setKeyBindings(
      trigger: settings.dictationTriggerBinding,
      readAloud: settings.readAloudBinding
    )
  }

  /// A released trigger whose text has not landed yet is the one thing worth
  /// delaying a quit for: the user spoke it and expects to see it. AppKit's
  /// deferred termination is the only way to wait, because
  /// `applicationWillTerminate` is synchronous and the finish needs the main
  /// actor to make progress.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let dictationController, dictationController.isFinishing else {
      return .terminateNow
    }
    Task { @MainActor in
      await dictationController.waitForFinish(timeout: .seconds(2))
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    remoteButtonMonitor?.stop()
    dictationController?.stop()
    // A transcript the HUD is still offering only exists in its staging folder,
    // so quitting writes it out rather than losing it.
    dropTranscriptionController?.commitOfferedTranscript()
  }

  private func showSettings() {
    guard let settings, let usageTracker else { return }
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        settings: settings,
        sounds: HUDSounds(),
        runtimeState: settingsRuntimeState,
        usageTracker: usageTracker,
        updater: updaterService
      )
    }
    settingsWindowController?.show()
  }
}
