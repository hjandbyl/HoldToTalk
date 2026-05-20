import Foundation

enum AppVersion {
    static let fallbackShortVersion = "0.1.1"
    static let fallbackBuildNumber = "1"

    static var displayText: String {
        L10n.tr("Version %@", versionString)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildNumber = info?["CFBundleVersion"] as? String
        let version = nonEmpty(shortVersion) ?? fallbackShortVersion

        guard let build = nonEmpty(buildNumber), build != version else {
            return version
        }

        return "\(version) (\(build))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}
