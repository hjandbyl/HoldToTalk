import Foundation

enum AppVersion {
    static let fallbackShortVersion = "0.1.2"
    static let fallbackBuildNumber = "2"

    static var displayText: String {
        L10n.tr("Version %@", versionString)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildNumber = nonEmpty(info?["CFBundleVersion"] as? String) ?? fallbackBuildNumber
        let version = nonEmpty(shortVersion) ?? fallbackShortVersion

        guard buildNumber != version else {
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
