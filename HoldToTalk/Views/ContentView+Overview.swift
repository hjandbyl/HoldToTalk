import SwiftUI

extension ContentView {
    var overviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            overviewHeroPanel

            if controller.needsMicrophonePermission || controller.needsAccessibilityPermission {
                permissionWarning
            }

            if needsLocalSpeechModelDownloadNotice {
                localSpeechModelDownloadNotice(showActions: true)
            } else if controller.preferredRecognitionEngine == .volcengine, controller.needsVolcengineAPIKey {
                volcengineAPIKeyNotice(showActions: true)
            } else if controller.preferredRecognitionEngine == .qwenASR, controller.needsQwenASRAPIKey {
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

    var overviewSetupPanel: some View {
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

    var overviewActivityGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
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

    var overviewHealthCard: some View {
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

}
