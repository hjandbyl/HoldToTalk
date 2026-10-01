import SwiftUI

extension MainSectionContent {
    var statusColor: Color {
        if environment.recording.isRecording {
            return .recordingAccent
        }
        if environment.recording.isTranscribing {
            return .blue
        }
        return environment.settings.isEnabled ? .green : .secondary
    }

    var overviewHeadline: String {
        if environment.recording.isRecording {
            return L10n.tr("Listening now")
        }
        if environment.recording.isTranscribing {
            return L10n.tr("Finishing transcription")
        }
        if environment.devices.needsMicrophonePermission || environment.devices.needsAccessibilityPermission {
            return L10n.tr("Complete setup to start")
        }
        return environment.settings.isEnabled ? L10n.tr("Ready for hold-to-talk") : L10n.tr("Listening is paused")
    }

    var permissionsSummary: String {
        if environment.devices.needsMicrophonePermission && environment.devices.needsAccessibilityPermission {
            return L10n.tr("Microphone and Accessibility needed")
        }
        if environment.devices.needsMicrophonePermission {
            return L10n.tr("Microphone needed")
        }
        if environment.devices.needsAccessibilityPermission {
            return L10n.tr("Accessibility needed")
        }
        return L10n.tr("All permissions granted")
    }

    var recognitionSummary: String {
        if environment.isUsingLocalFallbackForMissingAPIKey {
            return L10n.tr("%@ selected, using local until API key is added", environment.settings.preferredRecognitionEngine.title)
        }

        if environment.settings.preferredRecognitionEngine == .sherpaOnnx {
            return "\(environment.settings.preferredRecognitionEngine.title) · \(environment.settings.selectedLocalSpeechModel.displayTitle) · \(environment.settings.language.title)"
        }

        return "\(environment.settings.preferredRecognitionEngine.title) · \(environment.settings.language.title)"
    }

    var needsLocalSpeechModelDownloadNotice: Bool {
        environment.settings.preferredRecognitionEngine == .sherpaOnnx && !environment.models.isSelectedLocalSpeechModelInstalled
    }

    var languageSelection: Binding<TranscriptionLanguage> {
        Binding {
            environment.settings.language
        } set: { language in
            environment.settings.setLanguage(language)
        }
    }

    var recognitionEngineSelection: Binding<RecognitionEngine> {
        Binding {
            environment.settings.preferredRecognitionEngine
        } set: { engine in
            environment.settings.setPreferredRecognitionEngine(engine)
        }
    }

    var localSpeechModelSelection: Binding<LocalSpeechModel> {
        Binding {
            environment.settings.selectedLocalSpeechModel
        } set: { model in
            environment.settings.setLocalSpeechModel(model)
        }
    }

    var inputDeviceSelection: Binding<String> {
        Binding {
            environment.devices.selectedInputDeviceUID
        } set: { uid in
            environment.devices.setInputDeviceUID(uid)
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

    func revealAPIKey(for engine: RecognitionEngine) {
        if revealedAPIKeyEngine == engine {
            apiKeyRevealTask?.cancel()
            apiKeyRevealTask = nil
            revealedAPIKeyEngine = nil
            return
        }

        revealedAPIKeyEngine = engine
        apiKeyRevealTask?.cancel()
        apiKeyRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, revealedAPIKeyEngine == engine else { return }
            revealedAPIKeyEngine = nil
            apiKeyRevealTask = nil
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
        .contentSurface()
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

}
