import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var controller: HoldToTalkController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open HoldToTalk") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Text(controller.statusMessage)
            .lineLimit(1)

        Button(controller.isEnabled ? "Pause Listening" : "Resume Listening") {
            controller.setListeningEnabled(!controller.isEnabled)
        }

        Button("Request Permissions") {
            controller.requestAccessibilityPermission()
            controller.requestInputMonitoringPermission()
            controller.requestMicrophonePermission()
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
