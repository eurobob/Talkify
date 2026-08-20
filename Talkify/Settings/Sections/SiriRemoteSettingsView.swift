import AppKit
import SwiftUI

/// The Siri Remote section: whether the remote drives dictation, which
/// microphone a remote-started session records from, and what each button
/// does.
struct SiriRemoteSettingsView: View {
  @Bindable var settings: AppSettings

  /// Read when the section appears. Enumerating CoreAudio on every redraw
  /// would hit the hardware for a list that changes rarely.
  @State private var inputDeviceNames: [String] = []
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

        SettingsPickerRow(
          title: "Remote microphone",
          description: "macOS does not publish the remote's microphone, so a "
            + "bridge process publishes it under this name. Sessions the "
            + "keyboard starts are unaffected and keep the system default.",
          options: inputDeviceNames,
          optionLabel: { $0 },
          selection: $settings.siriRemoteInputDeviceName,
          controlWidth: 200
        )
        .disabled(!settings.siriRemoteEnabled)
      }

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

        ForEach(configurableButtons, id: \.self) { button in
          buttonRow(button)
        }
      }
      .disabled(!settings.siriRemoteEnabled)
    }
    .onAppear { reloadInputDevices() }
    .onDisappear { disarmRecorder() }
  }

  /// Every button the user may bind. The Siri button is not one of them.
  private var configurableButtons: [SiriRemoteButtonMonitor.Button] {
    SiriRemoteButtonMonitor.Button.allCases.filter { $0 != .siri }
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

  /// The stored pick stays in the list even when its device is absent,
  /// which is the normal state while the bridge is not running. Dropping it
  /// would leave the picker blank and silently rewrite the user's choice.
  private func reloadInputDevices() {
    var names = AudioInputDevice.available().map(\.name)
    if !names.contains(settings.siriRemoteInputDeviceName) {
      names.append(settings.siriRemoteInputDeviceName)
    }
    inputDeviceNames = names
  }
}
