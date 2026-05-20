import Foundation

enum AppVersion {
    private static let fallbackVersionString = "Development"

    static var displayText: String {
        L10n.tr("Version %@", versionString)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildNumber = nonEmpty(info?["CFBundleVersion"] as? String)
        let version = nonEmpty(shortVersion) ?? fallbackVersionString

        guard let buildNumber, buildNumber != version else {
            return version
        }

        return "\(version) (\(buildNumber))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}
