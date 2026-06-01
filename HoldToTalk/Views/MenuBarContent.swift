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

            Divider()

            Text(AppVersion.displayText)

            Button(L10n.tr("Quit")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
