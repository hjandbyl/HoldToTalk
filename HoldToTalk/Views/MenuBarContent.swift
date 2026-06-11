import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var controller: HoldToTalkController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button(L10n.tr("Open HoldToTalk")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Text(controller.statusMessage)
                .lineLimit(1)

            Button(controller.isEnabled ? L10n.tr("Pause Listening") : L10n.tr("Resume Listening")) {
                controller.setListeningEnabled(!controller.isEnabled)
            }

            Menu(microphoneMenuTitle) {
                inputDeviceMenuItem(
                    title: L10n.tr("Auto (%@)", AudioDeviceInspector.defaultInputDeviceName()),
                    uid: ""
                )

                ForEach(controller.availableInputDevices) { device in
                    inputDeviceMenuItem(title: device.name, uid: device.id)
                }

                Divider()

                Button(L10n.tr("Refresh")) {
                    controller.refreshInputDeviceState()
                }
            }
            .disabled(controller.isRecording)

            Divider()

            Text(AppVersion.displayText)

            Button(L10n.tr("Quit")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
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
