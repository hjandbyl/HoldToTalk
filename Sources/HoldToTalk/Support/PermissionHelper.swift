import ApplicationServices
import AVFoundation
import AppKit
import Foundation

enum PermissionHelper {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var hasInputMonitoringPermission: Bool {
        CGPreflightListenEventAccess()
    }

    static var microphoneStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoringPermission() -> Bool {
        CGRequestListenEventAccess()
    }
}
