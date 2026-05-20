import AppKit
import Combine
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

    var body: some Scene {
        mainWindowScene
    }

    private var mainWindowScene: some Scene {
        WindowGroup("HoldToTalk", id: "main") {
            ContentView(controller: controller)
                .frame(minWidth: 880, minHeight: 660)
                .environment(\.locale, appLanguage.locale)
                .onChange(of: appLanguageID) { _, _ in
                    controller.appLanguageDidChange()
                    AppStatusItemController.shared.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    guard appLanguage == .system else { return }
                    localeRefreshToken = UUID()
                    controller.appLanguageDidChange()
                    AppStatusItemController.shared.refresh()
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

        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            cache[name] = image
            return image
        }

        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppDisplayMode(AppDisplayModePreference.savedMode())
        Task { @MainActor in
            await HoldToTalkController.shared.start()
        }
    }
}

@MainActor
private func applyAppDisplayMode(_ mode: AppDisplayMode) {
    AppDisplayModePreference.apply(mode: mode)
    AppStatusItemController.shared.setVisible(mode.showsStatusItem, controller: .shared)
}

@MainActor
private final class AppStatusItemController: NSObject {
    static let shared = AppStatusItemController()

    private var statusItem: NSStatusItem?
    private weak var controller: HoldToTalkController?
    private var controllerChangeCancellable: AnyCancellable?

    func setVisible(_ visible: Bool, controller: HoldToTalkController) {
        self.controller = controller

        if visible {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            observe(controller)
            refresh()
        } else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            controllerChangeCancellable = nil
        }
    }

    func refresh() {
        guard let statusItem, let controller else { return }

        if let image = MenuBarIconProvider.image(named: controller.menuBarTemplateIconName) {
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "HoldToTalk"
        }

        statusItem.menu = makeMenu(controller: controller)
    }

    private func observe(_ controller: HoldToTalkController) {
        guard controllerChangeCancellable == nil else { return }
        controllerChangeCancellable = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func makeMenu(controller: HoldToTalkController) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(menuItem(title: L10n.tr("Open HoldToTalk"), action: #selector(openHoldToTalk)))
        menu.addItem(.separator())

        let statusItem = NSMenuItem(title: controller.statusMessage, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(menuItem(
            title: controller.isEnabled ? L10n.tr("Pause Listening") : L10n.tr("Resume Listening"),
            action: #selector(toggleListening)
        ))
        menu.addItem(menuItem(title: L10n.tr("Request Permissions"), action: #selector(requestPermissions)))
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: AppVersion.displayText, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = menuItem(title: L10n.tr("Quit"), action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)

        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openHoldToTalk() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleListening() {
        guard let controller else { return }
        controller.setListeningEnabled(!controller.isEnabled)
        refresh()
    }

    @objc private func requestPermissions() {
        controller?.requestAccessibilityPermission()
        controller?.requestMicrophonePermission()
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
