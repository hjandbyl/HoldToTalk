import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    static let storageKey = "HoldToTalk.appLanguage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.tr("Follow System Language")
        case .english:
            return L10n.tr("English")
        case .simplifiedChinese:
            return L10n.tr("Simplified Chinese")
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return Locale(identifier: Self.systemLocalizationIdentifier())
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }

    var localizationIdentifier: String {
        switch self {
        case .system:
            return Self.systemLocalizationIdentifier()
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    static var current: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    private static func systemLocalizationIdentifier() -> String {
        let preferredLanguage = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferredLanguage.hasPrefix("zh") ? "zh-Hans" : "en"
    }
}
