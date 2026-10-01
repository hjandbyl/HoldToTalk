import AppKit
import AVFoundation
import Foundation

@MainActor
final class DevicePermissionStore: ObservableObject {
    @Published var availableInputDevices: [AudioInputDevice] = []
    @Published var inputDeviceText = L10n.tr("Unknown")
    @Published var microphoneStatusText = L10n.tr("Unknown")
    @Published var accessibilityStatusText = L10n.tr("Unknown")
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published var selectedInputDeviceUID: String {
        didSet {
            defaults.set(selectedInputDeviceUID, forKey: Self.inputDeviceDefaultsKey)
            if selectedInputDeviceUID.isEmpty { defaults.removeObject(forKey: Self.inputDeviceNameDefaultsKey) }
            refreshInputDeviceState()
        }
    }
    private let defaults: UserDefaults
    private let monitor = AudioInputDeviceMonitor()
    private var polling: Task<Void, Never>?
    private var recordingActive = false
    var didRefresh: (() -> Void)?
    static let inputDeviceDefaultsKey = "HoldToTalk.inputDeviceUID"
    static let inputDeviceNameDefaultsKey = "HoldToTalk.inputDeviceName"
    var needsMicrophonePermission: Bool { !hasMicrophonePermission }
    var needsAccessibilityPermission: Bool { !hasAccessibilityPermission }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedInputDeviceUID = defaults.string(forKey: Self.inputDeviceDefaultsKey) ?? ""
    }
    func start() {
        monitor.start { [weak self] in Task { @MainActor in self?.refreshInputDeviceState(); self?.didRefresh?() } }
        refresh()
    }
    func refresh() {
        refreshPermissionStatus()
        refreshInputDeviceState()
        didRefresh?()
        if polling == nil, recordingActive || needsMicrophonePermission || needsAccessibilityPermission {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    self.refreshPermissionStatus()
                    self.didRefresh?()
                    if !self.recordingActive && !self.needsMicrophonePermission && !self.needsAccessibilityPermission {
                        self.polling = nil
                        return
                    }
                }
            }
        }
    }
    func setRecordingActive(_ active: Bool) { recordingActive = active; if active { refresh() } }

    func refreshPermissionStatus() {
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if hasMicrophonePermission != (authorization == .authorized) { hasMicrophonePermission = authorization == .authorized }
        let trusted = PermissionHelper.isAccessibilityTrusted
        if hasAccessibilityPermission != trusted { hasAccessibilityPermission = trusted }
        setIfChanged(\.microphoneStatusText, PermissionHelper.microphoneStatusText(for: authorization))
        setIfChanged(\.accessibilityStatusText, hasAccessibilityPermission ? L10n.tr("Granted") : L10n.tr("Not granted"))
    }
    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func requestAccessibilityPermission() { _ = PermissionHelper.requestAccessibilityPermission(); refresh() }
    func openMicrophoneSettings() { PermissionHelper.openMicrophoneSettings(); refresh() }
    func openAccessibilitySettings() { PermissionHelper.openAccessibilitySettings(); refresh() }
    func shutdown() { polling?.cancel(); polling = nil; monitor.stop() }
    private func setIfChanged(_ key: ReferenceWritableKeyPath<DevicePermissionStore, String>, _ value: String) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }
    var isSelectedInputDeviceUnavailable: Bool {
        !selectedInputDeviceUID.isEmpty
            && !availableInputDevices.contains { $0.id == selectedInputDeviceUID }
    }

    var unavailableSelectedInputDeviceTitle: String {
        let savedName = defaults.string(forKey: Self.inputDeviceNameDefaultsKey) ?? ""
        guard !savedName.isEmpty else {
            return L10n.tr("Selected microphone unavailable")
        }
        return L10n.tr("%@ (unavailable)", savedName)
    }

    var activeInputDeviceUID: String? {
        guard !selectedInputDeviceUID.isEmpty,
              availableInputDevices.contains(where: { $0.id == selectedInputDeviceUID }) else {
            return nil
        }
        return selectedInputDeviceUID
    }

    static func loadInputDeviceUID() -> String {
        UserDefaults.standard.string(forKey: inputDeviceDefaultsKey) ?? ""
    }

    static func loadInputDeviceName() -> String {
        UserDefaults.standard.string(forKey: inputDeviceNameDefaultsKey) ?? ""
    }

    func setInputDeviceUID(_ uid: String) {
        guard !uid.isEmpty else {
            selectedInputDeviceUID = ""
            return
        }

        guard let device = AudioDeviceInspector.inputDevice(uid: uid) else { return }
        defaults.set(device.name, forKey: Self.inputDeviceNameDefaultsKey)
        selectedInputDeviceUID = uid
    }

    func refreshInputDeviceState() {
        let inputDevices = AudioDeviceInspector.inputDevices()
        if availableInputDevices != inputDevices {
            availableInputDevices = inputDevices
        }

        guard !selectedInputDeviceUID.isEmpty else {
            setIfChanged(\.inputDeviceText, AudioDeviceInspector.inputDeviceDisplayName(selectedUID: ""))
            return
        }

        if let selectedDevice = inputDevices.first(where: { $0.id == selectedInputDeviceUID }) {
            defaults.set(selectedDevice.name, forKey: Self.inputDeviceNameDefaultsKey)
            setIfChanged(\.inputDeviceText, selectedDevice.name)
            return
        }

        let savedName = defaults.string(forKey: Self.inputDeviceNameDefaultsKey) ?? ""
        let reconnectCandidates = inputDevices.filter { $0.name == savedName }
        if !savedName.isEmpty,
           reconnectCandidates.count == 1,
           let reconnectedDevice = reconnectCandidates.first {
            selectedInputDeviceUID = reconnectedDevice.id
            return
        }

        let defaultName = AudioDeviceInspector.defaultInputDeviceName()
        let unavailableText = savedName.isEmpty
            ? L10n.tr("Selected microphone unavailable; using Auto (%@)", defaultName)
            : L10n.tr("%@ unavailable; using Auto (%@)", savedName, defaultName)
        setIfChanged(\.inputDeviceText, unavailableText)
    }
}
