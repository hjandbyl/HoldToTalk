import SwiftUI

extension ContentView {
    var shortcutSection: some View {
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
                        tint: controller.isRecording ? .recordingAccent : nil
                    ) {
                        controller.toggleManualRecording()
                    }
                }
            }
            .padding(16)
            .liquidGlassSurface(interactive: true)
        }
    }

    var settingsSection: some View {
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

                labeledControlRow(L10n.tr("Microphone")) {
                    HStack(spacing: 8) {
                        Picker(L10n.tr("Microphone"), selection: inputDeviceSelection) {
                            Text(L10n.tr("Auto (%@)", AudioDeviceInspector.defaultInputDeviceName())).tag("")
                            ForEach(controller.availableInputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                            if !controller.selectedInputDeviceUID.isEmpty
                                && !controller.availableInputDevices.contains(where: { $0.id == controller.selectedInputDeviceUID }) {
                                Text(L10n.tr("Selected microphone unavailable")).tag(controller.selectedInputDeviceUID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .leading)
                        .disabled(controller.isRecording)

                        Button {
                            controller.refreshInputDeviceState()
                        } label: {
                            Label(L10n.tr("Refresh"), systemImage: "arrow.clockwise")
                        }
                        .disabled(controller.isRecording)
                    }
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

    var permissionsSection: some View {
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
                statusRow(title: L10n.tr("Status"), value: controller.statusMessage)
                statusRow(title: L10n.tr("Microphone"), value: controller.microphoneStatusText)
                statusRow(title: L10n.tr("Input Device"), value: controller.inputDeviceText)
                statusRow(title: L10n.tr("Target App"), value: controller.targetAppText)
                statusRow(title: L10n.tr("Shortcut Event"), value: controller.shortcutEventText)
                statusRow(title: L10n.tr("Last Recording"), value: controller.lastRecordingInfo)
                statusRow(title: L10n.tr("Accessibility"), value: controller.accessibilityStatusText)
                statusRow(title: L10n.tr("Doubao Key"), value: controller.volcengineAPIKeyStatusText)
                statusRow(title: L10n.tr("Qwen Key"), value: controller.qwenASRAPIKeyStatusText)
                statusRow(title: L10n.tr("Version"), value: AppVersion.displayText)
            }
            .padding(16)
            .materialSurface()
        }
    }

    func transcriptPanel(minHeight: CGFloat) -> some View {
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

    var inputLevelMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary.opacity(0.22))

                Capsule()
                    .fill(controller.isRecording ? Color.recordingAccent : Color.accentColor)
                    .frame(width: max(8, proxy.size.width * controller.inputLevel))
                    .opacity(controller.isRecording ? 1 : 0.45)
            }
        }
        .frame(height: 6)
        .accessibilityLabel(L10n.tr("Input level"))
    }

}
