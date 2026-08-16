import AppKit
import AVFoundation
import Foundation

@MainActor
final class HoldToTalkController: ObservableObject {
    static let shared = HoldToTalkController()

    @Published var isEnabled = true
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var statusMessage = L10n.tr("Starting...")
    @Published var lastTranscript = ""
    @Published var liveTranscript = ""
    @Published var inputLevel = 0.0
    @Published var inputSpectrum = Array(repeating: 0.0, count: AudioRecorder.spectrumBandCount)
    @Published var microphoneStatusText = L10n.tr("Unknown")
    @Published var inputDeviceText = L10n.tr("Unknown")
    @Published var availableInputDevices: [AudioInputDevice] = []
    @Published var selectedInputDeviceUID: String {
        didSet {
            if selectedInputDeviceUID.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.inputDeviceDefaultsKey)
                UserDefaults.standard.removeObject(forKey: Self.inputDeviceNameDefaultsKey)
            } else {
                UserDefaults.standard.set(selectedInputDeviceUID, forKey: Self.inputDeviceDefaultsKey)
            }
            refreshInputDeviceState()
        }
    }
    @Published var shortcutEventText = L10n.tr("No shortcut event yet.")
    @Published var lastRecordingInfo = L10n.tr("No recording yet.")
    @Published var targetAppText = L10n.tr("No target app yet.")
    @Published var accessibilityStatusText = L10n.tr("Unknown")
    @Published var autoPaste = true
    @Published var recognitionEngine: RecognitionEngine = .volcengine
    @Published var preferredRecognitionEngine: RecognitionEngine = .volcengine
    @Published var selectedLocalSpeechModel: LocalSpeechModel
    @Published var localSpeechModelStatusText = L10n.tr("Not downloaded")
    @Published var isDownloadingLocalSpeechModel = false
    @Published var downloadingLocalSpeechModelID: String?
    @Published var localSpeechModelDownloadProgress = 0.0
    @Published var volcengineLanguage: TranscriptionLanguage = .auto
    @Published var qwenASRLanguage: TranscriptionLanguage = .auto
    @Published var sherpaOnnxLanguage: TranscriptionLanguage = .auto
    @Published var volcengineAPIKeyDraft = ""
    @Published var volcengineAPIKeyStatusText = L10n.tr("Not set")
    @Published var qwenASRAPIKeyDraft = ""
    @Published var qwenASRAPIKeyStatusText = L10n.tr("Not set")
    @Published var holdShortcut: HoldShortcut
    @Published var isRecordingShortcut = false
    @Published var removesTrailingSentencePeriod: Bool {
        didSet {
            UserDefaults.standard.set(removesTrailingSentencePeriod, forKey: Self.removesTrailingSentencePeriodDefaultsKey)
        }
    }

    let recorder = AudioRecorder()
    let keyMonitor = GlobalFnKeyMonitor()
    let transcriber = SherpaOnnxClient()
    let cloudTranscriber = VolcengineStreamingClient()
    let qwenASRTranscriber = QwenASRStreamingClient()
    let injector = TextInjector()
    lazy var transcriptionOverlay = TranscriptionOverlayController(controller: self)

    var didStart = false
    var currentRecordingURL: URL?
    var permissionRefreshTask: Task<Void, Never>?
    var recognizerPrewarmTask: Task<Void, Never>?
    var localSpeechModelDownloadTask: Task<Void, Never>?
    var activationObserver: NSObjectProtocol?
    var pendingTranscriptionCount = 0
    var recordingTrigger = "Shortcut"
    var recordingTargetApplication: NSRunningApplication?
    var lastTargetApplication: NSRunningApplication?
    var cloudPreconnectTask: Task<Void, Error>?
    var cloudStartTask: Task<Void, Error>?
    var cloudSendTask: Task<Void, Never>?
    var bufferedCloudChunks: [Data] = []
    var isCloudSessionReady = false
    var cloudSessionEngine: RecognitionEngine?
    var cloudSessionLanguage: TranscriptionLanguage?
    var activeRecognitionSessionID = 0
    var overlayHideTask: Task<Void, Never>?
    var recordingStartedAt: Date?
    var recordingStopTask: Task<Void, Never>?
    var hasShortcutEvent = false
    var hasRecordingInfo = false

    let shortcutDefaultsKey = "HoldToTalk.holdShortcut"
    let localSpeechModelDefaultsKey = "HoldToTalk.localSpeechModel"
    static let inputDeviceDefaultsKey = "HoldToTalk.inputDeviceUID"
    static let inputDeviceNameDefaultsKey = "HoldToTalk.inputDeviceName"
    let minimumFnHoldDurationForRecognition: TimeInterval = 0.22
    let recordingTailPadding: TimeInterval = 0.35
    static let manualRecordingTrigger = "Manual"
    static let removesTrailingSentencePeriodDefaultsKey = "HoldToTalk.removesTrailingSentencePeriod"
    static let percentFormatter: NumberFormatter = {
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

    var isSelectedInputDeviceUnavailable: Bool {
        !selectedInputDeviceUID.isEmpty
            && !availableInputDevices.contains { $0.id == selectedInputDeviceUID }
    }

    var unavailableSelectedInputDeviceTitle: String {
        let savedName = Self.loadInputDeviceName()
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

    var menuBarIconAssetName: String {
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

    var needsQwenASRAPIKey: Bool {
        QwenASRCredentialStore.apiKey() == nil
    }

    var isUsingLocalFallbackForMissingAPIKey: Bool {
        preferredRecognitionEngine.isCloud
            && recognitionEngine == .sherpaOnnx
            && needsAPIKey(for: preferredRecognitionEngine)
    }

    private init() {
        let savedShortcut = Self.loadHoldShortcut()
        holdShortcut = savedShortcut
        selectedLocalSpeechModel = Self.loadLocalSpeechModel()
        selectedInputDeviceUID = Self.loadInputDeviceUID()
        removesTrailingSentencePeriod = Self.loadRemovesTrailingSentencePeriod()
        keyMonitor.delegate = self
        keyMonitor.shortcut = savedShortcut
        volcengineAPIKeyDraft = VolcengineCredentialStore.apiKey() ?? ""
        qwenASRAPIKeyDraft = QwenASRCredentialStore.apiKey() ?? ""
        refreshVolcengineAPIKeyState()
        refreshQwenASRAPIKeyState()
        refreshLocalSpeechModelStatus()
        refreshInputDeviceState()
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

        if enabled, recognitionEngine.isCloud {
            preconnectCloudSession()
        } else if !enabled, !isRecording, !isTranscribing {
            cloudPreconnectTask?.cancel()
            cloudPreconnectTask = nil
            Task { [cloudTranscriber] in
                await cloudTranscriber.cancel()
            }
            Task { [qwenASRTranscriber] in
                await qwenASRTranscriber.cancel()
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

    func syncQwenASRAPIKeyDraft() {
        let apiKey = qwenASRAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            clearQwenASRAPIKey()
            return
        }

        guard QwenASRCredentialStore.apiKey() != apiKey else {
            qwenASRAPIKeyDraft = apiKey
            refreshQwenASRAPIKeyState()
            return
        }

        do {
            try QwenASRCredentialStore.saveAPIKey(apiKey)
            qwenASRAPIKeyDraft = apiKey
            refreshQwenASRAPIKeyState()
            resetCloudSession()
            preferredRecognitionEngine = .qwenASR
            recognitionEngine = .qwenASR
            if !isRecording, !isTranscribing {
                statusMessage = L10n.tr("Qwen-ASR API key saved. Cloud recognition is available.")
                preconnectCloudSession()
            }
        } catch {
            qwenASRAPIKeyStatusText = L10n.tr("Could not save API key: %@", error.localizedDescription)
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

    func clearQwenASRAPIKey() {
        do {
            try QwenASRCredentialStore.deleteAPIKey()
            qwenASRAPIKeyDraft = ""
            refreshQwenASRAPIKeyState()
            resetCloudSession()
            fallbackToLocalRecognitionForMissingAPIKey()
        } catch {
            qwenASRAPIKeyStatusText = L10n.tr("Could not clear API key: %@", error.localizedDescription)
        }
    }

    func setPreferredRecognitionEngine(_ engine: RecognitionEngine) {
        preferredRecognitionEngine = engine

        switch engine {
        case .volcengine, .qwenASR:
            guard !needsAPIKey(for: engine) else {
                fallbackToLocalRecognitionForMissingAPIKey()
                return
            }

            recognitionEngine = engine
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
                Task { [qwenASRTranscriber] in
                    await qwenASRTranscriber.cancel()
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
        case .qwenASR:
            guard TranscriptionLanguage.qwenASRLanguages.contains(language) else { return }
            guard qwenASRLanguage != language else { return }
            qwenASRLanguage = language
            if recognitionEngine == .qwenASR {
                resetCloudSession()
            }
            if recognitionEngine == .qwenASR, !isRecording, !isTranscribing {
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
        refreshInputDeviceState()
        setIfChanged(\.accessibilityStatusText, PermissionHelper.isAccessibilityTrusted ? L10n.tr("Granted") : L10n.tr("Not granted"))
    }

}
