import AppKit
import AVFoundation
import Foundation

@MainActor
final class HoldToTalkController: ObservableObject {
    static let shared = HoldToTalkController()

    @Published var isEnabled = true
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var statusMessage = L10n.tr("Starting...")
    @Published private(set) var lastTranscript = ""
    @Published private(set) var liveTranscript = ""
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var microphoneStatusText = L10n.tr("Unknown")
    @Published private(set) var inputDeviceText = L10n.tr("Unknown")
    @Published private(set) var shortcutEventText = L10n.tr("No shortcut event yet.")
    @Published private(set) var lastRecordingInfo = L10n.tr("No recording yet.")
    @Published private(set) var targetAppText = L10n.tr("No target app yet.")
    @Published private(set) var accessibilityStatusText = L10n.tr("Unknown")
    @Published var autoPaste = true
    @Published private(set) var recognitionEngine: RecognitionEngine = .volcengine
    @Published private(set) var preferredRecognitionEngine: RecognitionEngine = .volcengine
    @Published private(set) var selectedLocalSpeechModel: LocalSpeechModel
    @Published private(set) var localSpeechModelStatusText = L10n.tr("Not downloaded")
    @Published private(set) var isDownloadingLocalSpeechModel = false
    @Published private(set) var downloadingLocalSpeechModelID: String?
    @Published private(set) var localSpeechModelDownloadProgress = 0.0
    @Published private var volcengineLanguage: TranscriptionLanguage = .auto
    @Published private var sherpaOnnxLanguage: TranscriptionLanguage = .auto
    @Published var volcengineAPIKeyDraft = ""
    @Published private(set) var volcengineAPIKeyStatusText = L10n.tr("Not set")
    @Published private(set) var holdShortcut: HoldShortcut
    @Published var isRecordingShortcut = false
    @Published var removesTrailingSentencePeriod: Bool {
        didSet {
            UserDefaults.standard.set(removesTrailingSentencePeriod, forKey: Self.removesTrailingSentencePeriodDefaultsKey)
        }
    }

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
    private var localSpeechModelDownloadTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var pendingTranscriptionCount = 0
    private var recordingTrigger = "Shortcut"
    private var recordingTargetApplication: NSRunningApplication?
    private var lastTargetApplication: NSRunningApplication?
    private var cloudPreconnectTask: Task<Void, Error>?
    private var cloudStartTask: Task<Void, Error>?
    private var cloudSendTask: Task<Void, Never>?
    private var bufferedCloudChunks: [Data] = []
    private var isCloudSessionReady = false
    private var cloudSessionLanguage: TranscriptionLanguage?
    private var activeRecognitionSessionID = 0
    private var overlayHideTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var hasShortcutEvent = false
    private var hasRecordingInfo = false

    private let shortcutDefaultsKey = "HoldToTalk.holdShortcut"
    private let localSpeechModelDefaultsKey = "HoldToTalk.localSpeechModel"
    private let minimumFnHoldDurationForRecognition: TimeInterval = 0.22
    private static let manualRecordingTrigger = "Manual"
    private static let removesTrailingSentencePeriodDefaultsKey = "HoldToTalk.removesTrailingSentencePeriod"
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    var headerSystemImage: String {
        if isRecording { return "mic.circle.fill" }
        if isTranscribing { return "waveform.circle.fill" }
        return "keyboard"
    }

    var menuBarTemplateIconName: String {
        if isRecording { return "MenuBarIconRecordingTemplate" }
        if isTranscribing { return "MenuBarIconTranscribingTemplate" }
        return "MenuBarIconIdleTemplate"
    }

    var language: TranscriptionLanguage {
        language(for: preferredRecognitionEngine)
    }

    var availableLanguages: [TranscriptionLanguage] {
        availableLanguages(for: preferredRecognitionEngine)
    }

    var localSpeechModels: [LocalSpeechModel] {
        LocalSpeechModel.all
    }

    var isSelectedLocalSpeechModelInstalled: Bool {
        LocalSpeechModelStore.isInstalled(selectedLocalSpeechModel)
    }

    var needsMicrophonePermission: Bool {
        !PermissionHelper.hasMicrophonePermission
    }

    var needsAccessibilityPermission: Bool {
        !PermissionHelper.isAccessibilityTrusted
    }

    var needsVolcengineAPIKey: Bool {
        VolcengineCredentialStore.apiKey() == nil
    }

    var isUsingLocalFallbackForMissingAPIKey: Bool {
        preferredRecognitionEngine == .volcengine && recognitionEngine == .sherpaOnnx && needsVolcengineAPIKey
    }

    private init() {
        let savedShortcut = Self.loadHoldShortcut()
        holdShortcut = savedShortcut
        selectedLocalSpeechModel = Self.loadLocalSpeechModel()
        removesTrailingSentencePeriod = Self.loadRemovesTrailingSentencePeriod()
        keyMonitor.delegate = self
        keyMonitor.shortcut = savedShortcut
        volcengineAPIKeyDraft = VolcengineCredentialStore.apiKey() ?? ""
        refreshVolcengineAPIKeyState()
        refreshLocalSpeechModelStatus()
        if needsVolcengineAPIKey {
            recognitionEngine = .sherpaOnnx
            statusMessage = L10n.tr("Using local recognition. Add a Volcengine API key to enable cloud recognition.")
        }
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
        ensureRecognitionEngineAvailable()
        if recognitionEngine == .sherpaOnnx, isSelectedLocalSpeechModelInstalled {
            prewarmRecognizer()
        } else if recognitionEngine == .sherpaOnnx {
            statusMessage = L10n.tr("Download %@ before using local recognition.", selectedLocalSpeechModel.displayTitle)
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
            statusMessage = enabled ? L10n.tr("Listening for %@.", holdShortcut.displayName) : L10n.tr("Paused.")
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

    func openMicrophoneSettings() {
        PermissionHelper.openMicrophoneSettings()
        refreshPermissionStatus()
    }

    func requestAccessibilityPermission() {
        _ = PermissionHelper.requestAccessibilityPermission()
        refreshPermissionStatus()
        startKeyMonitor()
    }

    func openAccessibilitySettings() {
        PermissionHelper.openAccessibilitySettings()
        refreshPermissionStatus()
    }

    func syncVolcengineAPIKeyDraft() {
        let apiKey = volcengineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            clearVolcengineAPIKey()
            return
        }

        guard VolcengineCredentialStore.apiKey() != apiKey else {
            volcengineAPIKeyDraft = apiKey
            refreshVolcengineAPIKeyState()
            return
        }

        do {
            try VolcengineCredentialStore.saveAPIKey(apiKey)
            volcengineAPIKeyDraft = apiKey
            refreshVolcengineAPIKeyState()
            resetCloudSession()
            preferredRecognitionEngine = .volcengine
            recognitionEngine = .volcengine
            if !isRecording, !isTranscribing {
                statusMessage = L10n.tr("Volcengine API key saved. Cloud recognition is available.")
                preconnectCloudSession()
            }
        } catch {
            volcengineAPIKeyStatusText = L10n.tr("Could not save API key: %@", error.localizedDescription)
        }
    }

    func clearVolcengineAPIKey() {
        do {
            try VolcengineCredentialStore.deleteAPIKey()
            volcengineAPIKeyDraft = ""
            refreshVolcengineAPIKeyState()
            resetCloudSession()
            fallbackToLocalRecognitionForMissingAPIKey()
        } catch {
            volcengineAPIKeyStatusText = L10n.tr("Could not clear API key: %@", error.localizedDescription)
        }
    }

    func setPreferredRecognitionEngine(_ engine: RecognitionEngine) {
        preferredRecognitionEngine = engine

        switch engine {
        case .volcengine:
            guard !needsVolcengineAPIKey else {
                fallbackToLocalRecognitionForMissingAPIKey()
                return
            }

            recognitionEngine = .volcengine
            if !isRecording, !isTranscribing {
                preconnectCloudSession()
            }
        case .sherpaOnnx:
            recognitionEngine = .sherpaOnnx
            cloudPreconnectTask?.cancel()
            cloudPreconnectTask = nil
            if !isRecording, !isTranscribing {
                Task { [cloudTranscriber] in
                    await cloudTranscriber.cancel()
                }
            }
            if isSelectedLocalSpeechModelInstalled {
                prewarmRecognizer()
            } else if !isRecording, !isTranscribing {
                statusMessage = L10n.tr("Download %@ before using local recognition.", selectedLocalSpeechModel.displayTitle)
            }
        }
    }

    func setLocalSpeechModel(_ model: LocalSpeechModel) {
        guard selectedLocalSpeechModel != model else { return }

        selectedLocalSpeechModel = model
        UserDefaults.standard.set(model.id, forKey: localSpeechModelDefaultsKey)
        if !model.supportedLanguages.contains(sherpaOnnxLanguage) {
            sherpaOnnxLanguage = .auto
        }
        refreshLocalSpeechModelStatus()
        recognizerPrewarmTask?.cancel()
        recognizerPrewarmTask = nil
        Task { [transcriber] in
            await transcriber.clearCache()
        }

        if preferredRecognitionEngine == .sherpaOnnx {
            if isSelectedLocalSpeechModelInstalled {
                prewarmRecognizer()
            } else if !isRecording, !isTranscribing {
                statusMessage = L10n.tr("Download %@ before using local recognition.", model.displayTitle)
            }
        }
    }

    func downloadSelectedLocalSpeechModel() {
        downloadLocalSpeechModel(selectedLocalSpeechModel)
    }

    func downloadLocalSpeechModel(_ model: LocalSpeechModel) {
        guard !isDownloadingLocalSpeechModel else { return }

        if selectedLocalSpeechModel != model {
            setLocalSpeechModel(model)
        }

        isDownloadingLocalSpeechModel = true
        downloadingLocalSpeechModelID = model.id
        localSpeechModelDownloadProgress = 0
        localSpeechModelStatusText = L10n.tr("Downloading %@...", model.displayTitle)
        statusMessage = localSpeechModelStatusText

        localSpeechModelDownloadTask = Task { [weak self] in
            do {
                try await LocalSpeechModelStore.download(model) { progress in
                    await MainActor.run {
                        guard let self, self.downloadingLocalSpeechModelID == model.id else { return }
                        self.localSpeechModelDownloadProgress = progress
                        let percent = Self.percentFormatter.string(from: NSNumber(value: progress)) ?? ""
                        self.localSpeechModelStatusText = L10n.tr("Downloading %@... %@", model.displayTitle, percent)
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.isDownloadingLocalSpeechModel = false
                    self.downloadingLocalSpeechModelID = nil
                    self.localSpeechModelDownloadProgress = 0
                    self.localSpeechModelDownloadTask = nil
                    self.refreshLocalSpeechModelStatus()
                    self.statusMessage = L10n.tr("Downloaded %@.", model.displayTitle)
                    if self.preferredRecognitionEngine == .sherpaOnnx, self.selectedLocalSpeechModel == model {
                        self.prewarmRecognizer()
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isDownloadingLocalSpeechModel = false
                    self.downloadingLocalSpeechModelID = nil
                    self.localSpeechModelDownloadProgress = 0
                    self.localSpeechModelDownloadTask = nil
                    if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                        self.refreshLocalSpeechModelStatus()
                        self.statusMessage = L10n.tr("Download canceled.")
                    } else {
                        self.localSpeechModelStatusText = error.localizedDescription
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelLocalSpeechModelDownload() {
        guard isDownloadingLocalSpeechModel else { return }
        localSpeechModelDownloadTask?.cancel()
        localSpeechModelDownloadTask = nil
        isDownloadingLocalSpeechModel = false
        downloadingLocalSpeechModelID = nil
        localSpeechModelDownloadProgress = 0
        refreshLocalSpeechModelStatus()
        statusMessage = L10n.tr("Download canceled.")
    }

    func deleteLocalSpeechModel(_ model: LocalSpeechModel) {
        if downloadingLocalSpeechModelID == model.id {
            cancelLocalSpeechModelDownload()
        }

        do {
            try LocalSpeechModelStore.delete(model)
            if selectedLocalSpeechModel == model {
                recognizerPrewarmTask?.cancel()
                recognizerPrewarmTask = nil
                Task { [transcriber] in
                    await transcriber.clearCache()
                }
            }
            refreshLocalSpeechModelStatus()
            statusMessage = L10n.tr("Deleted %@.", model.displayTitle)
        } catch {
            localSpeechModelStatusText = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func refreshLocalSpeechModelStatus() {
        localSpeechModelStatusText = isSelectedLocalSpeechModelInstalled ? L10n.tr("Downloaded") : L10n.tr("Not downloaded")
    }

    func setLanguage(_ language: TranscriptionLanguage) {
        switch preferredRecognitionEngine {
        case .volcengine:
            guard TranscriptionLanguage.volcengineLanguages.contains(language) else { return }
            guard volcengineLanguage != language else { return }
            volcengineLanguage = language
            if recognitionEngine == .volcengine {
                resetCloudSession()
            }
            if recognitionEngine == .volcengine, !isRecording, !isTranscribing {
                preconnectCloudSession()
            }
        case .sherpaOnnx:
            guard selectedLocalSpeechModel.supportedLanguages.contains(language) else { return }
            sherpaOnnxLanguage = language
        }
    }

    func beginShortcutRecording() {
        isRecordingShortcut = true
        statusMessage = L10n.tr("Press the shortcut to use for hold-to-talk.")
    }

    func cancelShortcutRecording() {
        isRecordingShortcut = false
        statusMessage = isEnabled ? L10n.tr("Listening for %@.", holdShortcut.displayName) : L10n.tr("Paused.")
    }

    func setHoldShortcut(_ shortcut: HoldShortcut) {
        guard shortcut.isValidGlobalShortcut else {
            statusMessage = L10n.tr("Use Fn, a function key, or a shortcut with Command, Option, Control, or Shift.")
            return
        }

        holdShortcut = shortcut
        keyMonitor.shortcut = shortcut
        isRecordingShortcut = false
        saveHoldShortcut(shortcut)
        hasShortcutEvent = true
        shortcutEventText = L10n.tr("Shortcut set to %@.", shortcut.displayName)
        if isEnabled, !isRecording, !isTranscribing {
            statusMessage = L10n.tr("Listening for %@.", shortcut.displayName)
        }
        try? keyMonitor.rearm()
    }

    func resetHoldShortcut() {
        setHoldShortcut(.defaultShortcut)
    }

    func toggleManualRecording() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording(trigger: Self.manualRecordingTrigger)
        }
    }

    func appLanguageDidChange() {
        refreshPermissionStatus()
        refreshVolcengineAPIKeyState()

        if !hasShortcutEvent {
            shortcutEventText = L10n.tr("No shortcut event yet.")
        }

        if !hasRecordingInfo {
            lastRecordingInfo = L10n.tr("No recording yet.")
        }

        if lastTargetApplication == nil, recordingTargetApplication == nil {
            targetAppText = L10n.tr("No target app yet.")
        }

        refreshCurrentStatusMessage()
    }

    func refreshPermissionStatus() {
        setIfChanged(\.microphoneStatusText, PermissionHelper.microphoneStatusText)
        setIfChanged(\.inputDeviceText, AudioDeviceInspector.defaultInputDeviceName())
        setIfChanged(\.accessibilityStatusText, PermissionHelper.isAccessibilityTrusted ? L10n.tr("Granted") : L10n.tr("Not granted"))
    }

    private func setIfChanged(_ keyPath: ReferenceWritableKeyPath<HoldToTalkController, String>, _ newValue: String) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }

    private func refreshVolcengineAPIKeyState() {
        volcengineAPIKeyStatusText = VolcengineCredentialStore.apiKey() == nil ? L10n.tr("Not set") : L10n.tr("Saved in Keychain")
    }

    private func language(for engine: RecognitionEngine) -> TranscriptionLanguage {
        switch engine {
        case .volcengine:
            return TranscriptionLanguage.volcengineLanguages.contains(volcengineLanguage) ? volcengineLanguage : .auto
        case .sherpaOnnx:
            return selectedLocalSpeechModel.supportedLanguages.contains(sherpaOnnxLanguage) ? sherpaOnnxLanguage : .auto
        }
    }

    private func availableLanguages(for engine: RecognitionEngine) -> [TranscriptionLanguage] {
        switch engine {
        case .volcengine:
            return TranscriptionLanguage.volcengineLanguages
        case .sherpaOnnx:
            return selectedLocalSpeechModel.supportedLanguages
        }
    }

    private func ensureRecognitionEngineAvailable() {
        if recognitionEngine == .volcengine, needsVolcengineAPIKey {
            fallbackToLocalRecognitionForMissingAPIKey()
        }
    }

    private func fallbackToLocalRecognitionForMissingAPIKey() {
        guard needsVolcengineAPIKey else { return }

        if recognitionEngine != .sherpaOnnx {
            recognitionEngine = .sherpaOnnx
        }

        resetCloudSession()
        if isSelectedLocalSpeechModelInstalled {
            prewarmRecognizer()
        }

        if !isRecording, !isTranscribing {
            statusMessage = L10n.tr("Using local recognition. Add a Volcengine API key to enable cloud recognition.")
        }
    }

    private func resetCloudSession() {
        cloudPreconnectTask?.cancel()
        cloudStartTask?.cancel()
        cloudSendTask?.cancel()
        cloudPreconnectTask = nil
        cloudStartTask = nil
        cloudSendTask = nil
        bufferedCloudChunks.removeAll(keepingCapacity: true)
        isCloudSessionReady = false
        cloudSessionLanguage = nil
        Task { [cloudTranscriber] in
            await cloudTranscriber.cancel()
        }
    }

    private func startKeyMonitor() {
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

    private func missingKeyboardPermissionNames() -> [String] {
        var names: [String] = []

        if !PermissionHelper.isAccessibilityTrusted {
            names.append(L10n.tr("Accessibility"))
        }

        return names
    }

    private func handleShortcutChanged(isDown: Bool) {
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

    private func startRecording(trigger: String) {
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
            recordingStartedAt = nil
            recordingTargetApplication = nil
            if trigger != Self.manualRecordingTrigger {
                transcriptionOverlay.hide()
            }
            statusMessage = L10n.tr("Could not start recording: %@", error.localizedDescription)
        }
    }

    private func stopRecordingAndTranscribe() {
        let pendingCloudAudio = recognitionEngine == .volcengine ? recorder.takePendingStreamingAudio() : nil
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
                    text = finalizedTranscriptText(
                        from: try await cloudTranscriber.finish(finalAudio: pendingCloudAudio),
                        shouldRemoveTrailingSentencePeriod: shouldRemoveTrailingSentencePeriod
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
                    text = finalizedTranscriptText(
                        from: try await transcriber.transcribe(
                            audioURL: audioURL,
                            language: selectedLanguage.sherpaOnnxLanguageCode,
                            model: selectedLocalModel
                        ),
                        shouldRemoveTrailingSentencePeriod: shouldRemoveTrailingSentencePeriod
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
                if trigger != Self.manualRecordingTrigger {
                    scheduleOverlayHide(after: 0.2, sessionID: recognitionSessionID)
                }
            }
        }
    }

    private func shouldTreatAsShortFnTap(trigger: String, heldDuration: TimeInterval) -> Bool {
        trigger != Self.manualRecordingTrigger
            && heldDuration < minimumFnHoldDurationForRecognition
            && liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func cancelFnTurnWithoutTranscribing(
        selectedEngine: RecognitionEngine,
        statusMessage fallbackStatusMessage: String
    ) {
        overlayHideTask?.cancel()
        overlayHideTask = nil
        transcriptionOverlay.hide()
        liveTranscript = ""
        inputLevel = 0

        if selectedEngine == .volcengine {
            activeRecognitionSessionID += 1
            bufferedCloudChunks.removeAll(keepingCapacity: true)
            cloudStartTask?.cancel()
            cloudSendTask?.cancel()
            cloudStartTask = nil
            cloudSendTask = nil
            isCloudSessionReady = false
            cloudSessionLanguage = nil
            Task { [weak self, cloudTranscriber] in
                await cloudTranscriber.cancel()
                await MainActor.run {
                    self?.preconnectCloudSession()
                }
            }
        }

        statusMessage = rearmKeyMonitorAfterTurn() ?? fallbackStatusMessage
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
        let selectedLanguage = language(for: .volcengine)

        cloudStartTask = Task { [cloudTranscriber] in
            if let preconnectTask {
                try? await preconnectTask.value
            }

            try await cloudTranscriber.start(language: selectedLanguage) { [weak self] update in
                Task { @MainActor in
                    self?.handleCloudRecognitionUpdate(update, sessionID: sessionID)
                }
            }

            await MainActor.run {
                guard self.activeRecognitionSessionID == sessionID else { return }
                self.isCloudSessionReady = true
                self.cloudSessionLanguage = selectedLanguage
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

        guard VolcengineCredentialStore.apiKey() != nil else {
            fallbackToLocalRecognitionForMissingAPIKey()
            return
        }

        let selectedLanguage = language(for: .volcengine)
        if missingKeyboardPermissionNames().isEmpty {
            statusMessage = L10n.tr("Preparing Volcengine cloud...")
        }

        cloudPreconnectTask = Task { [weak self, cloudTranscriber] in
            do {
                try await cloudTranscriber.prepare(language: selectedLanguage)

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

                    self.cloudSessionLanguage = selectedLanguage
                    self.statusMessage = L10n.tr("Listening for %@. Volcengine cloud ready.", self.holdShortcut.displayName)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard self.cloudPreconnectTask != nil else { return }
                    self.cloudPreconnectTask = nil
                    if self.isEnabled, !self.isRecording, !self.isTranscribing, self.missingKeyboardPermissionNames().isEmpty {
                        self.statusMessage = L10n.tr("Volcengine cloud preconnect failed: %@", error.localizedDescription)
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
            statusMessage = update.isDefinite ? L10n.tr("Recording. Cloud finalizing segment...") : L10n.tr("Recording with cloud recognition...")
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
        targetAppText = application.localizedName ?? application.bundleIdentifier ?? L10n.tr("Unknown")
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
                ? L10n.tr("Transcribing queued recordings...")
                : recognitionEngine == .volcengine
                    ? L10n.tr("Waiting for cloud final result...")
                    : L10n.tr("Transcribing with sherpa-onnx...")
        }
    }

    private func finishTranscription(finalStatus: String) {
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
            hasRecordingInfo = true
            lastRecordingInfo = L10n.tr("%@, %@, %@, input %@", stats.summary, localizedTriggerName(trigger), captureSummary, inputDevice)
        } catch {
            hasRecordingInfo = true
            lastRecordingInfo = L10n.tr("%@, %@, input %@, audio analysis failed: %@", localizedTriggerName(trigger), captureSummary, inputDevice, error.localizedDescription)
        }
    }

    private func removeTrailingSentencePeriod(from text: String) -> String {
        guard text.last == "。" else { return text }
        return String(text.dropLast())
    }

    private func finalizedTranscriptText(
        from rawText: String,
        shouldRemoveTrailingSentencePeriod: Bool
    ) -> String {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldRemoveTrailingSentencePeriod else { return trimmedText }
        return removeTrailingSentencePeriod(from: trimmedText)
    }

    private func localizedTriggerName(_ trigger: String) -> String {
        trigger == Self.manualRecordingTrigger ? L10n.tr("Manual") : trigger
    }

    private func refreshCurrentStatusMessage() {
        if isRecording {
            statusMessage = recordingTrigger == Self.manualRecordingTrigger
                ? L10n.tr("Manual recording...")
                : L10n.tr("Recording while %@ is held.", recordingTrigger)
            return
        }

        if isTranscribing {
            statusMessage = pendingTranscriptionCount > 1
                ? L10n.tr("Transcribing queued recordings...")
                : recognitionEngine == .volcengine
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

        if needsVolcengineAPIKey {
            statusMessage = L10n.tr("Using local recognition. Add a Volcengine API key to enable cloud recognition.")
            return
        }

        statusMessage = L10n.tr("Listening for %@.", holdShortcut.displayName)
    }

    private static func loadHoldShortcut() -> HoldShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: "HoldToTalk.holdShortcut"),
            let shortcut = try? JSONDecoder().decode(HoldShortcut.self, from: data)
        else {
            return .defaultShortcut
        }
        return shortcut
    }

    private func saveHoldShortcut(_ shortcut: HoldShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: shortcutDefaultsKey)
    }

    private static func loadRemovesTrailingSentencePeriod() -> Bool {
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

    private static func loadLocalSpeechModel() -> LocalSpeechModel {
        guard let id = UserDefaults.standard.string(forKey: "HoldToTalk.localSpeechModel") else {
            return .defaultModel
        }

        return LocalSpeechModel.model(id: id)
    }
}
