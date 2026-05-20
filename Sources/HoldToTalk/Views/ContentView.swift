import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: HoldToTalkController

    @AppStorage(AppLanguage.storageKey) private var appLanguageID = AppLanguage.system.rawValue
    @AppStorage(AppDisplayModePreference.storageKey) private var appDisplayModeID = AppDisplayModePreference.savedMode().rawValue
    @State private var selectedSection: MainSection? = .overview
    @State private var apiKeyAutosaveTask: Task<Void, Never>?

    private let labelWidth: CGFloat = 136
    private let volcengineAPIKeyURL = URL(string: "https://console.volcengine.com/speech/new/overview?projectName=default")!

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageID) ?? .system
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .background {
            ShortcutRecorderView(
                isRecording: controller.isRecordingShortcut,
                onCapture: { controller.setHoldShortcut($0) },
                onCancel: { controller.cancelShortcutRecording() }
            )
            .frame(width: 0, height: 0)
        }
    }

    private var sidebar: some View {
        List {
            Section("HoldToTalk") {
                ForEach(MainSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .listRowBackground(
                        (selectedSection ?? .overview) == section
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("HoldToTalk")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: controller.isEnabled ? .green : .secondary)
                    Text(controller.isEnabled ? L10n.tr("Listening") : L10n.tr("Paused"))
                        .font(.callout.weight(.medium))
                }

                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(AppVersion.displayText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailView: some View {
        ScrollView {
            glassContainer {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedSection ?? .overview {
                    case .overview:
                        overviewSection
                    case .recognition:
                        recognitionSection
                    case .shortcut:
                        shortcutSection
                    case .permissions:
                        permissionsSection
                    case .transcript:
                        transcriptSection
                    case .diagnostics:
                        diagnosticsSection
                    case .settings:
                        settingsSection
                    }
                }
                .frame(maxWidth: 980, alignment: .topLeading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle((selectedSection ?? .overview).title)
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            overviewHeroPanel

            if controller.needsMicrophonePermission || controller.needsAccessibilityPermission {
                permissionWarning
            }

            if needsLocalSpeechModelDownloadNotice {
                localSpeechModelDownloadNotice(showActions: true)
            } else if controller.needsVolcengineAPIKey {
                volcengineAPIKeyNotice(showActions: true)
            }

            overviewSetupPanel
            overviewActivityGrid
        }
    }

    private var overviewHeroPanel: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(controller.isRecording ? 0.20 : 0.16))

                Image(systemName: controller.headerSystemImage)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(controller.isRecording ? Color.red : Color.accentColor)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 8) {
                Text(overviewHeadline)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    StatusDot(color: statusColor)
                    Text(controller.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                inputLevelMeter
                    .frame(maxWidth: 440)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                ProminentGlassButton(
                    title: controller.isRecording ? L10n.tr("Stop Test") : L10n.tr("Test Rec"),
                    systemImage: controller.isRecording ? "stop.fill" : "record.circle",
                    tint: controller.isRecording ? .red : nil
                ) {
                    controller.toggleManualRecording()
                }

                Text(L10n.tr("Hold %@ in any app", controller.holdShortcut.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .liquidGlassSurface(interactive: true)
    }

    private var overviewSetupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.tr("Setup"), systemImage: "checklist")

            LazyVGrid(columns: overviewSetupColumns, spacing: 12) {
                setupStepCard(
                    title: L10n.tr("Permissions"),
                    value: permissionsSummary,
                    systemImage: "lock.shield.fill",
                    tint: (controller.needsMicrophonePermission || controller.needsAccessibilityPermission) ? .orange : .green,
                    actionTitle: L10n.tr("Review"),
                    destination: .permissions
                )

                setupStepCard(
                    title: L10n.tr("Recognition"),
                    value: recognitionSummary,
                    systemImage: "waveform",
                    tint: .blue,
                    actionTitle: L10n.tr("Configure"),
                    destination: .recognition
                )

                setupStepCard(
                    title: L10n.tr("Shortcut"),
                    value: controller.holdShortcut.displayName,
                    systemImage: "keyboard.fill",
                    tint: .purple,
                    actionTitle: L10n.tr("Change"),
                    destination: .shortcut
                )
            }
        }
    }

    private var overviewActivityGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
            overviewTranscriptCard
            overviewHealthCard
        }
    }

    private var overviewTranscriptCard: some View {
        Button {
            selectedSection = .transcript
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: L10n.tr("Last transcript"), systemImage: "text.alignleft")

                    Spacer()

                    Label(L10n.tr("Open"), systemImage: "arrow.right")
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(controller.lastTranscript.isEmpty ? L10n.tr("No transcript yet.") : controller.lastTranscript)
                        .font(.callout)
                        .foregroundStyle(controller.lastTranscript.isEmpty ? .secondary : .primary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(minHeight: 126, maxHeight: 160)
                .materialSurface()
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlassSurface(interactive: true)
    }

    private var overviewHealthCard: some View {
        Button {
            selectedSection = .diagnostics
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: L10n.tr("Health"), systemImage: "stethoscope")

                compactStatusRow(title: L10n.tr("Microphone"), value: controller.microphoneStatusText, systemImage: "mic.fill")
                compactStatusRow(title: L10n.tr("Input Device"), value: controller.inputDeviceText, systemImage: "speaker.wave.2.fill")
                compactStatusRow(title: L10n.tr("Target App"), value: controller.targetAppText, systemImage: "app.connected.to.app.below.fill")
                compactStatusRow(title: L10n.tr("Insertion"), value: controller.autoPaste ? L10n.tr("Auto paste on") : L10n.tr("Auto paste off"), systemImage: "text.cursor")

                Spacer(minLength: 0)

                Label(L10n.tr("Open Diagnostics"), systemImage: "arrow.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlassSurface(interactive: true)
    }

    private var heroPanel: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.16))

                Image(systemName: controller.headerSystemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(controller.isRecording ? Color.red : Color.accentColor)
            }
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 8) {
                Text("HoldToTalk")
                    .font(.largeTitle.weight(.semibold))

                HStack(spacing: 10) {
                    StatusDot(color: statusColor)
                    Text(controller.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                inputLevelMeter
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                ProminentGlassButton(
                    title: controller.isRecording ? L10n.tr("Stop Test") : L10n.tr("Test Rec"),
                    systemImage: controller.isRecording ? "stop.fill" : "record.circle",
                    tint: controller.isRecording ? .red : nil
                ) {
                    controller.toggleManualRecording()
                }

                Toggle(L10n.tr("Listening for shortcut"), isOn: $controller.isEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: controller.isEnabled) { _, newValue in
                        controller.setListeningEnabled(newValue)
                    }
            }
            .controlSize(.large)
        }
        .padding(18)
        .liquidGlassSurface(interactive: true)
    }

    private var statusTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            StatusTile(title: L10n.tr("Microphone"), value: controller.microphoneStatusText, systemImage: "mic.fill")
            StatusTile(title: L10n.tr("Input Device"), value: controller.inputDeviceText, systemImage: "speaker.wave.2.fill")
            StatusTile(title: L10n.tr("Target App"), value: controller.targetAppText, systemImage: "app.connected.to.app.below.fill")
            StatusTile(title: L10n.tr("Accessibility"), value: controller.accessibilityStatusText, systemImage: "hand.raised.fill")
        }
    }

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Recognition"), systemImage: "waveform")

            Picker(L10n.tr("Engine"), selection: recognitionEngineSelection) {
                Text(L10n.tr("Doubao")).tag(RecognitionEngine.volcengine)
                Text(L10n.tr("Local")).tag(RecognitionEngine.sherpaOnnx)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420, alignment: .leading)

            switch controller.preferredRecognitionEngine {
            case .volcengine:
                volcenginePanel
            case .sherpaOnnx:
                localSpeechModelsPanel
            }
        }
    }

    private var recognitionLanguagePicker: some View {
        labeledControlRow(L10n.tr("Language")) {
            Picker(L10n.tr("Language"), selection: languageSelection) {
                ForEach(controller.availableLanguages) { language in
                    Text(language.title).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 280, alignment: .leading)
        }
    }

    private var localSpeechModelsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.tr("Local Models"), systemImage: "square.stack.3d.up.fill")
            recognitionLanguagePicker

            if needsLocalSpeechModelDownloadNotice {
                localSpeechModelDownloadNotice(showActions: false)
            }

            labeledControlRow(L10n.tr("Selected Model")) {
                Picker(L10n.tr("Selected Model"), selection: localSpeechModelSelection) {
                    ForEach(controller.localSpeechModels) { model in
                        Text(model.displayTitle).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 360, alignment: .leading)

                if controller.isDownloadingLocalSpeechModel {
                    Button {
                        controller.cancelLocalSpeechModelDownload()
                    } label: {
                        Label(L10n.tr("Cancel"), systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        controller.downloadSelectedLocalSpeechModel()
                    } label: {
                        Label(
                            controller.isSelectedLocalSpeechModelInstalled ? L10n.tr("Downloaded") : L10n.tr("Download"),
                            systemImage: controller.isSelectedLocalSpeechModelInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                        )
                    }
                    .disabled(controller.isSelectedLocalSpeechModelInstalled)
                }
            }

            statusRow(title: L10n.tr("Model Status"), value: controller.localSpeechModelStatusText)

            if controller.isDownloadingLocalSpeechModel {
                ProgressView(value: controller.localSpeechModelDownloadProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 520)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(controller.localSpeechModels) { model in
                    localSpeechModelRow(model)
                }
            }
        }
        .padding(16)
        .liquidGlassSurface(interactive: true)
    }

    private func localSpeechModelRow(_ model: LocalSpeechModel) -> some View {
        let isSelected = controller.selectedLocalSpeechModel == model
        let isInstalled = LocalSpeechModelStore.isInstalled(model)
        let isDownloading = controller.downloadingLocalSpeechModelID == model.id

        return Button {
            controller.setLocalSpeechModel(model)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : (isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle"))
                    .foregroundStyle(isInstalled ? .green : (isDownloading ? .blue : .secondary))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayTitle)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)

                    Text("\(model.sizeDescription) · \(model.supportedLanguageSummary) · \(model.punctuationSummary) · \(model.capabilitySummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                modelActionButton(model: model, isInstalled: isInstalled, isDownloading: isDownloading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialSurface(tint: isSelected ? .blue : nil)
    }

    @ViewBuilder
    private func modelActionButton(model: LocalSpeechModel, isInstalled: Bool, isDownloading: Bool) -> some View {
        if isDownloading {
            Button {
                controller.cancelLocalSpeechModelDownload()
            } label: {
                Label(L10n.tr("Cancel"), systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        } else if isInstalled {
            Button {
                controller.deleteLocalSpeechModel(model)
            } label: {
                Label(L10n.tr("Delete Model"), systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(controller.isDownloadingLocalSpeechModel)
        } else {
            Button {
                controller.downloadLocalSpeechModel(model)
            } label: {
                Label(L10n.tr("Download"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(controller.isDownloadingLocalSpeechModel)
        }
    }

    private var volcenginePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.tr("Doubao Streaming Speech Recognition 2.0"), systemImage: "cloud.fill")
            recognitionLanguagePicker

            if controller.needsVolcengineAPIKey {
                volcengineAPIKeyNotice(showActions: false)
            }

            labeledControlRow(L10n.tr("API Key")) {
                SecureField(L10n.tr("Paste API key to save automatically"), text: $controller.volcengineAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onChange(of: controller.volcengineAPIKeyDraft) { _, _ in
                        scheduleAPIKeyAutosave()
                    }

                Button {
                    controller.clearVolcengineAPIKey()
                } label: {
                    Label(L10n.tr("Clear"), systemImage: "trash")
                }

                Link(destination: volcengineAPIKeyURL) {
                    Label(L10n.tr("Get API Key"), systemImage: "arrow.up.right.square")
                }
            }

            statusRow(title: L10n.tr("Key Status"), value: controller.volcengineAPIKeyStatusText)
        }
        .padding(16)
        .liquidGlassSurface(interactive: true)
    }

    private func volcengineAPIKeyNotice(showActions: Bool) -> some View {
        Button {
            selectedSection = .recognition
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("Local recognition is active"))
                        .font(.headline)

                    Text(L10n.tr("Add a Volcengine API key to enable cloud recognition."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if showActions {
                    HStack(spacing: 8) {
                        Label(L10n.tr("Add API Key"), systemImage: "key.fill")
                            .foregroundStyle(.secondary)

                        Link(destination: volcengineAPIKeyURL) {
                            Label(L10n.tr("Get API Key"), systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .materialSurface(tint: .blue)
    }

    private func localSpeechModelDownloadNotice(showActions: Bool) -> some View {
        Button {
            selectedSection = .recognition
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("Local model is not downloaded"))
                        .font(.headline)

                    Text(L10n.tr("Download %@ before using local recognition.", controller.selectedLocalSpeechModel.displayTitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if showActions {
                    Label(L10n.tr("Download Model"), systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .materialSurface(tint: .blue)
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Shortcut"), systemImage: "keyboard")

            VStack(alignment: .leading, spacing: 14) {
                labeledControlRow(L10n.tr("Shortcut")) {
                    Text(controller.isRecordingShortcut ? L10n.tr("Press shortcut...") : controller.holdShortcut.displayName)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minWidth: 180, alignment: .leading)
                        .materialSurface()

                    Button(controller.isRecordingShortcut ? L10n.tr("Cancel") : L10n.tr("Change")) {
                        if controller.isRecordingShortcut {
                            controller.cancelShortcutRecording()
                        } else {
                            controller.beginShortcutRecording()
                        }
                    }

                    Button(L10n.tr("Reset")) {
                        controller.resetHoldShortcut()
                    }
                }

                labeledControlRow(L10n.tr("Listening")) {
                    Toggle(L10n.tr("Listening for shortcut"), isOn: $controller.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: controller.isEnabled) { _, newValue in
                            controller.setListeningEnabled(newValue)
                        }
                }

                labeledControlRow(L10n.tr("Insertion")) {
                    Toggle(L10n.tr("Paste recognized text automatically"), isOn: $controller.autoPaste)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                labeledControlRow(L10n.tr("Manual Test")) {
                    ProminentGlassButton(
                        title: controller.isRecording ? L10n.tr("Stop Test") : L10n.tr("Test Rec"),
                        systemImage: controller.isRecording ? "stop.fill" : "record.circle",
                        tint: controller.isRecording ? .red : nil
                    ) {
                        controller.toggleManualRecording()
                    }
                }
            }
            .padding(16)
            .liquidGlassSurface(interactive: true)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Settings"), systemImage: "gearshape")

            VStack(alignment: .leading, spacing: 14) {
                labeledControlRow(L10n.tr("Display Language")) {
                    Picker(L10n.tr("Display Language"), selection: appLanguageSelection) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .leading)
                }

                labeledControlRow(L10n.tr("Display In")) {
                    Picker(L10n.tr("Display In"), selection: appDisplayModeSelection) {
                        ForEach(AppDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 380, alignment: .leading)
                }

                labeledControlRow(L10n.tr("Punctuation")) {
                    Toggle(L10n.tr("Remove trailing period"), isOn: $controller.removesTrailingSentencePeriod)
                        .toggleStyle(.switch)
                }
            }
            .padding(16)
            .liquidGlassSurface(interactive: true)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Permissions"), systemImage: "lock.shield.fill")

            if controller.needsMicrophonePermission || controller.needsAccessibilityPermission {
                permissionWarning
            }

            VStack(alignment: .leading, spacing: 14) {
                statusRow(title: L10n.tr("Microphone"), value: controller.microphoneStatusText)
                statusRow(title: L10n.tr("Accessibility"), value: controller.accessibilityStatusText)

                HStack(spacing: 10) {
                    Button {
                        controller.requestMicrophonePermission()
                    } label: {
                        Label(L10n.tr("Request Microphone"), systemImage: "mic.fill")
                    }

                    Button {
                        controller.requestAccessibilityPermission()
                    } label: {
                        Label(L10n.tr("Request Accessibility"), systemImage: "hand.raised.fill")
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .liquidGlassSurface(interactive: true)
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Transcript"), systemImage: "text.alignleft")
            transcriptPanel(minHeight: 320)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Diagnostics"), systemImage: "stethoscope")

            VStack(alignment: .leading, spacing: 12) {
                statusRow(title: L10n.tr("Status"), value: controller.statusMessage)
                statusRow(title: L10n.tr("Microphone"), value: controller.microphoneStatusText)
                statusRow(title: L10n.tr("Input Device"), value: controller.inputDeviceText)
                statusRow(title: L10n.tr("Target App"), value: controller.targetAppText)
                statusRow(title: L10n.tr("Shortcut Event"), value: controller.shortcutEventText)
                statusRow(title: L10n.tr("Last Recording"), value: controller.lastRecordingInfo)
                statusRow(title: L10n.tr("Accessibility"), value: controller.accessibilityStatusText)
                statusRow(title: L10n.tr("Key Status"), value: controller.volcengineAPIKeyStatusText)
                statusRow(title: L10n.tr("Version"), value: AppVersion.displayText)
            }
            .padding(16)
            .materialSurface()
        }
    }

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L10n.tr("Last transcript"), systemImage: "text.alignleft")
            transcriptPanel(minHeight: 118)
        }
    }

    private func transcriptPanel(minHeight: CGFloat) -> some View {
        ScrollView {
            Text(controller.lastTranscript.isEmpty ? L10n.tr("No transcript yet.") : controller.lastTranscript)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundStyle(controller.lastTranscript.isEmpty ? .secondary : .primary)
                .padding(12)
        }
        .frame(minHeight: minHeight)
        .materialSurface()
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Permissions required"))
                        .font(.headline)

                    Text(L10n.tr("Microphone and Accessibility access are required."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                if controller.needsMicrophonePermission {
                    Button {
                        controller.openMicrophoneSettings()
                    } label: {
                        Label(L10n.tr("Open Microphone Settings"), systemImage: "mic.fill")
                    }
                }

                if controller.needsAccessibilityPermission {
                    Button {
                        controller.openAccessibilitySettings()
                    } label: {
                        Label(L10n.tr("Open Accessibility Settings"), systemImage: "hand.raised.fill")
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(tint: .orange, interactive: true)
    }

    private var inputLevelMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary.opacity(0.22))

                Capsule()
                    .fill(controller.isRecording ? Color.red : Color.accentColor)
                    .frame(width: max(8, proxy.size.width * controller.inputLevel))
                    .opacity(controller.isRecording ? 1 : 0.45)
            }
        }
        .frame(height: 6)
        .accessibilityLabel(L10n.tr("Input level"))
    }

    private var statusColor: Color {
        if controller.isRecording {
            return .red
        }
        if controller.isTranscribing {
            return .blue
        }
        return controller.isEnabled ? .green : .secondary
    }

    private var overviewHeadline: String {
        if controller.isRecording {
            return L10n.tr("Listening now")
        }
        if controller.isTranscribing {
            return L10n.tr("Finishing transcription")
        }
        if controller.needsMicrophonePermission || controller.needsAccessibilityPermission {
            return L10n.tr("Complete setup to start")
        }
        return controller.isEnabled ? L10n.tr("Ready for hold-to-talk") : L10n.tr("Listening is paused")
    }

    private var permissionsSummary: String {
        if controller.needsMicrophonePermission && controller.needsAccessibilityPermission {
            return L10n.tr("Microphone and Accessibility needed")
        }
        if controller.needsMicrophonePermission {
            return L10n.tr("Microphone needed")
        }
        if controller.needsAccessibilityPermission {
            return L10n.tr("Accessibility needed")
        }
        return L10n.tr("All permissions granted")
    }

    private var recognitionSummary: String {
        if controller.isUsingLocalFallbackForMissingAPIKey {
            return L10n.tr("Volcengine selected, using local until API key is added")
        }

        if controller.preferredRecognitionEngine == .sherpaOnnx {
            return "\(controller.preferredRecognitionEngine.title) · \(controller.selectedLocalSpeechModel.displayTitle) · \(controller.language.title)"
        }

        return "\(controller.preferredRecognitionEngine.title) · \(controller.language.title)"
    }

    private var needsLocalSpeechModelDownloadNotice: Bool {
        controller.preferredRecognitionEngine == .sherpaOnnx && !controller.isSelectedLocalSpeechModelInstalled
    }

    private var overviewSetupColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 176), spacing: 12),
            GridItem(.flexible(minimum: 176), spacing: 12),
            GridItem(.flexible(minimum: 176), spacing: 12)
        ]
    }

    private var languageSelection: Binding<TranscriptionLanguage> {
        Binding {
            controller.language
        } set: { language in
            controller.setLanguage(language)
        }
    }

    private var recognitionEngineSelection: Binding<RecognitionEngine> {
        Binding {
            controller.preferredRecognitionEngine
        } set: { engine in
            controller.setPreferredRecognitionEngine(engine)
        }
    }

    private var localSpeechModelSelection: Binding<LocalSpeechModel> {
        Binding {
            controller.selectedLocalSpeechModel
        } set: { model in
            controller.setLocalSpeechModel(model)
        }
    }

    private var appLanguageSelection: Binding<AppLanguage> {
        Binding {
            appLanguage
        } set: { language in
            appLanguageID = language.rawValue
        }
    }

    private var appDisplayModeSelection: Binding<AppDisplayMode> {
        Binding {
            AppDisplayMode(rawValue: appDisplayModeID) ?? AppDisplayModePreference.defaultMode
        } set: { mode in
            appDisplayModeID = mode.rawValue
        }
    }

    private func controlGroup<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .materialSurface()
    }

    private func labeledControlRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            content()
        }
        .font(.callout)
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func scheduleAPIKeyAutosave() {
        apiKeyAutosaveTask?.cancel()
        apiKeyAutosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            controller.syncVolcengineAPIKeyDraft()
        }
    }

    private func setupStepCard(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        actionTitle: String,
        destination: MainSection
    ) -> some View {
        Button {
            selectedSection = destination
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 20)

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)

                Label(actionTitle, systemImage: "arrow.right")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .materialSurface(tint: tint)
    }

    private func compactStatusRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)

            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                content()
            }
        } else {
            content()
        }
    }
}

private enum MainSection: String, CaseIterable, Identifiable {
    case overview
    case recognition
    case shortcut
    case permissions
    case transcript
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.tr("Overview")
        case .recognition: return L10n.tr("Recognition")
        case .shortcut: return L10n.tr("Shortcut")
        case .permissions: return L10n.tr("Permissions")
        case .transcript: return L10n.tr("Transcript")
        case .diagnostics: return L10n.tr("Diagnostics")
        case .settings: return L10n.tr("Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .recognition: return "waveform"
        case .shortcut: return "keyboard"
        case .permissions: return "lock.shield"
        case .transcript: return "text.alignleft"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .labelStyle(.titleAndIcon)
    }
}

private struct StatusTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .materialSurface()
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.35), radius: 4)
    }
}

private struct GlassButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(title, systemImage: systemImage, action: action)
            .buttonStyle(.glass)
            .accessibilityLabel(title)
        } else {
            Button(title, systemImage: systemImage, action: action)
            .buttonStyle(.bordered)
            .accessibilityLabel(title)
        }
    }
}

private struct ProminentGlassButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(title, systemImage: systemImage, action: action)
            .buttonStyle(.glassProminent)
            .tint(tint)
            .accessibilityLabel(title)
        } else {
            Button(title, systemImage: systemImage, action: action)
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .accessibilityLabel(title)
        }
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassSurface(tint: Color? = nil, interactive: Bool = false) -> some View {
        self.materialSurface(tint: tint)
    }

    func materialSurface(tint: Color? = nil) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke((tint ?? Color(nsColor: .separatorColor)).opacity(0.35), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}
