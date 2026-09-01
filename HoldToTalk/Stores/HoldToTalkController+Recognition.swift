import AppKit
import AVFoundation
import Foundation

extension HoldToTalkController {
    func setIfChanged(_ keyPath: ReferenceWritableKeyPath<HoldToTalkController, String>, _ newValue: String) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }

    func refreshVolcengineAPIKeyState() {
        hasVolcengineAPIKey = VolcengineCredentialStore.apiKey() != nil
        setIfChanged(\.volcengineAPIKeyStatusText, hasVolcengineAPIKey ? L10n.tr("Saved in Keychain") : L10n.tr("Not set"))
    }

    func refreshQwenASRAPIKeyState() {
        hasQwenASRAPIKey = QwenASRCredentialStore.apiKey() != nil
        setIfChanged(\.qwenASRAPIKeyStatusText, hasQwenASRAPIKey ? L10n.tr("Saved in Keychain") : L10n.tr("Not set"))
    }

    func needsAPIKey(for engine: RecognitionEngine) -> Bool {
        switch engine {
        case .volcengine:
            return needsVolcengineAPIKey
        case .qwenASR:
            return needsQwenASRAPIKey
        case .sherpaOnnx:
            return false
        }
    }

    func language(for engine: RecognitionEngine) -> TranscriptionLanguage {
        switch engine {
        case .volcengine:
            return TranscriptionLanguage.volcengineLanguages.contains(volcengineLanguage) ? volcengineLanguage : .auto
        case .qwenASR:
            return TranscriptionLanguage.qwenASRLanguages.contains(qwenASRLanguage) ? qwenASRLanguage : .auto
        case .sherpaOnnx:
            return selectedLocalSpeechModel.supportedLanguages.contains(sherpaOnnxLanguage) ? sherpaOnnxLanguage : .auto
        }
    }

    func availableLanguages(for engine: RecognitionEngine) -> [TranscriptionLanguage] {
        switch engine {
        case .volcengine:
            return TranscriptionLanguage.volcengineLanguages
        case .qwenASR:
            return TranscriptionLanguage.qwenASRLanguages
        case .sherpaOnnx:
            return selectedLocalSpeechModel.supportedLanguages
        }
    }

    func ensureRecognitionEngineAvailable() {
        if recognitionEngine.isCloud, needsAPIKey(for: recognitionEngine) {
            fallbackToLocalRecognitionForMissingAPIKey()
        }
    }

    func fallbackToLocalRecognitionForMissingAPIKey() {
        guard preferredRecognitionEngine.isCloud, needsAPIKey(for: preferredRecognitionEngine) else { return }

        if recognitionEngine != .sherpaOnnx {
            recognitionEngine = .sherpaOnnx
        }

        resetCloudSession()
        if isSelectedLocalSpeechModelInstalled {
            prewarmRecognizer()
        }

        if !isRecording, !isTranscribing {
            statusMessage = L10n.tr("Using local recognition. Add an API key to enable cloud recognition.")
        }
    }

    func resetCloudSession() {
        cloudPreconnectTask?.cancel()
        cloudStartTask?.cancel()
        cloudSendTask?.cancel()
        cloudPreconnectTask = nil
        cloudStartTask = nil
        cloudSendTask = nil
        bufferedCloudChunks.removeAll(keepingCapacity: true)
        isCloudSessionReady = false
        cloudSessionEngine = nil
        cloudSessionLanguage = nil
        Task { [cloudTranscriber] in
            await cloudTranscriber.cancel()
        }
        Task { [qwenASRTranscriber] in
            await qwenASRTranscriber.cancel()
        }
    }

    func startKeyMonitor() {
        let missingPermissions = missingKeyboardPermissionNames()
        guard missingPermissions.isEmpty else {
            statusMessage = L10n.tr(
                "Grant %@ permission, then hold %@.",
                missingPermissions.joined(separator: L10n.tr(" and ")),
                holdShortcut.displayName
            )
            refreshPermissionStatus()
            return
        }

        do {
            try keyMonitor.start()
            statusMessage = isEnabled ? L10n.tr("Listening for %@.", holdShortcut.displayName) : L10n.tr("Paused.")
        } catch {
            statusMessage = error.localizedDescription
        }
        refreshPermissionStatus()
    }

    func startPermissionPolling() {
        guard permissionRefreshTask == nil else { return }
        guard requiresFrequentPermissionPolling else { return }

        permissionRefreshTask = Task { [weak self] in
            defer { self?.permissionRefreshTask = nil }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))

                guard let self, !Task.isCancelled else { return }
                self.refreshPermissionStatus()

                if self.isEnabled, !self.keyMonitor.isRunning, self.missingKeyboardPermissionNames().isEmpty {
                    self.startKeyMonitor()
                }

                guard self.requiresFrequentPermissionPolling else { return }
            }
        }
    }

    var requiresFrequentPermissionPolling: Bool {
        needsMicrophonePermission
            || needsAccessibilityPermission
            || (isEnabled && !keyMonitor.isRunning)
    }

    func applicationDidBecomeActive() {
        refreshPermissionStatus()
        refreshLocalSpeechModelStatus()

        if isEnabled, !keyMonitor.isRunning, missingKeyboardPermissionNames().isEmpty {
            startKeyMonitor()
        }

        startPermissionPolling()
    }

    func startInputDeviceMonitoring() {
        inputDeviceMonitor.start { [weak self] in
            Task { @MainActor in
                self?.refreshInputDeviceState()
            }
        }
    }

    func startForegroundAppTracking() {
        guard activationObserver == nil else { return }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }

            Task { @MainActor in
                self.updateLastTargetApplication(application)
            }
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            updateLastTargetApplication(frontmost)
        }
    }

    func prewarmRecognizer() {
        guard recognizerPrewarmTask == nil else { return }
        guard isSelectedLocalSpeechModelInstalled else {
            statusMessage = L10n.tr("Download %@ before using local recognition.", selectedLocalSpeechModel.displayTitle)
            return
        }

        if isEnabled, !isRecording, !isTranscribing, missingKeyboardPermissionNames().isEmpty {
            statusMessage = L10n.tr("Preparing sherpa-onnx...")
        }

        recognizerPrewarmTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.transcriber.preload(model: self.selectedLocalSpeechModel)

                if self.isEnabled, !self.isRecording, !self.isTranscribing, self.missingKeyboardPermissionNames().isEmpty {
                    self.statusMessage = L10n.tr("Listening for %@. sherpa-onnx ready.", self.holdShortcut.displayName)
                }
            } catch {
                if !self.isRecording, !self.isTranscribing {
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func missingKeyboardPermissionNames() -> [String] {
        var names: [String] = []

        if !hasAccessibilityPermission {
            names.append(L10n.tr("Accessibility"))
        }

        return names
    }

}
