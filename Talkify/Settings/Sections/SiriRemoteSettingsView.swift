import AppKit
import SwiftUI

/// The Siri Remote section: whether the remote drives dictation, which
/// microphone a remote-started session records from, and what each button
/// does.
struct SiriRemoteSettingsView: View {
  @Bindable var settings: AppSettings

  /// Read when the section appears and after an install, rather than on
  /// every redraw: asking launchd is not free.
  @State private var helperState: VoiceHelperInstaller.State = .notInstalled
  @State private var helperError: String?
  /// Which button's recorder is armed, if any. One at a time, so a keypress
  /// can never land in two bindings at once.
  @State private var recordingButton: SiriRemoteButtonMonitor.Button?

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Remote") {
        SettingsRow(
          title: "Use the Siri Remote",
          description: "Read the remote's buttons and dictate from its "
            + "microphone. Needs Input Monitoring, the same permission the "
            + "keyboard trigger uses."
        ) {
          Toggle("Use the Siri Remote", isOn: $settings.siriRemoteEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsRow(
          title: "Start at login",
          description: "The microphone helper starts at boot on its own, but "
            + "it feeds nothing unless Talkify is running. Without this the "
            + "remote is dead after every restart until you open the app."
        ) {
          Toggle("Start at login", isOn: $settings.startAtLogin)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsRow(
          title: "Microphone helper",
          description: helperDescription
        ) {
          switch helperState {
          case .installed:
            Text("Installed")
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(.white.opacity(0.6))
          case .awaitingApproval:
            Button("Open Settings") { VoiceHelperInstaller.openApprovalSettings() }
              .buttonStyle(SettingsButtonStyle())
          case .notInstalled:
            Button("Install") { installHelper() }
              .buttonStyle(SettingsButtonStyle())
          case .missingFromBundle:
            Text("Missing")
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(.white.opacity(0.6))
          }
        }
        .disabled(!settings.siriRemoteEnabled)
      }

      SettingsCard(title: "Clickpad") {
        SettingsRow(
          title: "Move the pointer",
          description: "Swipe the remote's clickpad to move the pointer, and "
            + "press it to click. The pointer holds still while the pad is "
            + "pressed, so a click lands where you aimed rather than where "
            + "your finger slid to."
        ) {
          Toggle("Move the pointer", isOn: $settings.siriRemoteTrackpadEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsRow(
          title: "Pointer speed",
          description: "The slow end. A quick swipe is amplified on top of "
            + "this, so a careful movement can still land on a button while a "
            + "fast one crosses the screen."
        ) {
          Slider(
            value: $settings.siriRemoteTrackpadSpeed,
            in: 120...1200
          )
          .frame(width: 180)
        }
        .disabled(!settings.siriRemoteTrackpadEnabled)

        SettingsRow(
          title: "Circle the rim to scroll",
          description: "Trace the outer edge of the pad to scroll, the way a "
            + "click wheel does. The middle of the pad still moves the "
            + "pointer, and where your finger lands decides which it is."
        ) {
          Toggle("Circle the rim to scroll", isOn: $settings.siriRemoteRingScroll)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .disabled(!settings.siriRemoteTrackpadEnabled)

        SettingsRow(
          title: "Tap to click",
          description: "A quick touch that does not travel clicks, without "
            + "pressing the pad down."
        ) {
          Toggle("Tap to click", isOn: $settings.siriRemoteTapToClick)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .disabled(!settings.siriRemoteTrackpadEnabled)
      }
      .disabled(!settings.siriRemoteEnabled)

      SettingsCard(title: "Buttons") {
        SettingsRow(
          title: "What each button does",
          description: "Choose \"Send keys…\" and record any combination, and "
            + "the button presses it. A button left on \"Leave to macOS\" keeps "
            + "working the way it always did: Talkify reads the remote without "
            + "taking it over, so the volume, mute and transport keys still "
            + "reach the system on their own. Mission Control and the rest are "
            + "named here because macOS swallows their shortcuts before a "
            + "recorder can capture them."
        ) {
          Button("Reset") {
            recordingButton = nil
            settings.isRecordingKeybind = false
            settings.siriRemoteButtonMap = .standard
          }
          .buttonStyle(SettingsButtonStyle())
        }

        SettingsRow(
          title: SiriRemoteButtonMonitor.Button.siri.title,
          description: "Holds to dictate. This one is fixed: it is the button "
            + "with the microphone behind it."
        ) {
          Text("Dictate while held")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
        }

        if settings.siriRemoteTrackpadEnabled {
          SettingsRow(
            title: SiriRemoteButtonMonitor.Button.select.title,
            description: "Clicks, while the clickpad moves the pointer."
          ) {
            Text("Click")
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(.white.opacity(0.6))
          }
        }

        ForEach(configurableButtons, id: \.self) { button in
          buttonRow(button)
        }
      }
      .disabled(!settings.siriRemoteEnabled)
    }
    .onAppear { helperState = VoiceHelperInstaller.state }
    .onDisappear { disarmRecorder() }
  }

  /// Every button the user may bind. The Siri button is not one of them.
  private var configurableButtons: [SiriRemoteButtonMonitor.Button] {
    SiriRemoteButtonMonitor.Button.allCases.filter { button in
      // Siri always dictates. The clickpad's press is the click while the
      // pointer is on, and binding it as well would fire both.
      if button == .siri { return false }
      if button == .select, settings.siriRemoteTrackpadEnabled { return false }
      return true
    }
  }

  @ViewBuilder
  private func buttonRow(_ button: SiriRemoteButtonMonitor.Button) -> some View {
    SettingsPickerRow(
      title: button.title,
      options: RemoteButtonAction.Kind.allCases,
      optionLabel: { $0.title },
      selection: kindBinding(for: button),
      controlWidth: 200
    )

    if settings.siriRemoteButtonMap[button].kind == .sendKeys {
      SettingsRow(
        title: "  Keys",
        description: recordingButton == button
          ? "Press the combination you want this button to send."
          : "The combination this button presses."
      ) {
        KeyRecorderView(
          keyBinding: keysBinding(for: button),
          // A bare modifier has nothing to press, so it cannot be sent.
          allowsBareModifier: false,
          isRecording: recordingBinding(for: button),
          onRecordingChanged: { settings.isRecordingKeybind = $0 },
          label: { binding, isArmed in
            Text(isArmed ? "…" : binding.label)
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .frame(minWidth: 64)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .fill(.white.opacity(isArmed ? 0.22 : 0.10))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(.white.opacity(isArmed ? 0.5 : 0.18))
              )
              .contentShape(Rectangle())
          }
        )
      }
    }
  }

  private func kindBinding(
    for button: SiriRemoteButtonMonitor.Button
  ) -> Binding<RemoteButtonAction.Kind> {
    Binding(
      get: { settings.siriRemoteButtonMap[button].kind },
      set: { kind in
        // Switching a button away from Send keys and back keeps whatever it
        // had recorded, rather than making the user record it twice.
        let current = settings.siriRemoteButtonMap[button]
        settings.siriRemoteButtonMap[button] = current.withKind(
          kind,
          recorded: current.recordedKeyBinding ?? .optionEscape
        )
        if kind != .sendKeys, recordingButton == button { disarmRecorder() }
      }
    )
  }

  private func keysBinding(
    for button: SiriRemoteButtonMonitor.Button
  ) -> Binding<KeyBinding> {
    Binding(
      get: { settings.siriRemoteButtonMap[button].recordedKeyBinding ?? .optionEscape },
      set: { settings.siriRemoteButtonMap[button] = .sendKeys($0) }
    )
  }

  private func recordingBinding(
    for button: SiriRemoteButtonMonitor.Button
  ) -> Binding<Bool> {
    Binding(
      get: { recordingButton == button },
      set: { recordingButton = $0 ? button : nil }
    )
  }

  /// Leaving the section with a recorder armed would keep the dictation
  /// trigger suspended with nothing on screen to explain it.
  private func disarmRecorder() {
    recordingButton = nil
    settings.isRecordingKeybind = false
  }

  private var helperDescription: String {
    if let helperError {
      return "Could not install it: \(helperError)"
    }
    switch helperState {
    case .installed:
      return "The remote's microphone is ready whenever Talkify is running, "
        + "including after a restart."
    case .awaitingApproval:
      return "macOS needs your approval. Allow \"Talkify Remote\" under "
        + "Login Items & Extensions, then come back here."
    case .notInstalled:
      return "macOS lets only a privileged helper read the Bluetooth link, so "
        + "the remote's microphone needs one installed once. macOS will ask "
        + "you to approve it."
    case .missingFromBundle:
      return "This build does not contain the helper, so the remote's "
        + "microphone cannot work. Rebuild the app."
    }
  }

  private func installHelper() {
    switch VoiceHelperInstaller.install() {
    case let .success(state):
      helperState = state
      helperError = nil
    case let .failure(error):
      helperState = VoiceHelperInstaller.state
      helperError = error.localizedDescription
    }
  }
}
