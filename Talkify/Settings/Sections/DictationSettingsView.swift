import AppKit
import SwiftUI

/// The Dictation section: where a finished Direct Dictation session's text
/// goes, and whether a copy is kept. Both choices are captured into the
/// session settings snapshot at session start (CONTEXT.md).
struct DictationSettingsView: View {
  @Bindable var settings: AppSettings

  private let historyStore = DictationHistoryStore()
  @State private var isConfirmingClear = false
  /// Read once when the section appears. Enumerating CoreAudio on every
  /// redraw would hit the hardware for a list that changes rarely.
  @State private var inputDeviceNames: [String] = []

  var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Insertion") {
        SettingsPickerRow(
          title: "Deliver text by",
          description: "Insert into the app pastes into the control you were "
            + "typing in and restores your clipboard, as Direct Dictation has "
            + "always worked. Copy to the clipboard never pastes. Insert and "
            + "copy pastes and leaves the text on the clipboard.",
          options: InsertionDestination.allCases,
          optionLabel: { $0.title },
          selection: $settings.insertionDestination
        )
      }

      SettingsCard(title: "Siri Remote") {
        SettingsRow(
          title: "Dictate from the Siri Remote",
          description: "Hold the remote's Siri button to dictate, and press "
            + "Back to throw the take away. Needs Input Monitoring, the same "
            + "permission the keyboard trigger uses."
        ) {
          Toggle("Dictate from the Siri Remote", isOn: $settings.siriRemoteEnabled)
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

      SettingsCard(title: "History") {
        SettingsRow(
          title: "Save transcription history",
          description: "Keep finished dictation text as daily text files you "
            + "can read in Finder. Off by default, and nothing is sent "
            + "anywhere: the files stay on this Mac."
        ) {
          Toggle("Save transcription history", isOn: $settings.dictationHistoryEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        SettingsRow(
          title: "Folder",
          description: settings.resolvedHistoryFolder.path(percentEncoded: false)
        ) {
          Button("Choose…") { chooseFolder() }
            .buttonStyle(SettingsButtonStyle())
        }
        .disabled(!settings.dictationHistoryEnabled)

        SettingsRow(
          title: "Clear history",
          description: "Delete the daily history files Talkify wrote to the "
            + "folder above. Nothing else in the folder is touched."
        ) {
          Button("Clear History…") { isConfirmingClear = true }
            .buttonStyle(SettingsButtonStyle())
        }
      }
    }
    .confirmationDialog(
      "Clear transcription history?",
      isPresented: $isConfirmingClear
    ) {
      Button("Clear History", role: .destructive) { clearHistory() }
    } message: {
      Text("This deletes every daily history file Talkify wrote to the "
        + "history folder. It cannot be undone.")
    }
    .onAppear { reloadInputDevices() }
  }

  /// The stored pick is kept in the list even when its device is absent,
  /// which is the normal state while the bridge is not running. Dropping it
  /// would leave the picker blank and silently rewrite the user's choice.
  private func reloadInputDevices() {
    var names = AudioInputDevice.available().map(\.name)
    if !names.contains(settings.siriRemoteInputDeviceName) {
      names.append(settings.siriRemoteInputDeviceName)
    }
    inputDeviceNames = names
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose where transcription history is saved."
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.dictationHistoryFolder = url
  }

  private func clearHistory() {
    let folder = settings.resolvedHistoryFolder
    Task {
      try? await historyStore.clear(folder: folder)
    }
  }
}
