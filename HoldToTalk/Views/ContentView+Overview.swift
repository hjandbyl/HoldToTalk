import SwiftUI

extension MainSectionContent {
    var overviewSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Overview"), systemImage: "rectangle.grid.2x2")

            overviewHeroPanel

            if environment.devices.needsMicrophonePermission || environment.devices.needsAccessibilityPermission {
                permissionWarning
            }

            if needsLocalSpeechModelDownloadNotice {
                localSpeechModelDownloadNotice(showActions: true)
            } else if environment.settings.preferredRecognitionEngine == .volcengine, environment.credentials.needsVolcengineAPIKey {
                volcengineAPIKeyNotice(showActions: true)
            } else if environment.settings.preferredRecognitionEngine == .qwenASR, environment.credentials.needsQwenASRAPIKey {
                qwenASRAPIKeyNotice(showActions: true)
            }

            overviewSetupPanel
            overviewActivityGrid
        }
    }

    var overviewHeroPanel: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(environment.recording.isRecording ? Color.recordingAccent.opacity(0.14) : Color.accentColor.opacity(0.10))

                Image(systemName: environment.recording.headerSystemImage)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(environment.recording.isRecording ? Color.recordingAccent : Color.accentColor)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text(overviewHeadline)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    StatusDot(color: statusColor)
                    Text(environment.recording.statusMessage)
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
                    title: environment.recording.isRecording ? L10n.tr("Stop Test") : L10n.tr("Test Rec"),
                    systemImage: environment.recording.isRecording ? "stop.fill" : "record.circle",
                    tint: environment.recording.isRecording ? .recordingAccent : nil
                ) {
                    environment.toggleManualRecording()
                }

                Text(L10n.tr("Hold %@ in any app", environment.settings.holdShortcut.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .contentSurface()
    }

    var overviewSetupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.tr("Setup"), systemImage: "checklist")

            overviewSetupCards
        }
    }

    private var overviewSetupCards: some View {
        HStack(alignment: .top, spacing: 12) {
            setupStepCard(
                title: L10n.tr("Permissions"),
                value: permissionsSummary,
                systemImage: "lock.shield.fill",
                tint: (environment.devices.needsMicrophonePermission || environment.devices.needsAccessibilityPermission) ? .orange : .secondary,
                actionTitle: L10n.tr("Review"),
                destination: .permissions
            )

            setupStepCard(
                title: L10n.tr("Recognition"),
                value: recognitionSummary,
                systemImage: "waveform",
                tint: .secondary,
                actionTitle: L10n.tr("Configure"),
                destination: .recognition
            )

            setupStepCard(
                title: L10n.tr("Shortcut"),
                value: environment.settings.holdShortcut.displayName,
                systemImage: "keyboard.fill",
                tint: .secondary,
                actionTitle: L10n.tr("Change"),
                destination: .shortcut
            )
        }
    }

    var overviewActivityGrid: some View {
        overviewActivityCards
    }

    private var overviewActivityCards: some View {
        HStack(alignment: .top, spacing: 14) {
            overviewTranscriptCard
            overviewHealthCard
        }
    }

    var overviewTranscriptCard: some View {
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
                    Text(environment.recording.lastTranscript.isEmpty ? L10n.tr("No transcript yet.") : environment.recording.lastTranscript)
                        .font(.callout)
                        .foregroundStyle(environment.recording.lastTranscript.isEmpty ? .secondary : .primary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(minHeight: 126, maxHeight: 160)
                .insetContentSurface()
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentSurface()
    }

    var overviewHealthCard: some View {
        Button {
            selectedSection = .diagnostics
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: L10n.tr("Health"), systemImage: "stethoscope")

                compactStatusRow(title: L10n.tr("Microphone"), value: environment.devices.microphoneStatusText, systemImage: "mic.fill")
                compactStatusRow(title: L10n.tr("Input Device"), value: environment.devices.inputDeviceText, systemImage: "speaker.wave.2.fill")
                compactStatusRow(title: L10n.tr("Target App"), value: environment.diagnostics.targetAppText, systemImage: "app.connected.to.app.below.fill")
                compactStatusRow(title: L10n.tr("Insertion"), value: environment.settings.autoPaste ? L10n.tr("Auto paste on") : L10n.tr("Auto paste off"), systemImage: "text.cursor")

                Spacer(minLength: 0)

                Label(L10n.tr("Open Diagnostics"), systemImage: "arrow.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentSurface()
    }

}
