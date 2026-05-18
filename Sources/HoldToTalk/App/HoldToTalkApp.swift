import AppKit
import SwiftUI

@main
struct HoldToTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller: HoldToTalkController = .shared

    var body: some Scene {
        WindowGroup("HoldToTalk", id: "main") {
            ContentView(controller: controller)
                .frame(minWidth: 520, minHeight: 420)
                .task {
                    await controller.start()
                }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            Label("HoldToTalk", systemImage: controller.menuBarSystemImage)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
