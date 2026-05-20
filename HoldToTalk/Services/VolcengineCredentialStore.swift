import Foundation

enum VolcengineCredentialStore {
    private static let service = "HoldToTalk.volcengine"
    private static let account = "api-key"

    static func apiKey() -> String? {
        KeychainSecretStore.string(service: service, account: account)
    }

    static func saveAPIKey(_ apiKey: String) throws {
        try KeychainSecretStore.setString(apiKey, service: service, account: account)
    }

    static func deleteAPIKey() throws {
        try KeychainSecretStore.deleteString(service: service, account: account)
    }
}
