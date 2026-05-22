import AppKit
import AVFoundation
import Foundation

extension HoldToTalkController {
    func handleShortcutChanged(isDown: Bool) {
        guard isEnabled else { return }

        hasShortcutEvent = true
        let eventTime = Date().formatted(.dateTime.hour().minute().second())
        shortcutEventText = isDown
            ? L10n.tr("%@ down %@", holdShortcut.displayName, eventTime)
            : L10n.tr("%@ up %@", holdShortcut.displayName, eventTime)

        if isDown {
            guard !isRecording else { return }
            startRecording(trigger: holdShortcut.displayName)
        } else if isRecording {
            stopRecordingAndTranscribe()
        }
    }

    func startRecording(trigger: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            statusMessage = L10n.tr("Microphone permission is required.")
            requestMicrophonePermission()
            return
        }

        ensureRecognitionEngineAvailable()

        if recognitionEngine == .sherpaOnnx, !isSelectedLocalSpeechModelInstalled {
            statusMessage = L10n.tr("Download %@ before using local recognition.", selectedLocalSpeechModel.displayTitle)
            return
        }

        do {
            activeRecognitionSessionID += 1
            let recognitionSessionID = activeRecognitionSessionID
            overlayHideTask?.cancel()
            overlayHideTask = nil
            recordingTrigger = trigger
            liveTranscript = ""
            inputLevel = 0
            recordingStartedAt = Date()
            isRecording = true
            statusMessage = trigger == Self.manualRecordingTrigger ? L10n.tr("Manual recording...") : L10n.tr("Recording while %@ is held.", trigger)
            if trigger != Self.manualRecordingTrigger {
                transcriptionOverlay.show()
            }
            let targetApplication = currentInsertionTargetApplication()
            recordingTargetApplication = targetApplication
            targetAppText = targetApplication?.localizedName ?? L10n.tr("No target app captured.")

            if recognitionEngine.isCloud {
                startCloudSession(sessionID: recognitionSessionID)
                currentRecordingURL = try recorder.start { [weak self] chunk in
                    Task { @MainActor in
                        self?.handleCloudAudioChunk(chunk)
                    }
                } levelHandler: { [weak self] level in
                    Task { @MainActor in
                        self?.handleInputLevel(level)
                    }
                }
            } else {
                currentRecordingURL = try recorder.start(levelHandler: { [weak self] level in
                    Task { @MainActor in
                        self?.handleInputLevel(level)
                    }
                })
            }
        } catch {
            isRecording = false
            recordingStartedAt = nil
            recordingTargetApplication = nil
            if trigger != Self.manualRecordingTrigger {
                transcriptionOverlay.hide()
            }
            statusMessage = L10n.tr("Could not start recording: %@", error.localizedDescription)
        }
    }

    func stopRecordingAndTranscribe() {
        let pendingCloudAudio = recognitionEngine.isCloud ? recorder.takePendingStreamingAudio() : nil
        let audioURL = recorder.stop() ?? currentRecordingURL
        let trigger = recordingTrigger
        let targetApplication = recordingTargetApplication
        let captureSummary = recorder.captureSummary
        let inputDevice = inputDeviceText
        let selectedEngine = recognitionEngine
        let recognitionSessionID = activeRecognitionSessionID
        let heldDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity

        currentRecordingURL = nil
        recordingTargetApplication = nil
        recordingStartedAt = nil
        isRecording = false
        inputLevel = 0

        guard let audioURL else {
            cancelFnTurnWithoutTranscribing(
                selectedEngine: selectedEngine,
                statusMessage: L10n.tr("Listening for %@.", holdShortcut.displayName)
            )
            return
        }

        if shouldTreatAsShortFnTap(trigger: trigger, heldDuration: heldDuration) {
            cancelFnTurnWithoutTranscribing(
                selectedEngine: selectedEngine,
                statusMessage: L10n.tr("Hold %@ a little longer to talk.", holdShortcut.displayName)
            )
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        beginTranscription()

        let selectedLanguage = language(for: selectedEngine)
        let selectedLocalModel = selectedLocalSpeechModel
        let shouldRemoveTrailingSentencePeriod = removesTrailingSentencePeriod
        Task {
            var finalStatus = L10n.tr("Transcription finished.")
            var insertion: (text: String, targetApplication: NSRunningApplication?)?

            defer {
                finishTranscription(finalStatus: finalStatus)

                if let insertion {
                    injector.insert(insertion.text, targetApplication: insertion.targetApplication)
                }

                try? FileManager.default.removeItem(at: audioURL)

                if selectedEngine.isCloud, activeRecognitionSessionID == recognitionSessionID {
                    cloudStartTask = nil
                    cloudSendTask = nil
                    isCloudSessionReady = false
                    cloudSessionEngine = nil
                    preconnectCloudSession()
                }
            }

            do {
                let text: String
                switch selectedEngine {
                case .volcengine:
                    try await cloudStartTask?.value
                    _ = await cloudSendTask?.value
                    text = TextInjector.normalizedInsertionText(
                        from: finalizedTranscriptText(
                            from: try await cloudTranscriber.finish(finalAudio: pendingCloudAudio),
                            shouldRemoveTrailingSentencePeriod: shouldRemoveTrailingSentencePeriod
                        )
                    )
                    updateLastRecordingInfo(
                        audioURL: audioURL,
                        trigger: trigger,
                        captureSummary: captureSummary,
                        inputDevice: inputDevice
                    )
                case .qwenASR:
                    try await cloudStartTask?.value
                    _ = await cloudSendTask?.value
                    text = TextInjector.normalizedInsertionText(
                        from: finalizedTranscriptText(
                            from: try await qwenASRTranscriber.finish(finalAudio: pendingCloudAudio),
                            shouldRemoveTrailingSentencePeriod: shouldRemoveTrailingSentencePeriod
                        )
                    )
                    updateLastRecordingInfo(
                        audioURL: audioURL,
                        trigger: trigger,
                        captureSummary: captureSummary,
                        inputDevice: inputDevice
                    )
                case .sherpaOnnx:
                    updateLastRecordingInfo(
                        audioURL: audioURL,
                        trigger: trigger,
                        captureSummary: captureSummary,
                        inputDevice: inputDevice
                    )
                    text = TextInjector.normalizedInsertionText(
                        from: finalizedTranscriptText(
                            from: try await transcriber.transcribe(
                                audioURL: audioURL,
                                language: selectedLanguage.sherpaOnnxLanguageCode,
                                model: selectedLocalModel
                            ),
                            shouldRemoveTrailingSentencePeriod: shouldRemoveTrailingSentencePeriod
                        )
                    )
                }

                lastTranscript = text
                if trigger != Self.manualRecordingTrigger {
                    if !text.isEmpty {
                        liveTranscript = text
                    }
                    scheduleOverlayHide(after: text.isEmpty ? 0.2 : 0.25, sessionID: recognitionSessionID)
                }

                if text.isEmpty {
                    finalStatus = L10n.tr("No speech recognized.")
                } else {
                    if autoPaste {
                        insertion = (text, targetApplication)
                    }
                    finalStatus = autoPaste ? L10n.tr("Inserted recognized text.") : L10n.tr("Transcription ready.")
                }
            } catch {
                finalStatus = error.localizedDescription
                await cloudTranscriber.cancel()
                await qwenASRTranscriber.cancel()
                if trigger != Self.manualRecordingTrigger {
                    scheduleOverlayHide(after: 0.2, sessionID: recognitionSessionID)
                }
            }
        }
    }

    func shouldTreatAsShortFnTap(trigger: String, heldDuration: TimeInterval) -> Bool {
        trigger != Self.manualRecordingTrigger
            && heldDuration < minimumFnHoldDurationForRecognition
            && liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func cancelFnTurnWithoutTranscribing(
        selectedEngine: RecognitionEngine,
        statusMessage fallbackStatusMessage: String
    ) {
        overlayHideTask?.cancel()
        overlayHideTask = nil
        transcriptionOverlay.hide()
        liveTranscript = ""
        inputLevel = 0

        if selectedEngine.isCloud {
            activeRecognitionSessionID += 1
            bufferedCloudChunks.removeAll(keepingCapacity: true)
            cloudStartTask?.cancel()
            cloudSendTask?.cancel()
            cloudStartTask = nil
            cloudSendTask = nil
            isCloudSessionReady = false
            cloudSessionEngine = nil
            cloudSessionLanguage = nil
            Task { [weak self, cloudTranscriber, qwenASRTranscriber] in
                await cloudTranscriber.cancel()
                await qwenASRTranscriber.cancel()
                await MainActor.run {
                    self?.preconnectCloudSession()
                }
            }
        }

        statusMessage = rearmKeyMonitorAfterTurn() ?? fallbackStatusMessage
    }

    func scheduleOverlayHide(after delay: TimeInterval, sessionID: Int) {
        overlayHideTask?.cancel()
        overlayHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard
                    let self,
                    self.activeRecognitionSessionID == sessionID,
                    !self.isRecording
                else {
                    return
                }

                self.transcriptionOverlay.hide()
            }
        }
    }

    func startCloudSession(sessionID: Int) {
        bufferedCloudChunks.removeAll(keepingCapacity: true)
        cloudSendTask = nil
        isCloudSessionReady = false
        let preconnectTask = cloudPreconnectTask
        cloudPreconnectTask = nil
        let selectedEngine = recognitionEngine
        let selectedLanguage = language(for: selectedEngine)

        cloudStartTask = Task { [cloudTranscriber, qwenASRTranscriber] in
            if let preconnectTask {
                try? await preconnectTask.value
            }

            switch selectedEngine {
            case .volcengine:
                try await cloudTranscriber.start(language: selectedLanguage) { [weak self] update in
                    Task { @MainActor in
                        self?.handleCloudRecognitionUpdate(
                            text: update.text,
                            isDefinite: update.isDefinite,
                            engine: selectedEngine,
                            sessionID: sessionID
                        )
                    }
                }
            case .qwenASR:
                try await qwenASRTranscriber.start(language: selectedLanguage) { [weak self] update in
                    Task { @MainActor in
                        self?.handleCloudRecognitionUpdate(
                            text: update.text,
                            isDefinite: update.isDefinite,
                            engine: selectedEngine,
                            sessionID: sessionID
                        )
                    }
                }
            case .sherpaOnnx:
                return
            }

            await MainActor.run {
                guard self.activeRecognitionSessionID == sessionID, self.recognitionEngine == selectedEngine else { return }
                self.isCloudSessionReady = true
                self.cloudSessionEngine = selectedEngine
                self.cloudSessionLanguage = selectedLanguage
                self.flushBufferedCloudChunks()
            }
        }
    }

    func preconnectCloudSession() {
        guard
            recognitionEngine.isCloud,
            isEnabled,
            !isRecording,
            !isTranscribing,
            cloudPreconnectTask == nil
        else {
            return
        }

        let selectedEngine = recognitionEngine
        guard !needsAPIKey(for: selectedEngine) else {
            fallbackToLocalRecognitionForMissingAPIKey()
            return
        }

        let selectedLanguage = language(for: selectedEngine)
        if missingKeyboardPermissionNames().isEmpty {
            statusMessage = L10n.tr("Preparing %@...", selectedEngine.title)
        }

        cloudPreconnectTask = Task { [weak self, cloudTranscriber, qwenASRTranscriber] in
            do {
                switch selectedEngine {
                case .volcengine:
                    try await cloudTranscriber.prepare(language: selectedLanguage)
                case .qwenASR:
                    try await qwenASRTranscriber.prepare(language: selectedLanguage)
                case .sherpaOnnx:
                    return
                }

                await MainActor.run {
                    guard let self else { return }
                    guard
                        self.recognitionEngine == selectedEngine,
                        self.isEnabled,
                        self.cloudPreconnectTask != nil,
                        !self.isRecording,
                        !self.isTranscribing,
                        self.missingKeyboardPermissionNames().isEmpty
                    else {
                        return
                    }

                    self.cloudSessionEngine = selectedEngine
                    self.cloudSessionLanguage = selectedLanguage
                    self.statusMessage = L10n.tr("Listening for %@. %@ ready.", self.holdShortcut.displayName, selectedEngine.title)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard self.cloudPreconnectTask != nil else { return }
                    self.cloudPreconnectTask = nil
                    if self.isEnabled, !self.isRecording, !self.isTranscribing, self.missingKeyboardPermissionNames().isEmpty {
                        self.statusMessage = L10n.tr("%@ preconnect failed: %@", selectedEngine.title, error.localizedDescription)
                    }
                }
                throw error
            }
        }
    }

    func handleCloudAudioChunk(_ chunk: Data) {
        guard recognitionEngine.isCloud else { return }

        if isCloudSessionReady {
            enqueueCloudAudio(chunk)
        } else {
            bufferedCloudChunks.append(chunk)
        }
    }

    func handleInputLevel(_ level: Double) {
        guard isRecording else {
            inputLevel = 0
            return
        }

        let clampedLevel = min(1, max(0, level))
        let attack = 0.65
        let release = 0.24
        let smoothing = clampedLevel > inputLevel ? attack : release
        inputLevel = inputLevel * (1 - smoothing) + clampedLevel * smoothing
    }

    func flushBufferedCloudChunks() {
        guard isCloudSessionReady else { return }

        let chunks = bufferedCloudChunks
        bufferedCloudChunks.removeAll(keepingCapacity: true)
        for chunk in chunks {
            enqueueCloudAudio(chunk)
        }
    }

    func enqueueCloudAudio(_ chunk: Data) {
        let previousTask = cloudSendTask
        let selectedEngine = cloudSessionEngine ?? recognitionEngine
        cloudSendTask = Task { [cloudTranscriber, qwenASRTranscriber] in
            _ = await previousTask?.value
            switch selectedEngine {
            case .volcengine:
                try? await cloudTranscriber.sendAudio(chunk)
            case .qwenASR:
                try? await qwenASRTranscriber.sendAudio(chunk)
            case .sherpaOnnx:
                return
            }
        }
    }

    func handleCloudRecognitionUpdate(
        text: String,
        isDefinite: Bool,
        engine: RecognitionEngine,
        sessionID: Int
    ) {
        guard
            recognitionEngine == engine,
            sessionID == activeRecognitionSessionID,
            isRecording
        else {
            return
        }

        liveTranscript = text
        statusMessage = isDefinite ? L10n.tr("Recording. Cloud finalizing segment...") : L10n.tr("Recording with cloud recognition...")
    }

}
