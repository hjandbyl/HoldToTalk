import AppKit
import SwiftUI

@main
struct HoldToTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller: HoldToTalkController = .shared
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
            MenuBarContent(controller: controller)
                .environment(\.locale, appLanguage.locale)
        } label: {
            MenuBarStatusIcon(imageName: controller.menuBarTemplateIconName)
        }
        .menuBarExtraStyle(.menu)
    }

    private var mainWindowScene: some Scene {
        Window("HoldToTalk", id: "main") {
            ContentView(controller: controller)
                .frame(minWidth: 880, minHeight: 660)
                .environment(\.locale, appLanguage.locale)
                .onChange(of: appLanguageID) { _, _ in
                    controller.appLanguageDidChange()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    guard appLanguage == .system else { return }
                    localeRefreshToken = UUID()
                    controller.appLanguageDidChange()
                }
                .onChange(of: appDisplayModeID) { _, _ in
                    applyAppDisplayMode(appDisplayMode)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {}
        }
    }
}

private struct MenuBarStatusIcon: View {
    let imageName: String

    var body: some View {
        if let image = MenuBarIconProvider.image(named: imageName) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .accessibilityLabel("HoldToTalk")
        } else {
            Image(systemName: "mic")
                .accessibilityLabel("HoldToTalk")
        }
    }
}

@MainActor
private enum MenuBarIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        if let image = NSImage(named: name) ?? resourceImage(named: name) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            cache[name] = image
            return image
        }

        return nil
    }

    private static func resourceImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }

        return NSImage(contentsOf: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppDisplayMode(AppDisplayModePreference.savedMode())
        Task { @MainActor in
            await HoldToTalkController.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private func applyAppDisplayMode(_ mode: AppDisplayMode) {
    AppDisplayModePreference.apply(mode: mode)
}
