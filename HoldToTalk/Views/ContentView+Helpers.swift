import SwiftUI

extension ContentView {
    var statusColor: Color {
        if controller.isRecording {
            return .red
        }
        if controller.isTranscribing {
            return .blue
        }
        return controller.isEnabled ? .green : .secondary
    }

    var overviewHeadline: String {
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

    var permissionsSummary: String {
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

    var recognitionSummary: String {
        if controller.isUsingLocalFallbackForMissingAPIKey {
            return L10n.tr("Volcengine selected, using local until API key is added")
        }

        if controller.preferredRecognitionEngine == .sherpaOnnx {
            return "\(controller.preferredRecognitionEngine.title) · \(controller.selectedLocalSpeechModel.displayTitle) · \(controller.language.title)"
        }

        return "\(controller.preferredRecognitionEngine.title) · \(controller.language.title)"
    }

    var needsLocalSpeechModelDownloadNotice: Bool {
        controller.preferredRecognitionEngine == .sherpaOnnx && !controller.isSelectedLocalSpeechModelInstalled
    }

    var overviewSetupColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 176), spacing: 12),
            GridItem(.flexible(minimum: 176), spacing: 12),
            GridItem(.flexible(minimum: 176), spacing: 12)
        ]
    }

    var languageSelection: Binding<TranscriptionLanguage> {
        Binding {
            controller.language
        } set: { language in
            controller.setLanguage(language)
        }
    }

    var recognitionEngineSelection: Binding<RecognitionEngine> {
        Binding {
            controller.preferredRecognitionEngine
        } set: { engine in
            controller.setPreferredRecognitionEngine(engine)
        }
    }

    var localSpeechModelSelection: Binding<LocalSpeechModel> {
        Binding {
            controller.selectedLocalSpeechModel
        } set: { model in
            controller.setLocalSpeechModel(model)
        }
    }

    var appLanguageSelection: Binding<AppLanguage> {
        Binding {
            appLanguage
        } set: { language in
            appLanguageID = language.rawValue
        }
    }

    var appDisplayModeSelection: Binding<AppDisplayMode> {
        Binding {
            AppDisplayMode(rawValue: appDisplayModeID) ?? AppDisplayModePreference.defaultMode
        } set: { mode in
            appDisplayModeID = mode.rawValue
        }
    }

    func labeledControlRow<Content: View>(
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

    func statusRow(title: String, value: String) -> some View {
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

    func scheduleAPIKeyAutosave() {
        apiKeyAutosaveTask?.cancel()
        apiKeyAutosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            controller.syncVolcengineAPIKeyDraft()
        }
    }

    func setupStepCard(
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

    func compactStatusRow(title: String, value: String, systemImage: String) -> some View {
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
    func glassContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                content()
            }
        } else {
            content()
        }
    }
}
