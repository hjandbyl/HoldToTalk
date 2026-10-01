import SwiftUI

extension MainSectionContent {
    var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Shortcut"), systemImage: "keyboard")

            VStack(alignment: .leading, spacing: 14) {
                labeledControlRow(L10n.tr("Shortcut")) {
                    Text(environment.settings.isRecordingShortcut ? L10n.tr("Press shortcut...") : environment.settings.holdShortcut.displayName)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minWidth: 180, alignment: .leading)
                        .insetContentSurface()

                    Button(environment.settings.isRecordingShortcut ? L10n.tr("Cancel") : L10n.tr("Change")) {
                        if environment.settings.isRecordingShortcut {
                            environment.settings.cancelShortcutRecording()
                        } else {
                            environment.settings.beginShortcutRecording()
                        }
                    }

                    Button(L10n.tr("Reset")) {
                        environment.settings.resetHoldShortcut()
                    }
                }

                labeledControlRow(L10n.tr("Listening")) {
                    Toggle(L10n.tr("Listening for shortcut"), isOn: Binding(get: { environment.settings.isEnabled }, set: { environment.settings.isEnabled = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: environment.settings.isEnabled) { _, newValue in
                            environment.setListeningEnabled(newValue)
                        }
                }

                labeledControlRow(L10n.tr("Insertion")) {
                    Toggle(L10n.tr("Paste recognized text automatically"), isOn: Binding(get: { environment.settings.autoPaste }, set: { environment.settings.autoPaste = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                labeledControlRow(L10n.tr("Manual Test")) {
                    ProminentGlassButton(
                        title: environment.recording.isRecording ? L10n.tr("Stop Test") : L10n.tr("Test Rec"),
                        systemImage: environment.recording.isRecording ? "stop.fill" : "record.circle",
                        tint: environment.recording.isRecording ? .recordingAccent : nil
                    ) {
                        environment.toggleManualRecording()
                    }
                }
            }
            .padding(16)
            .contentSurface()
        }
    }

    var settingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Settings"), systemImage: "gearshape")

            VStack(alignment: .leading, spacing: 14) {
                labeledControlRow(L10n.tr("Display Language")) {
                    Picker(L10n.tr("Display Language"), selection: $appLanguageID) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .leading)
                }

                labeledControlRow(L10n.tr("Display In")) {
                    Picker(L10n.tr("Display In"), selection: $appDisplayModeID) {
                        ForEach(AppDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 380, alignment: .leading)
                }

                labeledControlRow(L10n.tr("Microphone")) {
                    HStack(spacing: 8) {
                        Picker(L10n.tr("Microphone"), selection: inputDeviceSelection) {
                            Text(L10n.tr("Auto (%@)", AudioDeviceInspector.defaultInputDeviceName())).tag("")
                            if environment.devices.isSelectedInputDeviceUnavailable {
                                Text(environment.devices.unavailableSelectedInputDeviceTitle)
                                    .tag(environment.devices.selectedInputDeviceUID)
                            }
                            ForEach(environment.devices.availableInputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .leading)
                        .disabled(environment.recording.isRecording)

                        Button {
                            environment.devices.refreshInputDeviceState()
                        } label: {
                            Label(L10n.tr("Refresh"), systemImage: "arrow.clockwise")
                        }
                        .disabled(environment.recording.isRecording)
                    }
                }

                labeledControlRow(L10n.tr("Punctuation")) {
                    Toggle(L10n.tr("Remove trailing period"), isOn: Binding(get: { environment.settings.removesTrailingSentencePeriod }, set: { environment.settings.removesTrailingSentencePeriod = $0 }))
                        .toggleStyle(.switch)
                }
            }
            .padding(16)
            .contentSurface()
        }
    }

    var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Permissions"), systemImage: "lock.shield.fill")

            if environment.devices.needsMicrophonePermission || environment.devices.needsAccessibilityPermission {
                permissionWarning
            }

            VStack(alignment: .leading, spacing: 14) {
                statusRow(title: L10n.tr("Microphone"), value: environment.devices.microphoneStatusText)
                statusRow(title: L10n.tr("Accessibility"), value: environment.devices.accessibilityStatusText)

                HStack(spacing: 10) {
                    Button {
                        environment.devices.requestMicrophonePermission()
                    } label: {
                        Label(L10n.tr("Request Microphone"), systemImage: "mic.fill")
                    }

                    Button {
                        environment.devices.requestAccessibilityPermission()
                    } label: {
                        Label(L10n.tr("Request Accessibility"), systemImage: "hand.raised.fill")
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .contentSurface()
        }
    }

    var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Transcript"), systemImage: "text.alignleft")
            transcriptPanel(minHeight: 320)
        }
    }

    var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: L10n.tr("Diagnostics"), systemImage: "stethoscope")

            VStack(alignment: .leading, spacing: 12) {
                statusRow(title: L10n.tr("Status"), value: environment.recording.statusMessage)
                statusRow(title: L10n.tr("Microphone"), value: environment.devices.microphoneStatusText)
                statusRow(title: L10n.tr("Input Device"), value: environment.devices.inputDeviceText)
                statusRow(title: L10n.tr("Target App"), value: environment.diagnostics.targetAppText)
                statusRow(title: L10n.tr("Shortcut Event"), value: environment.diagnostics.shortcutEventText)
                statusRow(title: L10n.tr("Last Recording"), value: environment.diagnostics.lastRecordingInfo)
                statusRow(title: L10n.tr("Accessibility"), value: environment.devices.accessibilityStatusText)
                statusRow(title: L10n.tr("Doubao Key"), value: environment.credentials.volcengineAPIKeyStatusText)
                statusRow(title: L10n.tr("Qwen Key"), value: environment.credentials.qwenASRAPIKeyStatusText)
                statusRow(title: L10n.tr("Version"), value: AppVersion.displayText)
                statusRow(title: L10n.tr("Pending Recordings"), value: String(environment.recording.pendingCount))
                if let metric = environment.diagnostics.metrics.last {
                    statusRow(title: L10n.tr("Last Timing"), value: metric.formattedTimings)
                }
                Toggle(L10n.tr("Retain diagnostic audio"), isOn: Binding(
                    get: { environment.diagnostics.retainDiagnosticAudio },
                    set: { environment.diagnostics.retainDiagnosticAudio = $0 }))
                    .help(L10n.tr("Keep the last successful recording locally for troubleshooting."))
            }
            .padding(16)
            .contentSurface()
        }
    }

    func transcriptPanel(minHeight: CGFloat) -> some View {
        ScrollView {
            Text(environment.recording.lastTranscript.isEmpty ? L10n.tr("No transcript yet.") : environment.recording.lastTranscript)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundStyle(environment.recording.lastTranscript.isEmpty ? .secondary : .primary)
                .padding(12)
        }
        .frame(minHeight: minHeight)
        .contentSurface()
    }

    var permissionWarning: some View {
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
                if environment.devices.needsMicrophonePermission {
                    Button {
                        environment.devices.openMicrophoneSettings()
                    } label: {
                        Label(L10n.tr("Open Microphone Settings"), systemImage: "mic.fill")
                    }
                }

                if environment.devices.needsAccessibilityPermission {
                    Button {
                        environment.devices.openAccessibilitySettings()
                    } label: {
                        Label(L10n.tr("Open Accessibility Settings"), systemImage: "hand.raised.fill")
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    var inputLevelMeter: some View {
        AudioInputLevelMeter(
            visualization: environment.recording.inputVisualization,
            isRecording: environment.recording.isRecording
        )
        .accessibilityLabel(L10n.tr("Input level"))
    }

}

private struct AudioInputLevelMeter: View {
    @ObservedObject var visualization: AudioInputVisualization
    let isRecording: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary.opacity(0.22))

                Capsule()
                    .fill(isRecording ? Color.recordingAccent : Color.accentColor)
                    .frame(width: max(8, proxy.size.width * visualization.snapshot.level))
                    .opacity(isRecording ? 1 : 0.45)
            }
        }
        .frame(height: 6)
    }
}
