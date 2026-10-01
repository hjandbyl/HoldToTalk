import AppKit
import AVFoundation
import Foundation
import Combine

/// Composition root. Views observe individual stores; this object does not relay their changes.
@MainActor
final class AppEnvironment: GlobalFnKeyMonitorDelegate {
    let settings: SettingsStore
    let credentials: CredentialStore
    let devices: DevicePermissionStore
    let models: ModelLibraryStore
    let recording: RecordingStore
    let diagnostics: DiagnosticsStore
    let dictation: DictationCoordinator
    private let local: any LocalRecognizing
    private let keyMonitor = GlobalFnKeyMonitor()
    private let cloudFactory: CloudSessionFactory
    private let overlay: TranscriptionOverlayController
    private var prewarmTask: Task<Void, Never>?
    private var prewarmModel: LocalSpeechModel?
    private var prewarmID: UUID?
    private var observer: NSObjectProtocol?
    private var lastTarget: NSRunningApplication?
    private var recordingSubscription: AnyCancellable?
    private var recordedDefaultDeviceUID: String?
    private var previousPermissionState: Int?
    private var started = false
    private var stopping = false

    init() {
        let settings = SettingsStore()
        let credentials = CredentialStore()
        let devices = DevicePermissionStore()
        let recording = RecordingStore()
        let diagnostics = DiagnosticsStore()
        let local = SherpaOnnxClient()
        let models = ModelLibraryStore(settings: settings, recognizer: local)
        let cloudFactory = CloudSessionFactory(credentials: credentials, settings: settings)
        self.settings = settings
        self.credentials = credentials
        self.devices = devices
        self.recording = recording
        self.diagnostics = diagnostics
        self.local = local
        self.models = models
        self.cloudFactory = cloudFactory
        dictation = DictationCoordinator(recording: recording, diagnostics: diagnostics,
            makeCapture: { AudioCaptureService() }, makeCloud: { cloudFactory.take($0) },
            local: local, injector: TextInjector())
        overlay = TranscriptionOverlayController(recording: recording)
        recordingSubscription = recording.$isRecording.removeDuplicates().sink { [weak self] active in
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                self.devices.setRecordingActive(active)
            }
        }
        keyMonitor.delegate = self
        keyMonitor.shortcut = settings.holdShortcut
        settings.configurationDidChange = { [weak self] in self?.prepareRecognition() }
        settings.shortcutDidChange = { [weak self] shortcut in
            guard let self else { return }
            if !self.recording.isRecording { self.keyMonitor.shortcut = shortcut; try? self.keyMonitor.rearm() }
            self.diagnostics.shortcutEventText = L10n.tr("Shortcut set to %@.", shortcut.displayName)
        }
        credentials.didSave = { [weak self] engine in
            guard let self, !self.stopping else { return }
            if !self.credentials.needsAPIKey(for: engine) { self.settings.preferredRecognitionEngine = engine }
            self.prepareRecognition()
        }
        devices.didRefresh = { [weak self] in self?.devicesDidRefresh() }
        models.isInUse = { [weak self] model in self?.dictation.isModelInUse(model) == true || self?.prewarmModel == model }
        models.didChange = { [weak self] in self?.prepareRecognition() }
        models.reportStatus = { [weak recording] status in
            guard let recording, !recording.isRecording else { return }
            recording.statusMessage = status
        }
        dictation.onOverlay = { [weak overlay] event in
            if case .show = event { overlay?.show() } else { overlay?.hide() }
        }
        dictation.onIdle = { [weak self] in
            guard let self, !self.stopping else { return }
            if self.settings.isEnabled, self.devices.hasAccessibilityPermission {
                self.keyMonitor.shortcut = self.settings.holdShortcut
                try? self.keyMonitor.rearm()
            }
            self.prepareRecognition()
        }
    }

    var recognitionEngine: RecognitionEngine {
        credentials.needsAPIKey(for: settings.preferredRecognitionEngine) ? .sherpaOnnx : settings.preferredRecognitionEngine
    }
    var isUsingLocalFallbackForMissingAPIKey: Bool {
        settings.preferredRecognitionEngine.isCloud && recognitionEngine == .sherpaOnnx
    }

    func start() {
        guard !started else { return }
        started = true
        devices.start()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { devices.requestMicrophonePermission() }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.track(application) }
        }
        if let application = NSWorkspace.shared.frontmostApplication { track(application) }
        prepareRecognition()
    }
    private func track(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier, !application.isTerminated else { return }
        lastTarget = application
        diagnostics.targetAppText = application.localizedName ?? L10n.tr("Unknown")
    }
    func applicationDidBecomeActive() {
        guard !stopping else { return }
        devices.refresh()
        models.refreshLocalSpeechModelStatus()
    }
    func appLanguageDidChange() {
        devices.refresh()
        credentials.refreshStatus()
        models.refreshLocalSpeechModelStatus()
        if !recording.isRecording && !recording.isTranscribing { updateIdleStatus() }
    }
    func setListeningEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if !enabled { dictation.pause(); keyMonitor.stop(); cloudFactory.reset() }
        else { devices.refresh(); prepareRecognition() }
        if !recording.isRecording && !recording.isTranscribing { updateIdleStatus() }
    }
    func toggleManualRecording() {
        if recording.isRecording { dictation.release() } else { startRecording(trigger: .manual) }
    }
    private func startRecording(trigger: RecordingTrigger) {
        devices.refreshPermissionStatus()
        guard devices.hasMicrophonePermission else {
            recording.statusMessage = L10n.tr("Microphone permission is required.")
            devices.requestMicrophonePermission()
            return
        }
        guard trigger.isManual || devices.hasAccessibilityPermission else { devices.refresh(); return }
        let engine = recognitionEngine
        guard !models.deletingLocalSpeechModelIDs.contains(settings.selectedLocalSpeechModel.id) || engine.isCloud else {
            recording.statusMessage = L10n.tr("The selected model is being deleted.")
            return
        }
        guard engine != .sherpaOnnx || models.isSelectedLocalSpeechModelInstalled else {
            recording.statusMessage = L10n.tr("Download %@ before using local recognition.", settings.selectedLocalSpeechModel.displayTitle)
            return
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication { track(frontmost) }
        let target = lastTarget.map { InsertionTarget(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName ?? L10n.tr("Unknown")) }
        let device = devices.activeInputDeviceUID
        if !recording.isRecording { recordedDefaultDeviceUID = device == nil ? AudioDeviceInspector.defaultInputDevice()?.id : nil }
        dictation.start(SessionConfiguration(engine: engine, language: settings.language(for: engine),
            model: settings.selectedLocalSpeechModel, inputDeviceUID: device, target: target, trigger: trigger,
            autoPaste: settings.autoPaste, removesTrailingSentencePeriod: settings.removesTrailingSentencePeriod,
            tailPadding: AudioDeviceInspector.isBluetoothInputDevice(uid: device) ? 0.35 : 0,
            retainDiagnosticAudio: diagnostics.retainDiagnosticAudio))
    }
    private func devicesDidRefresh() {
        guard !stopping else { return }
        let permissionState = (devices.hasMicrophonePermission ? 1 : 0) | (devices.hasAccessibilityPermission ? 2 : 0)
        let permissionsChanged = previousPermissionState != permissionState
        previousPermissionState = permissionState
        if recording.isRecording {
            let missingDevice = dictation.activeInputDeviceUID.map { uid in !devices.availableInputDevices.contains { $0.id == uid } } ?? false
            let defaultChanged = recordedDefaultDeviceUID.map { $0 != AudioDeviceInspector.defaultInputDevice()?.id } ?? false
            if defaultChanged || !devices.hasMicrophonePermission || (dictation.activeRequiresAccessibility && !devices.hasAccessibilityPermission) || missingDevice {
                dictation.invalidateActive()
            }
        }
        if permissionsChanged { updateIdleStatus() }
        if devices.hasAccessibilityPermission, settings.isEnabled, !keyMonitor.isRunning {
            do { try keyMonitor.start(); updateIdleStatus() } catch { recording.statusMessage = error.localizedDescription }
        } else if !devices.hasAccessibilityPermission { keyMonitor.stop() }
    }
    private func updateIdleStatus() {
        guard !recording.isRecording, !recording.isTranscribing else { return }
        if !settings.isEnabled { recording.statusMessage = L10n.tr("Paused.") }
        else if !devices.hasMicrophonePermission { recording.statusMessage = L10n.tr("Microphone permission is required.") }
        else if !devices.hasAccessibilityPermission {
            recording.statusMessage = L10n.tr("Accessibility permission is required for global shortcut detection and text insertion.")
        } else { recording.statusMessage = L10n.tr("Listening for %@.", settings.holdShortcut.displayName) }
    }
    private func prepareRecognition() {
        guard !stopping else { return }
        cloudFactory.reset()
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmModel = nil
        prewarmID = nil
        models.refreshLocalSpeechModelStatus()
        guard settings.isEnabled else { return }
        if recognitionEngine.isCloud {
            cloudFactory.prepare()
        } else if models.isSelectedLocalSpeechModelInstalled {
            let model = settings.selectedLocalSpeechModel
            guard !models.deletingLocalSpeechModelIDs.contains(model.id) else { return }
            let language = settings.language(for: .sherpaOnnx).localSpeechModelLanguageCode(for: model)
            prewarmModel = model
            let id = UUID()
            prewarmID = id
            prewarmTask = Task { [weak self, local] in
                defer { if self?.prewarmID == id { self?.prewarmModel = nil; self?.prewarmTask = nil; self?.prewarmID = nil } }
                do { try await local.preload(model: model, language: language) }
                catch { if !Task.isCancelled, self?.recording.isRecording == false { self?.recording.statusMessage = error.localizedDescription } }
            }
        }
    }
    nonisolated func globalFnKeyMonitor(_ monitor: GlobalFnKeyMonitor, didChangeFnKeyDown isDown: Bool) {
        Task { @MainActor in
            guard self.settings.isEnabled, !self.settings.isRecordingShortcut, !self.stopping else { return }
            let time = Date().formatted(.dateTime.hour().minute().second())
            self.diagnostics.shortcutEventText = L10n.tr(isDown ? "%@ down %@" : "%@ up %@", self.settings.holdShortcut.displayName, time)
            if isDown { self.startRecording(trigger: .shortcut(self.settings.holdShortcut.displayName)) }
            else { self.dictation.release() }
        }
    }
    func shutdown() async {
        stopping = true
        recordingSubscription?.cancel()
        keyMonitor.stop()
        devices.shutdown()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        credentials.shutdown()
        await cloudFactory.shutdown()
        prewarmTask?.cancel()
        await dictation.shutdown()
        await models.shutdown()
        await prewarmTask?.value
        await local.clearCache()
    }
}

@MainActor
final class CloudSessionFactory {
    private let credentials: CredentialStore
    private let settings: SettingsStore
    private var prepared: (id: UUID, engine: RecognitionEngine, language: TranscriptionLanguage, client: any CloudRecognizing)?
    private var task: Task<Void, Never>?
    private var retiring: [UUID: Task<Void, Never>] = [:]
    init(credentials: CredentialStore, settings: SettingsStore) { self.credentials = credentials; self.settings = settings }
    func take(_ engine: RecognitionEngine) -> any CloudRecognizing {
        if let prepared, prepared.engine == engine, prepared.language == settings.language(for: engine) {
            self.prepared = nil
            task = nil
            return prepared.client
        }
        return StreamingRecognitionSession(engine: engine, apiKey: credentials.apiKey(for: engine))
    }
    func prepare() {
        let engine = settings.preferredRecognitionEngine
        guard engine.isCloud, !credentials.needsAPIKey(for: engine), prepared == nil else { return }
        let language = settings.language(for: engine)
        let id = UUID()
        let client = StreamingRecognitionSession(engine: engine, apiKey: credentials.apiKey(for: engine), idleFailureHandler: { [weak self] in
            Task { @MainActor in
                guard self?.prepared?.id == id else { return }
                self?.prepared = nil
                self?.task = nil
            }
        })
        prepared = (id, engine, language, client)
        task = Task { [weak self] in
            do { try await client.prepare(language: language) }
            catch {
                if self?.prepared?.id == id { self?.prepared = nil; self?.task = nil }
                await client.cancel()
            }
        }
    }
    func reset() {
        task?.cancel()
        task = nil
        if let prepared {
            let id = UUID()
            retiring[id] = Task { [weak self] in
                await prepared.client.cancel()
                self?.retiring[id] = nil
            }
        }
        prepared = nil
    }
    func shutdown() async {
        let preparing = task
        reset()
        await preparing?.value
        for task in retiring.values { await task.value }
        retiring.removeAll()
    }
}
