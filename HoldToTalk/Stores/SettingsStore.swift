import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var isEnabled = true
    @Published var autoPaste = true
    @Published var preferredRecognitionEngine: RecognitionEngine = .volcengine
    @Published var selectedLocalSpeechModel: LocalSpeechModel
    @Published var volcengineLanguage: TranscriptionLanguage = .auto
    @Published var qwenASRLanguage: TranscriptionLanguage = .auto
    @Published var sherpaOnnxLanguage: TranscriptionLanguage = .auto
    @Published var holdShortcut: HoldShortcut
    @Published var isRecordingShortcut = false
    @Published var removesTrailingSentencePeriod: Bool {
        didSet { defaults.set(removesTrailingSentencePeriod, forKey: "HoldToTalk.removesTrailingSentencePeriod") }
    }
    private let defaults: UserDefaults
    var configurationDidChange: (() -> Void)?
    var shortcutDidChange: ((HoldShortcut) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        holdShortcut = defaults.data(forKey: "HoldToTalk.holdShortcut").flatMap { try? JSONDecoder().decode(HoldShortcut.self, from: $0) } ?? .defaultShortcut
        selectedLocalSpeechModel = defaults.string(forKey: "HoldToTalk.localSpeechModel").map(LocalSpeechModel.model(id:)) ?? .defaultModel
        removesTrailingSentencePeriod = defaults.object(forKey: "HoldToTalk.removesTrailingSentencePeriod") == nil
            ? true : defaults.bool(forKey: "HoldToTalk.removesTrailingSentencePeriod")
    }

    var language: TranscriptionLanguage { language(for: preferredRecognitionEngine) }
    var availableLanguages: [TranscriptionLanguage] { availableLanguages(for: preferredRecognitionEngine) }
    var localSpeechModels: [LocalSpeechModel] { LocalSpeechModel.all }

    func language(for engine: RecognitionEngine) -> TranscriptionLanguage {
        let candidate: TranscriptionLanguage
        switch engine {
        case .volcengine: candidate = volcengineLanguage
        case .qwenASR: candidate = qwenASRLanguage
        case .sherpaOnnx: candidate = sherpaOnnxLanguage
        }
        return availableLanguages(for: engine).contains(candidate) ? candidate : .auto
    }
    func availableLanguages(for engine: RecognitionEngine) -> [TranscriptionLanguage] {
        switch engine {
        case .volcengine: return TranscriptionLanguage.volcengineLanguages
        case .qwenASR: return TranscriptionLanguage.qwenASRLanguages
        case .sherpaOnnx: return selectedLocalSpeechModel.supportedLanguages
        }
    }
    func setLanguage(_ language: TranscriptionLanguage) {
        guard availableLanguages.contains(language) else { return }
        switch preferredRecognitionEngine {
        case .volcengine: volcengineLanguage = language
        case .qwenASR: qwenASRLanguage = language
        case .sherpaOnnx: sherpaOnnxLanguage = language
        }
        configurationDidChange?()
    }
    func setPreferredRecognitionEngine(_ engine: RecognitionEngine) {
        preferredRecognitionEngine = engine
        configurationDidChange?()
    }
    func setLocalSpeechModel(_ model: LocalSpeechModel) {
        selectedLocalSpeechModel = model
        defaults.set(model.id, forKey: "HoldToTalk.localSpeechModel")
        if !model.supportedLanguages.contains(sherpaOnnxLanguage) { sherpaOnnxLanguage = .auto }
        configurationDidChange?()
    }
    func beginShortcutRecording() { isRecordingShortcut = true }
    func cancelShortcutRecording() { isRecordingShortcut = false }
    func setHoldShortcut(_ shortcut: HoldShortcut) {
        guard shortcut.isValidGlobalShortcut else { return }
        holdShortcut = shortcut
        isRecordingShortcut = false
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "HoldToTalk.holdShortcut") }
        shortcutDidChange?(shortcut)
    }
    func resetHoldShortcut() { setHoldShortcut(.defaultShortcut) }
}
