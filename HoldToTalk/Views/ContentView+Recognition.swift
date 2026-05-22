import SwiftUI

extension ContentView {
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

            switch controller.preferredRecognitionEngine {
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
                ForEach(controller.availableLanguages) { language in
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

    func localSpeechModelRow(_ model: LocalSpeechModel) -> some View {
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
    func modelActionButton(model: LocalSpeechModel, isInstalled: Bool, isDownloading: Bool) -> some View {
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

    var volcenginePanel: some View {
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
                        scheduleAPIKeyAutosave(for: .volcengine)
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

    var qwenASRPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.tr("Qwen3-ASR Flash Realtime"), systemImage: "cloud.fill")
            recognitionLanguagePicker

            if controller.needsQwenASRAPIKey {
                qwenASRAPIKeyNotice(showActions: false)
            }

            labeledControlRow(L10n.tr("API Key")) {
                SecureField(L10n.tr("Paste API key to save automatically"), text: $controller.qwenASRAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onChange(of: controller.qwenASRAPIKeyDraft) { _, _ in
                        scheduleAPIKeyAutosave(for: .qwenASR)
                    }

                Button {
                    controller.clearQwenASRAPIKey()
                } label: {
                    Label(L10n.tr("Clear"), systemImage: "trash")
                }

                Link(destination: qwenASRAPIKeyURL) {
                    Label(L10n.tr("Get API Key"), systemImage: "arrow.up.right.square")
                }
            }

            statusRow(title: L10n.tr("Key Status"), value: controller.qwenASRAPIKeyStatusText)
        }
        .padding(16)
        .liquidGlassSurface(interactive: true)
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
        .materialSurface(tint: .blue)
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
        .materialSurface(tint: .blue)
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

}
