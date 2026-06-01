import AppKit
import AVFoundation
import Foundation

extension HoldToTalkController {
    func currentInsertionTargetApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication, !isSelfApplication(frontmost) {
            updateLastTargetApplication(frontmost)
            return frontmost
        }

        return lastTargetApplication
    }

    func updateLastTargetApplication(_ application: NSRunningApplication) {
        guard !isSelfApplication(application), !application.isTerminated else { return }

        lastTargetApplication = application
        targetAppText = application.localizedName ?? application.bundleIdentifier ?? L10n.tr("Unknown")
    }

    func isSelfApplication(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || application.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func beginTranscription() {
        pendingTranscriptionCount += 1
        isTranscribing = true

        if !isRecording {
            statusMessage = pendingTranscriptionCount > 1
                ? L10n.tr("Transcribing queued recordings...")
                : recognitionEngine.isCloud
                    ? L10n.tr("Waiting for cloud final result...")
                    : L10n.tr("Transcribing with sherpa-onnx...")
        }
    }

    func finishTranscription(finalStatus: String) {
        pendingTranscriptionCount = max(0, pendingTranscriptionCount - 1)
        isTranscribing = pendingTranscriptionCount > 0

        if isRecording {
            return
        }

        if isTranscribing {
            statusMessage = L10n.tr("Transcribing queued recordings...")
        } else {
            statusMessage = rearmKeyMonitorAfterTurn() ?? finalStatus
        }
    }

    func rearmKeyMonitorAfterTurn() -> String? {
        guard isEnabled, missingKeyboardPermissionNames().isEmpty else { return nil }

        do {
            try keyMonitor.rearm()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func preserveLastRecording(_ url: URL) {
        let debugURL = FileManager.default.temporaryDirectory.appendingPathComponent("HoldToTalk-last.wav")
        try? FileManager.default.removeItem(at: debugURL)
        try? FileManager.default.copyItem(at: url, to: debugURL)
    }

    func updateLastRecordingInfo(
        audioURL: URL,
        trigger: String,
        captureSummary: String,
        inputDevice: String
    ) {
        preserveLastRecording(audioURL)

        do {
            let stats = try RecordedAudioAnalyzer.analyze(url: audioURL)
            hasRecordingInfo = true
            lastRecordingInfo = L10n.tr("%@, %@, %@, input %@", stats.summary, localizedTriggerName(trigger), captureSummary, inputDevice)
        } catch {
            hasRecordingInfo = true
            lastRecordingInfo = L10n.tr("%@, %@, input %@, audio analysis failed: %@", localizedTriggerName(trigger), captureSummary, inputDevice, error.localizedDescription)
        }
    }

    func removeTrailingSentencePeriod(from text: String) -> String {
        guard text.last == "。" else { return text }
        return String(text.dropLast())
    }

    func finalizedTranscriptText(
        from rawText: String,
        shouldRemoveTrailingSentencePeriod: Bool
    ) -> String {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldRemoveTrailingSentencePeriod else { return trimmedText }
        return removeTrailingSentencePeriod(from: trimmedText)
    }

    func localizedTriggerName(_ trigger: String) -> String {
        trigger == Self.manualRecordingTrigger ? L10n.tr("Manual") : trigger
    }

    func refreshCurrentStatusMessage() {
        if isRecording {
            statusMessage = recordingTrigger == Self.manualRecordingTrigger
                ? L10n.tr("Manual recording...")
                : L10n.tr("Recording while %@ is held.", recordingTrigger)
            return
        }

        if isTranscribing {
            statusMessage = pendingTranscriptionCount > 1
                ? L10n.tr("Transcribing queued recordings...")
                : recognitionEngine.isCloud
                    ? L10n.tr("Waiting for cloud final result...")
                    : L10n.tr("Transcribing with sherpa-onnx...")
            return
        }

        if isRecordingShortcut {
            statusMessage = L10n.tr("Press the shortcut to use for hold-to-talk.")
            return
        }

        let missingPermissions = missingKeyboardPermissionNames()
        if !missingPermissions.isEmpty {
            statusMessage = L10n.tr(
                "Grant %@ permission, then hold %@.",
                missingPermissions.joined(separator: L10n.tr(" and ")),
                holdShortcut.displayName
            )
            return
        }

        if !isEnabled {
            statusMessage = L10n.tr("Paused.")
            return
        }

        if preferredRecognitionEngine.isCloud, needsAPIKey(for: preferredRecognitionEngine) {
            statusMessage = L10n.tr("Using local recognition. Add an API key to enable cloud recognition.")
            return
        }

        statusMessage = L10n.tr("Listening for %@.", holdShortcut.displayName)
    }

    static func loadHoldShortcut() -> HoldShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: "HoldToTalk.holdShortcut"),
            let shortcut = try? JSONDecoder().decode(HoldShortcut.self, from: data)
        else {
            return .defaultShortcut
        }
        return shortcut
    }

    func saveHoldShortcut(_ shortcut: HoldShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: shortcutDefaultsKey)
    }

    static func loadInputDeviceUID() -> String {
        UserDefaults.standard.string(forKey: inputDeviceDefaultsKey) ?? ""
    }

    func setInputDeviceUID(_ uid: String) {
        selectedInputDeviceUID = uid
    }

    func refreshInputDeviceState() {
        availableInputDevices = AudioDeviceInspector.inputDevices()
        setIfChanged(\.inputDeviceText, AudioDeviceInspector.inputDeviceDisplayName(selectedUID: selectedInputDeviceUID))
    }

    static func loadRemovesTrailingSentencePeriod() -> Bool {
        guard UserDefaults.standard.object(forKey: removesTrailingSentencePeriodDefaultsKey) != nil else {
            return true
        }

        return UserDefaults.standard.bool(forKey: removesTrailingSentencePeriodDefaultsKey)
    }

    func recognitionEngineDidChange() {
        setPreferredRecognitionEngine(preferredRecognitionEngine)
    }

}

extension HoldToTalkController: GlobalFnKeyMonitorDelegate {
    nonisolated func globalFnKeyMonitor(_ monitor: GlobalFnKeyMonitor, didChangeFnKeyDown isDown: Bool) {
        Task { @MainActor in
            self.handleShortcutChanged(isDown: isDown)
        }
    }

    static func loadLocalSpeechModel() -> LocalSpeechModel {
        guard let id = UserDefaults.standard.string(forKey: "HoldToTalk.localSpeechModel") else {
            return .defaultModel
        }

        return LocalSpeechModel.model(id: id)
    }
}
