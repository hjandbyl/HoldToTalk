import AppKit
import SwiftUI

struct MenuBarContent: View {
    let environment: AppEnvironment
    @ObservedObject private var recording: RecordingStore
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var devices: DevicePermissionStore
    init(environment: AppEnvironment) {
        self.environment = environment
        recording = environment.recording
        settings = environment.settings
        devices = environment.devices
    }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(L10n.tr("Open HoldToTalk"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Divider()

            Text(environment.recording.statusMessage)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                environment.setListeningEnabled(!environment.settings.isEnabled)
            } label: {
                Label(
                    environment.settings.isEnabled ? L10n.tr("Pause Listening") : L10n.tr("Resume Listening"),
                    systemImage: environment.settings.isEnabled ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Menu {
                inputDeviceMenuItem(
                    title: L10n.tr("Auto (%@)", AudioDeviceInspector.defaultInputDeviceName()),
                    uid: ""
                )

                if environment.devices.isSelectedInputDeviceUnavailable {
                    inputDeviceMenuItem(
                        title: environment.devices.unavailableSelectedInputDeviceTitle,
                        uid: environment.devices.selectedInputDeviceUID
                    )
                }

                ForEach(environment.devices.availableInputDevices) { device in
                    inputDeviceMenuItem(title: device.name, uid: device.id)
                }

                Divider()

                Button(L10n.tr("Refresh")) {
                    environment.devices.refreshInputDeviceState()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                    Text(microphoneMenuTitle)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .disabled(environment.recording.isRecording)

            Divider()

            HStack {
                Text(AppVersion.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.tr("Quit")) {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            environment.devices.refreshInputDeviceState()
        }
    }

    private var microphoneMenuTitle: String {
        shortMenuTitle(L10n.tr("Microphone: %@", environment.devices.inputDeviceText))
    }

    @ViewBuilder
    private func inputDeviceMenuItem(title: String, uid: String) -> some View {
        Button {
            environment.devices.setInputDeviceUID(uid)
        } label: {
            if environment.devices.selectedInputDeviceUID == uid {
                Label(shortMenuTitle(title), systemImage: "checkmark")
            } else {
                Text(shortMenuTitle(title))
            }
        }
    }

    private func shortMenuTitle(_ title: String) -> String {
        guard title.count > 30 else { return title }
        return "\(title.prefix(27))..."
    }
}
