import Foundation

@MainActor
final class DictationSession {
    let id = UUID()
    let configuration: SessionConfiguration
    let capture: any RecordingCapture
    let cloud: (any CloudRecognizing)?
    let audio = CloudAudioBuffer()
    let startedAt: TimeInterval
    var releasedAt: TimeInterval?
    var resultAt: TimeInterval?
    var firstFrameAt: TimeInterval?
    var phase: DictationPhase = .preparing
    var partial = ""
    var file: URL?
    var captureTask: Task<URL, Error>?
    var captureStopTask: Task<CapturedRecording?, Never>?
    var recognitionTask: Task<String, Error>?
    var completionTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var result: Result<String, Error>?
    var terminationReason = "completed"
    var cancelled = false
    var finishingFailure = false
    var cleanupTask: Task<Void, Never>?

    init(configuration: SessionConfiguration, capture: any RecordingCapture, cloud: (any CloudRecognizing)?, startedAt: TimeInterval) {
        self.configuration = configuration
        self.capture = capture
        self.cloud = cloud
        self.startedAt = startedAt
    }
}

enum OverlayEvent {
    case show, hide
}

@MainActor
final class DictationCoordinator {
    let recording: RecordingStore
    let diagnostics: DiagnosticsStore
    private let makeCapture: () -> any RecordingCapture
    private let makeCloud: (SessionConfiguration) -> any CloudRecognizing
    private let local: any LocalRecognizing
    private let injector: any TextInserting
    private let clock: any DictationClock
    private var sessions: [DictationSession] = []
    private var active: DictationSession?
    private var insertionTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var overlaySessionID: UUID?
    private var pendingStart: (configuration: SessionConfiguration, pressedAt: TimeInterval, releasedAt: TimeInterval?)?
    private var shuttingDown = false
    var onOverlay: ((OverlayEvent) -> Void)?
    var onIdle: (() -> Void)?
    var outstandingCount: Int { sessions.count }
    var activeInputDeviceUID: String? { active?.configuration.inputDeviceUID }
    var activeRequiresAccessibility: Bool { active.map { !$0.configuration.trigger.isManual } ?? false }

    init(recording: RecordingStore, diagnostics: DiagnosticsStore,
         makeCapture: @escaping () -> any RecordingCapture,
         makeCloud: @escaping (SessionConfiguration) -> any CloudRecognizing,
         local: any LocalRecognizing, injector: any TextInserting,
         clock: any DictationClock = SystemDictationClock()) {
        self.recording = recording
        self.diagnostics = diagnostics
        self.makeCapture = makeCapture
        self.makeCloud = makeCloud
        self.local = local
        self.injector = injector
        self.clock = clock
    }

    func isModelInUse(_ model: LocalSpeechModel) -> Bool {
        sessions.contains { $0.configuration.engine == .sherpaOnnx && $0.configuration.model == model }
    }

    func start(_ configuration: SessionConfiguration) {
        guard !shuttingDown else { return }
        if let active {
            if active.phase == .stopping {
                if sessions.count < 8, pendingStart == nil {
                    pendingStart = (configuration, clock.now(), nil)
                } else if sessions.count >= 8 { recording.statusMessage = DictationError.busy.localizedDescription }
            } else {
                active.stopTask?.cancel()
                active.stopTask = nil
                active.releasedAt = nil
            }
            return
        }
        begin(configuration, pressedAt: clock.now())
    }

    private func begin(_ configuration: SessionConfiguration, pressedAt: TimeInterval) {
        guard sessions.count < 8 else {
            recording.statusMessage = DictationError.busy.localizedDescription
            return
        }
        let session = DictationSession(configuration: configuration, capture: makeCapture(),
            cloud: configuration.engine.isCloud ? makeCloud(configuration) : nil, startedAt: pressedAt)
        sessions.append(session)
        active = session
        overlaySessionID = session.id
        hideTask?.cancel()
        recording.liveTranscription.update("")
        recording.inputVisualization.reset()
        recording.statusMessage = configuration.trigger.isManual ? L10n.tr("Manual recording...")
            : L10n.tr("Recording while %@ is held.", configuration.trigger.title)
        diagnostics.targetAppText = configuration.target?.name ?? L10n.tr("No target app captured.")
        if !configuration.trigger.isManual { onOverlay?(.show) }
        publish()

        if let cloud = session.cloud {
            let language = configuration.language
            let audio = session.audio
            let id = session.id
            session.recognitionTask = Task.detached { [weak self] in
                try await withTaskCancellationHandler {
                    try await cloud.start(language: language) { [weak self] event in
                        Task { @MainActor in
                            switch event {
                            case .update(let update): self?.receive(update, sessionID: id)
                            case .failure(let error): await self?.failActive(id: id, error: error)
                            }
                        }
                    }
                    for try await chunk in audio.stream {
                        try Task.checkCancellation()
                        try await cloud.sendAudio(chunk)
                        audio.consumed(chunk)
                    }
                    return try await cloud.finish(finalAudio: nil)
                } onCancel: {
                    audio.finish(throwing: CancellationError())
                    Task { await cloud.cancel() }
                }
            }
            observeResult(session)
        }
        let capture = session.capture
        let audio = session.audio
        let id = session.id
        let clock = clock
        let audioHandler: (@Sendable (Data) -> Void)?
        if configuration.engine.isCloud {
            audioHandler = { [weak self] chunk in
                if !audio.append(chunk) {
                    Task { @MainActor in await self?.failActive(id: id, error: DictationError.bufferOverflow) }
                }
            }
        } else { audioHandler = nil }
        session.captureTask = Task { [weak self] in
            let url = try await capture.start(inputDeviceUID: configuration.inputDeviceUID, audio: audioHandler,
                analysis: { [weak self] analysis in
                    Task { @MainActor in
                        guard let self, self.active?.id == id else { return }
                        self.recording.inputVisualization.update(with: analysis)
                    }
                }, failure: { [weak self] error in
                    Task { @MainActor in await self?.failActive(id: id, error: error) }
                }, firstFrame: { [weak self] in
                    let time = clock.now()
                    Task { @MainActor in self?.sessions.first { $0.id == id }?.firstFrameAt = time }
                })
            session.file = url
            if session.phase == .preparing { session.phase = .recording }
            return url
        }
        let captureTask = session.captureTask!
        Task { [weak self] in
            do {
                _ = try await captureTask.value
            } catch {
                await self?.failActive(id: id, error: error)
            }
        }
    }

    func pause() { pendingStart = nil; release() }

    func release() {
        if pendingStart != nil {
            pendingStart?.releasedAt = clock.now()
            return
        }
        guard let active, active.stopTask == nil, active.phase != .stopping else { return }
        release(active, at: clock.now())
    }

    private func release(_ session: DictationSession, at time: TimeInterval) {
        session.releasedAt = time
        session.stopTask = Task { [weak self] in
            do {
                if session.configuration.tailPadding > 0 { try await self?.clock.sleep(for: session.configuration.tailPadding) }
                try Task.checkCancellation()
                await self?.finishCapture(session)
            } catch { }
        }
    }

    private func finishCapture(_ session: DictationSession) async {
        guard active?.id == session.id, session.phase != .stopping else { return }
        session.phase = .stopping
        let duration = (session.releasedAt ?? clock.now()) - session.startedAt
        let captured = await stopCapture(session, duration: duration)
        guard active?.id == session.id, !session.finishingFailure else { return }
        active = nil
        recording.inputVisualization.reset()
        session.phase = .recognizing
        publish()
        scheduleHide(sessionID: session.id, after: 2)
        defer { beginPending() }
        if session.cancelled || TranscriptPolicy.isShortTap(trigger: session.configuration.trigger, duration: duration, partial: session.partial) {
            session.cancelled = true
            session.terminationReason = "shortTap"
            session.audio.finish(throwing: CancellationError())
            session.recognitionTask?.cancel()
            await session.cloud?.cancel()
            complete(session, with: .failure(CancellationError()))
            return
        }
        guard let captured else {
            session.audio.finish(throwing: DictationError.captureFailed)
            session.recognitionTask?.cancel()
            await session.cloud?.cancel()
            complete(session, with: .failure(DictationError.captureFailed))
            return
        }
        if let error = captured.failure {
            session.audio.finish(throwing: error)
            session.recognitionTask?.cancel()
            await session.cloud?.cancel()
            complete(session, with: .failure(error))
            return
        }
        diagnostics.lastRecordingInfo = captured.summary
        if session.configuration.engine.isCloud {
            if !captured.finalAudio.isEmpty { session.audio.append(captured.finalAudio) }
            session.audio.finish()
        } else {
            let configuration = session.configuration
            let local = local
            session.recognitionTask = Task.detached {
                try Task.checkCancellation()
                let text = try await local.transcribe(audioURL: captured.url,
                    language: configuration.language.localSpeechModelLanguageCode(for: configuration.model), model: configuration.model)
                try Task.checkCancellation()
                return text
            }
            observeResult(session)
        }
        if active == nil { recording.statusMessage = L10n.tr("Transcribing queued recordings...") }
    }

    private func beginPending() {
        guard let next = pendingStart, !shuttingDown, active == nil else { return }
        pendingStart = nil
        begin(next.configuration, pressedAt: next.pressedAt)
        if let releasedAt = next.releasedAt, let active { release(active, at: releasedAt) }
    }

    private func observeResult(_ session: DictationSession) {
        guard let task = session.recognitionTask else { return }
        session.completionTask = Task { [weak self] in
            do {
                let text = try await task.value
                try Task.checkCancellation()
                self?.complete(session, with: .success(text))
            } catch {
                guard let self else { return }
                if self.active?.id == session.id {
                    await self.failActive(id: session.id, error: error)
                } else {
                    self.complete(session, with: .failure(error))
                }
            }
        }
    }

    func invalidateActive(_ error: Error = DictationError.captureFailed) {
        guard let id = active?.id else { return }
        Task { await failActive(id: id, error: error) }
    }

    private func failActive(id: UUID, error: Error) async {
        guard let session = sessions.first(where: { $0.id == id }), session.result == nil, !session.finishingFailure else { return }
        // Claim cleanup before awaiting, but do not publish a result until capture is stopped.
        session.finishingFailure = true
        session.phase = .stopping
        session.stopTask?.cancel()
        session.audio.finish(throwing: error)
        session.recognitionTask?.cancel()
        await session.cloud?.cancel()
        if active?.id == id {
            _ = await stopCapture(session, duration: clock.now() - session.startedAt)
            active = nil
            recording.inputVisualization.reset()
            beginPending()
        }
        session.terminationReason = DictationError.category(error)
        session.result = .failure(error)
        session.phase = .failed
        session.resultAt = clock.now()
        cleanupAudio(session, success: false)
        scheduleHide(sessionID: id, after: 0.2)
        publish()
        drainResults()
    }

    private func complete(_ session: DictationSession, with result: Result<String, Error>) {
        guard sessions.contains(where: { $0.id == session.id }), session.result == nil, !session.finishingFailure else { return }
        session.result = session.cancelled ? .failure(CancellationError()) : result
        session.resultAt = clock.now()
        session.phase = .waitingForInsertion
        if case .failure(let error) = session.result {
            if session.terminationReason == "completed" { session.terminationReason = DictationError.category(error) }
            cleanupAudio(session, success: false)
        }
        publish()
        drainResults()
    }

    private func drainResults() {
        guard insertionTask == nil else { return }
        insertionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.insertionTask = nil
                self.publish()
                if self.sessions.isEmpty { self.onIdle?() }
            }
            while let session = self.sessions.first, let result = session.result {
                var outcome = "failed"
                var insertionMilliseconds: Double?
                do {
                    try Task.checkCancellation()
                    guard !session.cancelled, !self.shuttingDown else { throw CancellationError() }
                    let text = TranscriptPolicy.finalize(try result.get(), removingTrailingPeriod: session.configuration.removesTrailingSentencePeriod)
                    self.recording.lastTranscript = text
                    if !text.isEmpty, session.configuration.autoPaste {
                        let insertion = try await self.injector.insert(text, target: session.configuration.target)
                        insertionMilliseconds = (self.clock.now() - (session.resultAt ?? self.clock.now())) * 1_000
                        outcome = insertion == .accessibilityWrite ? "written" : "eventsPosted"
                    } else { outcome = text.isEmpty ? "empty" : "ready" }
                    if self.overlaySessionID == session.id, self.active == nil { self.recording.liveTranscription.update(text) }
                    if self.active == nil {
                        self.recording.statusMessage = text.isEmpty ? L10n.tr("No speech recognized.")
                            : outcome == "eventsPosted" ? L10n.tr("Text input sent to the target app.")
                            : outcome == "written" ? L10n.tr("Inserted recognized text.") : L10n.tr("Transcription ready.")
                    }
                    session.phase = .completed
                } catch {
                    outcome = error is CancellationError ? "cancelled" : "failed"
                    if session.terminationReason == "completed" { session.terminationReason = DictationError.category(error) }
                    session.phase = error is CancellationError ? .cancelled : .failed
                    if self.active == nil {
                        self.recording.statusMessage = error is CancellationError
                            ? L10n.tr("Recording canceled.") : error.localizedDescription
                    }
                }
                self.scheduleHide(sessionID: session.id, after: 0.25)
                self.diagnostics.record(SessionMetrics(id: session.id, engine: session.configuration.engine,
                    firstFrameMilliseconds: session.firstFrameAt.map { ($0 - session.startedAt) * 1_000 },
                    resultMilliseconds: session.releasedAt.flatMap { released in session.resultAt.map { ($0 - released) * 1_000 } },
                    insertionMilliseconds: insertionMilliseconds, bufferedBytes: session.audio.peak, outcome: outcome,
                    reason: session.terminationReason, remainingSessions: max(0, self.sessions.count - 1)))
                self.cleanupAudio(session, success: outcome != "failed" && outcome != "cancelled")
                await session.cleanupTask?.value
                session.captureTask = nil
                session.captureStopTask = nil
                session.recognitionTask = nil
                session.completionTask = nil
                session.stopTask = nil
                self.sessions.removeAll { $0.id == session.id }
                self.publish()
            }
        }
    }

    private func receive(_ update: RecognitionUpdate, sessionID: UUID) {
        guard let session = active, session.id == sessionID, session.result == nil else { return }
        session.partial = update.text
        recording.liveTranscription.update(update.text)
    }

    private func scheduleHide(sessionID: UUID, after delay: TimeInterval) {
        guard overlaySessionID == sessionID else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do {
                try await self?.clock.sleep(for: delay)
                try Task.checkCancellation()
                guard let self, self.overlaySessionID == sessionID, self.active == nil else { return }
                self.onOverlay?(.hide)
            } catch { }
        }
    }

    private func cleanupAudio(_ session: DictationSession, success: Bool) {
        guard let url = session.file else { return }
        session.file = nil
        let authorization = success && session.configuration.retainDiagnosticAudio ? diagnostics.retentionAuthorization : nil
        session.cleanupTask = Task.detached(priority: .utility) {
            if let authorization, (try? authorization.check()) != nil {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("HoldToTalk-last.wav")
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: url, to: destination)
                if (try? authorization.check()) == nil { try? FileManager.default.removeItem(at: destination) }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func stopCapture(_ session: DictationSession, duration: TimeInterval) async -> CapturedRecording? {
        if let task = session.captureStopTask { return await task.value }
        let start = session.captureTask
        let capture = session.capture
        let task = Task {
            _ = try? await start?.value
            return await capture.stop(heldDuration: duration)
        }
        session.captureStopTask = task
        let captured = await task.value
        session.file = captured?.url ?? session.file
        return captured
    }

    private func publish() {
        recording.update(recording: active != nil, pending: sessions.filter { $0.id != active?.id }.count)
    }

    func shutdown() async {
        shuttingDown = true
        pendingStart = nil
        hideTask?.cancel()
        insertionTask?.cancel()
        for session in sessions {
            session.terminationReason = "shutdown"
            session.cancelled = true
            session.stopTask?.cancel()
            session.recognitionTask?.cancel()
            session.audio.finish(throwing: CancellationError())
        }
        for session in sessions {
            await session.cloud?.cancel()
            _ = try? await session.captureTask?.value
            if active?.id == session.id { _ = await stopCapture(session, duration: clock.now() - session.startedAt) }
            _ = try? await session.recognitionTask?.value
            cleanupAudio(session, success: false)
            await session.cleanupTask?.value
        }
        await insertionTask?.value
        sessions.removeAll()
        active = nil
        onOverlay?(.hide)
        publish()
    }
}
