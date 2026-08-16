import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var controller: HoldToTalkController
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

            Text(controller.statusMessage)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                controller.setListeningEnabled(!controller.isEnabled)
            } label: {
                Label(
                    controller.isEnabled ? L10n.tr("Pause Listening") : L10n.tr("Resume Listening"),
                    systemImage: controller.isEnabled ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Menu {
                inputDeviceMenuItem(
                    title: L10n.tr("Auto (%@)", AudioDeviceInspector.defaultInputDeviceName()),
                    uid: ""
                )

                if controller.isSelectedInputDeviceUnavailable {
                    inputDeviceMenuItem(
                        title: controller.unavailableSelectedInputDeviceTitle,
                        uid: controller.selectedInputDeviceUID
                    )
                }

                ForEach(controller.availableInputDevices) { device in
                    inputDeviceMenuItem(title: device.name, uid: device.id)
                }

                Divider()

                Button(L10n.tr("Refresh")) {
                    controller.refreshInputDeviceState()
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
            .disabled(controller.isRecording)

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
            controller.refreshInputDeviceState()
        }
    }

    private var microphoneMenuTitle: String {
        shortMenuTitle(L10n.tr("Microphone: %@", controller.inputDeviceText))
    }

    @ViewBuilder
    private func inputDeviceMenuItem(title: String, uid: String) -> some View {
        Button {
            controller.setInputDeviceUID(uid)
        } label: {
            if controller.selectedInputDeviceUID == uid {
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
