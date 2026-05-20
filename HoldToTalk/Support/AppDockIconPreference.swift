import AppKit
import Foundation

enum AppDisplayMode: String, CaseIterable, Identifiable {
    case dock
    case statusBar
    case dockAndStatusBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock:
            return L10n.tr("Dock")
        case .statusBar:
            return L10n.tr("Status Bar")
        case .dockAndStatusBar:
            return L10n.tr("Dock + Status Bar")
        }
    }

    var showsDockIcon: Bool {
        switch self {
        case .dock, .dockAndStatusBar:
            return true
        case .statusBar:
            return false
        }
    }

    var showsStatusItem: Bool {
        switch self {
        case .statusBar, .dockAndStatusBar:
            return true
        case .dock:
            return false
        }
    }
}

enum AppDisplayModePreference {
    static let storageKey = "HoldToTalk.displayMode"
    static let defaultMode: AppDisplayMode = .statusBar

    private static let legacyShowsDockIconStorageKey = "HoldToTalk.showsDockIcon"

    static func applySavedPreference() {
        apply(mode: savedMode())
    }

    static func savedMode() -> AppDisplayMode {
        if let rawValue = UserDefaults.standard.string(forKey: storageKey),
           let mode = AppDisplayMode(rawValue: rawValue) {
            return mode
        }

        if let legacyShowsDockIcon = UserDefaults.standard.object(forKey: legacyShowsDockIconStorageKey) as? Bool {
            return legacyShowsDockIcon ? .dockAndStatusBar : .statusBar
        }

        return defaultMode
    }

    static func apply(mode: AppDisplayMode) {
        NSApp.setActivationPolicy(mode.showsDockIcon ? .regular : .accessory)
    }
}
