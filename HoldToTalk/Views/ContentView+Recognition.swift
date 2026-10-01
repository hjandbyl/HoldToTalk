import SwiftUI

extension MainSectionContent {
    var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Recognition"), systemImage: "waveform")

            Picker(L10n.tr("Engine"), selection: recognitionEngineSelection) {
                Text(L10n.tr("Doubao")).tag(RecognitionEngine.volcengine)
                Text(L10n.tr("Qwen")).tag(RecognitionEngine.qwenASR)
                Text(L10n.tr("Local")).tag(RecognitionEngine.sherpaOnnx)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420, alignment: .leading)

            switch environment.settings.preferredRecognitionEngine {
            case .volcengine:
                volcenginePanel
            case .qwenASR:
                qwenASRPanel
            case .sherpaOnnx:
                localSpeechModelsPanel
            }
        }
    }

    var recognitionLanguagePicker: some View {
        labeledControlRow(L10n.tr("Language")) {
            Picker(L10n.tr("Language"), selection: languageSelection) {
                ForEach(environment.settings.availableLanguages) { language in
                    Text(language.title).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 280, alignment: .leading)
        }
    }

    var localSpeechModelsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.tr("Local Models"), systemImage: "square.stack.3d.up.fill")
            recognitionLanguagePicker

            if needsLocalSpeechModelDownloadNotice {
                localSpeechModelDownloadNotice(showActions: false)
            }

            labeledControlRow(L10n.tr("Selected Model")) {
                Picker(L10n.tr("Selected Model"), selection: localSpeechModelSelection) {
                    ForEach(environment.settings.localSpeechModels) { model in
                        Text(model.displayTitle).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 360, alignment: .leading)

                if environment.models.isDownloadingLocalSpeechModel {
                    Button {
                        environment.models.cancelLocalSpeechModelDownload()
                    } label: {
                        Label(L10n.tr("Cancel"), systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        environment.models.downloadSelectedLocalSpeechModel()
                    } label: {
                        Label(
                            environment.models.isSelectedLocalSpeechModelInstalled ? L10n.tr("Downloaded") : L10n.tr("Download"),
                            systemImage: environment.models.isSelectedLocalSpeechModelInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                        )
                    }
                    .disabled(environment.models.isSelectedLocalSpeechModelInstalled)
                }
            }

            statusRow(title: L10n.tr("Model Status"), value: environment.models.localSpeechModelStatusText)

            if environment.models.isDownloadingLocalSpeechModel {
                ProgressView(value: environment.models.localSpeechModelDownloadProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 520)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(environment.settings.localSpeechModels) { model in
                    localSpeechModelRow(model)
                }
            }
        }
        .padding(16)
        .contentSurface()
    }

    func localSpeechModelRow(_ model: LocalSpeechModel) -> some View {
        let isSelected = environment.settings.selectedLocalSpeechModel == model
        let isInstalled = environment.models.isLocalSpeechModelInstalled(model)
        let isDownloading = environment.models.downloadingLocalSpeechModelID == model.id
        let isDeleting = environment.models.deletingLocalSpeechModelIDs.contains(model.id)

        return Button {
            environment.settings.setLocalSpeechModel(model)
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

                modelActionButton(
                    model: model,
                    isInstalled: isInstalled,
                    isDownloading: isDownloading,
                    isDeleting: isDeleting
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetContentSurface(selected: isSelected)
    }

    @ViewBuilder
    func modelActionButton(
        model: LocalSpeechModel,
        isInstalled: Bool,
        isDownloading: Bool,
        isDeleting: Bool
    ) -> some View {
        if isDeleting {
            ProgressView()
                .controlSize(.small)
        } else if isDownloading {
            Button {
                environment.models.cancelLocalSpeechModelDownload()
            } label: {
                Label(L10n.tr("Cancel"), systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        } else if isInstalled {
            Button {
                environment.models.deleteLocalSpeechModel(model)
            } label: {
                Label(L10n.tr("Delete Model"), systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(
                environment.recording.isRecording
                    || environment.recording.isTranscribing
                    || environment.models.isDownloadingLocalSpeechModel
                    || !environment.models.deletingLocalSpeechModelIDs.isEmpty
            )
        } else {
            Button {
                environment.models.downloadLocalSpeechModel(model)
            } label: {
                Label(L10n.tr("Download"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(environment.models.isDownloadingLocalSpeechModel || !environment.models.deletingLocalSpeechModelIDs.isEmpty)
        }
    }

    var volcenginePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.tr("Doubao Streaming Speech Recognition 2.0"), systemImage: "cloud.fill")
            recognitionLanguagePicker

            if environment.credentials.needsVolcengineAPIKey {
                volcengineAPIKeyNotice(showActions: false)
            }

            labeledControlRow(L10n.tr("API Key")) {
                apiKeyInputField(
                    engine: .volcengine,
                    text: Binding(get: { environment.credentials.volcengineAPIKeyDraft }, set: { environment.credentials.volcengineAPIKeyDraft = $0 })
                )

                Link(destination: volcengineAPIKeyURL) {
                    Label(L10n.tr("Get API Key"), systemImage: "arrow.up.right.square")
                }
            }

            statusRow(title: L10n.tr("Key Status"), value: environment.credentials.volcengineAPIKeyStatusText)
        }
        .padding(16)
        .contentSurface()
    }

    var qwenASRPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.tr("Qwen3-ASR Flash Realtime"), systemImage: "cloud.fill")
            recognitionLanguagePicker

            if environment.credentials.needsQwenASRAPIKey {
                qwenASRAPIKeyNotice(showActions: false)
            }

            labeledControlRow(L10n.tr("API Key")) {
                apiKeyInputField(
                    engine: .qwenASR,
                    text: Binding(get: { environment.credentials.qwenASRAPIKeyDraft }, set: { environment.credentials.qwenASRAPIKeyDraft = $0 })
                )

                Link(destination: qwenASRAPIKeyURL) {
                    Label(L10n.tr("Get API Key"), systemImage: "arrow.up.right.square")
                }
            }

            statusRow(title: L10n.tr("Key Status"), value: environment.credentials.qwenASRAPIKeyStatusText)
        }
        .padding(16)
        .contentSurface()
    }

    func apiKeyInputField(engine: RecognitionEngine, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Group {
                if revealedAPIKeyEngine == engine {
                    TextField(L10n.tr("Paste API key to save automatically"), text: text)
                } else {
                    SecureField(L10n.tr("Paste API key to save automatically"), text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)

            Button {
                revealAPIKey(for: engine)
            } label: {
                Image(systemName: revealedAPIKeyEngine == engine ? "eye.slash" : "eye")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(revealedAPIKeyEngine == engine ? L10n.tr("Hide API Key") : L10n.tr("Show API Key"))
            .accessibilityLabel(revealedAPIKeyEngine == engine ? L10n.tr("Hide API Key") : L10n.tr("Show API Key"))
        }
    }

    func volcengineAPIKeyNotice(showActions: Bool) -> some View {
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
        .contentSurface()
    }

    func qwenASRAPIKeyNotice(showActions: Bool) -> some View {
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

                    Text(L10n.tr("Add a Qwen-ASR API key to enable cloud recognition."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if showActions {
                    HStack(spacing: 8) {
                        Label(L10n.tr("Add API Key"), systemImage: "key.fill")
                            .foregroundStyle(.secondary)

                        Link(destination: qwenASRAPIKeyURL) {
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
        .contentSurface()
    }

    func localSpeechModelDownloadNotice(showActions: Bool) -> some View {
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

                    Text(L10n.tr("Download %@ before using local recognition.", environment.settings.selectedLocalSpeechModel.displayTitle))
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
        .contentSurface()
    }

}
