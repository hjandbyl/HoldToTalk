import ApplicationServices
import AVFoundation
import AppKit
import Foundation

enum PermissionHelper {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var microphoneStatusText: String {
        microphoneStatusText(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    static func microphoneStatusText(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return L10n.tr("Granted")
        case .denied:
            return L10n.tr("Denied")
        case .restricted:
            return L10n.tr("Restricted")
        case .notDetermined:
            return L10n.tr("Not requested")
        @unknown default:
            return L10n.tr("Unknown")
        }
    }

    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openMicrophoneSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
