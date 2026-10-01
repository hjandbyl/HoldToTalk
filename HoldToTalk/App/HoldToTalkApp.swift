import AppKit
import SwiftUI

@main
struct HoldToTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var environment: AppEnvironment { appDelegate.environment }
    @State private var localeRefreshToken = UUID()
    @AppStorage(AppLanguage.storageKey) private var appLanguageID = AppLanguage.system.rawValue
    @AppStorage(AppDisplayModePreference.storageKey) private var appDisplayModeID = AppDisplayModePreference.savedMode().rawValue

    private var appLanguage: AppLanguage {
        _ = localeRefreshToken
        return AppLanguage(rawValue: appLanguageID) ?? .system
    }

    private var appDisplayMode: AppDisplayMode {
        AppDisplayMode(rawValue: appDisplayModeID) ?? AppDisplayModePreference.defaultMode
    }

    @SceneBuilder
    var body: some Scene {
        mainWindowScene
        menuBarScene
    }

    private var statusItemIsInserted: Binding<Bool> {
        Binding {
            appDisplayMode.showsStatusItem
        } set: { _ in
        }
    }

    private var menuBarScene: some Scene {
        MenuBarExtra(isInserted: statusItemIsInserted) {
            MenuBarContent(environment: environment)
                .environment(\.locale, appLanguage.locale)
        } label: {
            MenuBarStatusIcon(recording: environment.recording)
        }
        .menuBarExtraStyle(.window)
    }

    private var mainWindowScene: some Scene {
        Window("HoldToTalk", id: "main") {
            ContentView(environment: environment)
                .frame(minWidth: 880, minHeight: 660)
                .environment(\.locale, appLanguage.locale)
                .onChange(of: appLanguageID) { _, _ in
                    environment.appLanguageDidChange()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    guard appLanguage == .system else { return }
                    localeRefreshToken = UUID()
                    environment.appLanguageDidChange()
                }
                .onChange(of: appDisplayModeID) { _, _ in
                    applyAppDisplayMode(appDisplayMode)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {}
        }
    }
}

private struct MenuBarStatusIcon: View {
    @ObservedObject var recording: RecordingStore

    var body: some View {
        Image(recording.menuBarIconAssetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 19, height: 19, alignment: .center)
            .accessibilityLabel("HoldToTalk")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppDisplayMode(AppDisplayModePreference.savedMode())
        Task { @MainActor in
            environment.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            environment.applicationDidBecomeActive()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await environment.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private func applyAppDisplayMode(_ mode: AppDisplayMode) {
    AppDisplayModePreference.apply(mode: mode)
}
