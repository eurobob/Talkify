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
          description: "A button left on \"Leave to macOS\" keeps working the "
            + "way it always did. Talkify reads the remote without taking it "
            + "over, so the volume, mute and transport keys still reach the "
            + "system on their own."
        ) {
          Button("Reset") { settings.siriRemoteButtonMap = .standard }
            .buttonStyle(SettingsButtonStyle())
        }

        ForEach(SiriRemoteButtonMonitor.Button.allCases, id: \.self) { button in
          SettingsPickerRow(
            title: button.title,
            options: RemoteButtonAction.allCases,
            optionLabel: { $0.title },
            selection: binding(for: button),
            controlWidth: 200
          )
        }
      }
      .disabled(!settings.siriRemoteEnabled)
    }
    .onAppear { reloadInputDevices() }
  }

  private func binding(
    for button: SiriRemoteButtonMonitor.Button
  ) -> Binding<RemoteButtonAction> {
    Binding(
      get: { settings.siriRemoteButtonMap[button] },
      set: { settings.siriRemoteButtonMap[button] = $0 }
    )
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
