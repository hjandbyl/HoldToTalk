import SwiftUI
import Combine

struct ContentView: View {
    let environment: AppEnvironment
    @State private var selectedSection: MainSection? = .overview
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selectedSection) {
                Section("HoldToTalk") {
                    ForEach(MainSection.allCases) { section in
                        Label(section.title, systemImage: section.systemImage).tag(section).accessibilityLabel(section.title)
                    }
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationTitle("HoldToTalk")
            .background { NativeSidebarCollapseLock().frame(width: 0, height: 0) }
            .safeAreaInset(edge: .bottom) { SidebarStatus(settings: environment.settings, recording: environment.recording) }
        } detail: {
            MainSectionContent(environment: environment, section: selectedSection ?? .overview, selectedSection: $selectedSection)
                .id(selectedSection ?? .overview)
        }
        .background { ShortcutCaptureSurface(settings: environment.settings) }
    }
}

private struct SidebarStatus: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var recording: RecordingStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(color: settings.isEnabled ? .green : .secondary)
                Text(settings.isEnabled ? L10n.tr("Listening") : L10n.tr("Paused")).font(.callout.weight(.medium))
            }
            Text(recording.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(AppVersion.displayText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(12)
    }
}

private struct ShortcutCaptureSurface: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        ShortcutRecorderView(isRecording: settings.isRecordingShortcut,
            onCapture: { settings.setHoldShortcut($0) }, onCancel: { settings.cancelShortcutRecording() })
            .frame(width: 0, height: 0)
    }
}

@MainActor
final class SectionObservation: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []
    init(environment: AppEnvironment, section: MainSection) {
        let publishers: [ObservableObjectPublisher]
        switch section {
        case .overview: publishers = [environment.settings.objectWillChange, environment.credentials.objectWillChange,
            environment.devices.objectWillChange, environment.models.objectWillChange, environment.recording.objectWillChange, environment.diagnostics.objectWillChange]
        case .recognition: publishers = [environment.settings.objectWillChange, environment.credentials.objectWillChange,
            environment.models.objectWillChange, environment.recording.objectWillChange]
        case .shortcut: publishers = [environment.settings.objectWillChange, environment.recording.objectWillChange]
        case .permissions: publishers = [environment.devices.objectWillChange]
        case .transcript: publishers = [environment.recording.objectWillChange]
        case .diagnostics: publishers = [environment.recording.objectWillChange, environment.devices.objectWillChange,
            environment.credentials.objectWillChange, environment.diagnostics.objectWillChange]
        case .settings: publishers = [environment.settings.objectWillChange, environment.devices.objectWillChange, environment.recording.objectWillChange]
        }
        for publisher in publishers { publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions) }
    }
}

struct MainSectionContent: View {
    let environment: AppEnvironment
    let section: MainSection
    @Binding var selectedSection: MainSection?
    @StateObject private var observation: SectionObservation
    @AppStorage(AppLanguage.storageKey) var appLanguageID = AppLanguage.system.rawValue
    @AppStorage(AppDisplayModePreference.storageKey) var appDisplayModeID = AppDisplayModePreference.savedMode().rawValue
    @State var apiKeyRevealTask: Task<Void, Never>?
    @State var revealedAPIKeyEngine: RecognitionEngine?
    let labelWidth: CGFloat = 136
    let volcengineAPIKeyURL = URL(string: "https://console.volcengine.com/speech/new/overview?projectName=default")!
    let qwenASRAPIKeyURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing/model/settings/api-key")!
    var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageID) ?? .system }

    init(environment: AppEnvironment, section: MainSection, selectedSection: Binding<MainSection?>) {
        self.environment = environment
        self.section = section
        _selectedSection = selectedSection
        _observation = StateObject(wrappedValue: SectionObservation(environment: environment, section: section))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch section {
                case .overview: overviewSection
                case .recognition: recognitionSection
                case .shortcut: shortcutSection
                case .permissions: permissionsSection
                case .transcript: transcriptSection
                case .diagnostics: diagnosticsSection
                case .settings: settingsSection
                }
            }
            .frame(maxWidth: 980, alignment: .topLeading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(section.title)
        .onDisappear { apiKeyRevealTask?.cancel(); revealedAPIKeyEngine = nil }
    }
}
