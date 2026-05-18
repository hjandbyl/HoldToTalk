import AppKit
import AVFoundation
import Foundation

@MainActor
final class HoldToTalkController: ObservableObject {
    static let shared = HoldToTalkController()

    @Published var isEnabled = true
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var statusMessage = "Starting..."
    @Published private(set) var lastTranscript = ""
    @Published private(set) var liveTranscript = ""
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var microphoneStatusText = "Unknown"
    @Published private(set) var inputDeviceText = "Unknown"
    @Published private(set) var fnEventText = "No Fn event yet."
    @Published private(set) var lastRecordingInfo = "No recording yet."
    @Published private(set) var targetAppText = "No target app yet."
    @Published private(set) var accessibilityStatusText = "Unknown"
    @Published private(set) var inputMonitoringStatusText = "Unknown"
    @Published var autoPaste = true
    @Published var recognitionEngine: RecognitionEngine = .volcengine
    @Published var language: TranscriptionLanguage = .mixedZhEn

    private let recorder = AudioRecorder()
    private let keyMonitor = GlobalFnKeyMonitor()
    private let transcriber = SherpaOnnxClient()
    private let cloudTranscriber = VolcengineStreamingClient()
    private let injector = TextInjector()
    private lazy var transcriptionOverlay = TranscriptionOverlayController(controller: self)

    private var didStart = false
    private var currentRecordingURL: URL?
    private var permissionRefreshTask: Task<Void, Never>?
    private var recognizerPrewarmTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var pendingTranscriptionCount = 0
    private var recordingTrigger = "Fn"
    private var recordingTargetApplication: NSRunningApplication?
    private var lastTargetApplication: NSRunningApplication?
    private var cloudPreconnectTask: Task<Void, Error>?
    private var cloudStartTask: Task<Void, Error>?
    private var cloudSendTask: Task<Void, Never>?
    private var bufferedCloudChunks: [Data] = []
    private var isCloudSessionReady = false
    private var activeRecognitionSessionID = 0
    private var overlayHideTask: Task<Void, Never>?

    var headerSystemImage: String {
        if isRecording { return "mic.circle.fill" }
        if isTranscribing { return "waveform.circle.fill" }
        return "keyboard"
    }

    var menuBarSystemImage: String {
        if isRecording { return "mic.fill" }
        if isTranscribing { return "waveform" }
        return "keyboard"
    }

    private init() {
        keyMonitor.delegate = self
    }

    func start() async {
        guard !didStart else { return }
        didStart = true

        refreshPermissionStatus()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophonePermission()
        }

        startPermissionPolling()
        startForegroundAppTracking()
        startKeyMonitor()
        if recognitionEngine == .sherpaOnnx {
            prewarmRecognizer()
        } else {
            preconnectCloudSession()
        }
    }

    func setListeningEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled, isRecording {
            stopRecordingAndTranscribe()
        }

        if !isRecording && !isTranscribing {
            statusMessage = enabled ? "Listening for Fn." : "Paused."
        }

        if enabled, recognitionEngine == .volcengine {
            preconnectCloudSession()
        } else if !enabled, !isRecording, !isTranscribing {
            cloudPreconnectTask?.cancel()
            cloudPreconnectTask = nil
            Task { [cloudTranscriber] in
                await cloudTranscriber.cancel()
            }
        }
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionStatus()
            }
        }
    }

    func requestAccessibilityPermission() {
        _ = PermissionHelper.requestAccessibilityPermission()
        refreshPermissionStatus()
        startKeyMonitor()
    }

    func requestInputMonitoringPermission() {
        _ = PermissionHelper.requestInputMonitoringPermission()
        refreshPermissionStatus()
        startKeyMonitor()
    }

    func toggleManualRecording() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording(trigger: "Manual")
        }
    }

    func refreshPermissionStatus() {
        setIfChanged(\.microphoneStatusText, PermissionHelper.microphoneStatusText)
        setIfChanged(\.inputDeviceText, AudioDeviceInspector.defaultInputDeviceName())
        setIfChanged(\.accessibilityStatusText, PermissionHelper.isAccessibilityTrusted ? "Granted" : "Not granted")
        setIfChanged(\.inputMonitoringStatusText, PermissionHelper.hasInputMonitoringPermission ? "Granted" : "Not granted")
    }

    private func setIfChanged(_ keyPath: ReferenceWritableKeyPath<HoldToTalkController, String>, _ newValue: String) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }

    private func startKeyMonitor() {
        let missingPermissions = missingKeyboardPermissionNames()
        guard missingPermissions.isEmpty else {
            statusMessage = "Grant \(missingPermissions.joined(separator: " and ")) permission, then hold Fn."
            refreshPermissionStatus()
            return
        }

        do {
            try keyMonitor.start()
            statusMessage = isEnabled ? "Listening for Fn." : "Paused."
        } catch {
            statusMessage = error.localizedDescription
        }
        refreshPermissionStatus()
    }

    private func startPermissionPolling() {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))

                guard let self else { return }
                self.refreshPermissionStatus()

                if self.isEnabled, !self.keyMonitor.isRunning, self.missingKeyboardPermissionNames().isEmpty {
                    self.startKeyMonitor()
                }
            }
        }
    }

    private func startForegroundAppTracking() {
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

    private func prewarmRecognizer() {
        guard recognizerPrewarmTask == nil else { return }

        if isEnabled, !isRecording, !isTranscribing, missingKeyboardPermissionNames().isEmpty {
            statusMessage = "Preparing sherpa-onnx..."
        }

        recognizerPrewarmTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.transcriber.preload()

                if self.isEnabled, !self.isRecording, !self.isTranscribing, self.missingKeyboardPermissionNames().isEmpty {
                    self.statusMessage = "Listening for Fn. sherpa-onnx ready."
                }
            } catch {
                if !self.isRecording, !self.isTranscribing {
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func missingKeyboardPermissionNames() -> [String] {
        var names: [String] = []

        if !PermissionHelper.isAccessibilityTrusted {
            names.append("Accessibility")
        }

        if !PermissionHelper.hasInputMonitoringPermission {
            names.append("Input Monitoring")
        }

        return names
    }

    private func handleFnKeyChanged(isDown: Bool) {
        guard isEnabled else { return }

        fnEventText = "\(isDown ? "Down" : "Up") \(Date().formatted(.dateTime.hour().minute().second()))"

        if isDown {
            guard !isRecording else { return }
            startRecording(trigger: "Fn")
        } else if isRecording {
            stopRecordingAndTranscribe()
        }
    }

    private func startRecording(trigger: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            statusMessage = "Microphone permission is required."
            requestMicrophonePermission()
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
            isRecording = true
            statusMessage = trigger == "Fn" ? "Recording while Fn is held." : "Manual recording..."
            if trigger == "Fn" {
                transcriptionOverlay.show()
            }
            let targetApplication = currentInsertionTargetApplication()
            recordingTargetApplication = targetApplication
            targetAppText = targetApplication?.localizedName ?? "No target app captured."

            if recognitionEngine == .volcengine {
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
            recordingTargetApplication = nil
            statusMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAndTranscribe() {
        let pendingCloudAudio = recognitionEngine == .volcengine ? recorder.takePendingStreamingAudio() : nil
        guard let audioURL = recorder.stop() ?? currentRecordingURL else { return }
        let trigger = recordingTrigger
        let targetApplication = recordingTargetApplication
        let captureSummary = recorder.captureSummary
        let inputDevice = inputDeviceText
        let selectedEngine = recognitionEngine
        let recognitionSessionID = activeRecognitionSessionID

        currentRecordingURL = nil
        recordingTargetApplication = nil
        isRecording = false
        inputLevel = 0
        beginTranscription()

        let selectedLanguage = language
        Task {
            var finalStatus = "Transcription finished."
            var insertion: (text: String, targetApplication: NSRunningApplication?)?

            defer {
                finishTranscription(finalStatus: finalStatus)

                if let insertion {
                    injector.insert(insertion.text, targetApplication: insertion.targetApplication)
                }

                try? FileManager.default.removeItem(at: audioURL)

                if selectedEngine == .volcengine, activeRecognitionSessionID == recognitionSessionID {
                    cloudStartTask = nil
                    cloudSendTask = nil
                    isCloudSessionReady = false
                    preconnectCloudSession()
                }
            }

            do {
                let text: String
                switch selectedEngine {
                case .volcengine:
                    try await cloudStartTask?.value
                    _ = await cloudSendTask?.value
                    text = removeTrailingSentencePeriod(
                        from: try await cloudTranscriber.finish(finalAudio: pendingCloudAudio)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                    text = try await transcriber.transcribe(audioURL: audioURL, language: selectedLanguage.rawValue)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

                lastTranscript = text
                if trigger == "Fn" {
                    if !text.isEmpty {
                        liveTranscript = text
                    }
                    scheduleOverlayHide(after: text.isEmpty ? 0.2 : 0.25, sessionID: recognitionSessionID)
                }

                if text.isEmpty {
                    finalStatus = "No speech recognized."
                } else {
                    if autoPaste {
                        insertion = (text, targetApplication)
                    }
                    finalStatus = autoPaste ? "Inserted recognized text." : "Transcription ready."
                }
            } catch {
                finalStatus = error.localizedDescription
                await cloudTranscriber.cancel()
                if trigger == "Fn" {
                    scheduleOverlayHide(after: 0.2, sessionID: recognitionSessionID)
                }
            }
        }
    }

    private func scheduleOverlayHide(after delay: TimeInterval, sessionID: Int) {
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

    private func startCloudSession(sessionID: Int) {
        bufferedCloudChunks.removeAll(keepingCapacity: true)
        cloudSendTask = nil
        isCloudSessionReady = false
        let preconnectTask = cloudPreconnectTask
        cloudPreconnectTask = nil

        cloudStartTask = Task { [cloudTranscriber] in
            if let preconnectTask {
                try? await preconnectTask.value
            }

            try await cloudTranscriber.start { [weak self] update in
                Task { @MainActor in
                    self?.handleCloudRecognitionUpdate(update, sessionID: sessionID)
                }
            }

            await MainActor.run {
                guard self.activeRecognitionSessionID == sessionID else { return }
                self.isCloudSessionReady = true
                self.flushBufferedCloudChunks()
            }
        }
    }

    private func preconnectCloudSession() {
        guard
            recognitionEngine == .volcengine,
            isEnabled,
            !isRecording,
            !isTranscribing,
            cloudPreconnectTask == nil
        else {
            return
        }

        if missingKeyboardPermissionNames().isEmpty {
            statusMessage = "Preparing Volcengine cloud..."
        }

        cloudPreconnectTask = Task { [weak self, cloudTranscriber] in
            do {
                try await cloudTranscriber.prepare()

                await MainActor.run {
                    guard let self else { return }
                    guard
                        self.recognitionEngine == .volcengine,
                        self.isEnabled,
                        self.cloudPreconnectTask != nil,
                        !self.isRecording,
                        !self.isTranscribing,
                        self.missingKeyboardPermissionNames().isEmpty
                    else {
                        return
                    }

                    self.statusMessage = "Listening for Fn. Volcengine cloud ready."
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard self.cloudPreconnectTask != nil else { return }
                    self.cloudPreconnectTask = nil
                    if self.isEnabled, !self.isRecording, !self.isTranscribing, self.missingKeyboardPermissionNames().isEmpty {
                        self.statusMessage = "Volcengine cloud preconnect failed: \(error.localizedDescription)"
                    }
                }
                throw error
            }
        }
    }

    private func handleCloudAudioChunk(_ chunk: Data) {
        guard recognitionEngine == .volcengine else { return }

        if isCloudSessionReady {
            enqueueCloudAudio(chunk)
        } else {
            bufferedCloudChunks.append(chunk)
        }
    }

    private func handleInputLevel(_ level: Double) {
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

    private func flushBufferedCloudChunks() {
        guard isCloudSessionReady else { return }

        let chunks = bufferedCloudChunks
        bufferedCloudChunks.removeAll(keepingCapacity: true)
        for chunk in chunks {
            enqueueCloudAudio(chunk)
        }
    }

    private func enqueueCloudAudio(_ chunk: Data) {
        let previousTask = cloudSendTask
        cloudSendTask = Task { [cloudTranscriber] in
            _ = await previousTask?.value
            try? await cloudTranscriber.sendAudio(chunk)
        }
    }

    private func handleCloudRecognitionUpdate(
        _ update: VolcengineStreamingClient.RecognitionUpdate,
        sessionID: Int
    ) {
        guard recognitionEngine == .volcengine, sessionID == activeRecognitionSessionID else { return }

        liveTranscript = update.text
        if isRecording {
            statusMessage = update.isDefinite ? "Recording. Cloud finalizing segment..." : "Recording with cloud recognition..."
        }
    }

    private func currentInsertionTargetApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication, !isSelfApplication(frontmost) {
            updateLastTargetApplication(frontmost)
            return frontmost
        }

        return lastTargetApplication
    }

    private func updateLastTargetApplication(_ application: NSRunningApplication) {
        guard !isSelfApplication(application), !application.isTerminated else { return }

        lastTargetApplication = application
        targetAppText = application.localizedName ?? application.bundleIdentifier ?? "Unknown"
    }

    private func isSelfApplication(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || application.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func beginTranscription() {
        pendingTranscriptionCount += 1
        isTranscribing = true

        if !isRecording {
            statusMessage = pendingTranscriptionCount > 1
                ? "Transcribing queued recordings..."
                : recognitionEngine == .volcengine
                    ? "Waiting for cloud final result..."
                    : "Transcribing with sherpa-onnx..."
        }
    }

    private func finishTranscription(finalStatus: String) {
        pendingTranscriptionCount = max(0, pendingTranscriptionCount - 1)
        isTranscribing = pendingTranscriptionCount > 0

        if isRecording {
            return
        }

        if isTranscribing {
            statusMessage = "Transcribing queued recordings..."
        } else {
            statusMessage = rearmKeyMonitorAfterTurn() ?? finalStatus
        }
    }

    private func rearmKeyMonitorAfterTurn() -> String? {
        guard isEnabled, missingKeyboardPermissionNames().isEmpty else { return nil }

        do {
            try keyMonitor.rearm()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func preserveLastRecording(_ url: URL) {
        let debugURL = FileManager.default.temporaryDirectory.appendingPathComponent("HoldToTalk-last.wav")
        try? FileManager.default.removeItem(at: debugURL)
        try? FileManager.default.copyItem(at: url, to: debugURL)
    }

    private func updateLastRecordingInfo(
        audioURL: URL,
        trigger: String,
        captureSummary: String,
        inputDevice: String
    ) {
        preserveLastRecording(audioURL)

        do {
            let stats = try RecordedAudioAnalyzer.analyze(url: audioURL)
            lastRecordingInfo = "\(stats.summary), \(trigger), \(captureSummary), input \(inputDevice)"
        } catch {
            lastRecordingInfo = "\(trigger), \(captureSummary), input \(inputDevice), audio analysis failed: \(error.localizedDescription)"
        }
    }

    private func removeTrailingSentencePeriod(from text: String) -> String {
        guard text.last == "。" else { return text }
        return String(text.dropLast())
    }

    func recognitionEngineDidChange() {
        if recognitionEngine == .sherpaOnnx {
            cloudPreconnectTask?.cancel()
            cloudPreconnectTask = nil
            if !isRecording, !isTranscribing {
                Task { [cloudTranscriber] in
                    await cloudTranscriber.cancel()
                }
            }
            prewarmRecognizer()
        } else {
            if !isRecording && !isTranscribing {
                statusMessage = "Listening for Fn."
            }
            preconnectCloudSession()
        }
    }
}

extension HoldToTalkController: GlobalFnKeyMonitorDelegate {
    nonisolated func globalFnKeyMonitor(_ monitor: GlobalFnKeyMonitor, didChangeFnKeyDown isDown: Bool) {
        Task { @MainActor in
            self.handleFnKeyChanged(isDown: isDown)
        }
    }
}
