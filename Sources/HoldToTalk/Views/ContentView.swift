import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: HoldToTalkController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                statusRow(title: "Status", value: controller.statusMessage)
                statusRow(title: "Microphone", value: controller.microphoneStatusText)
                statusRow(title: "Input Device", value: controller.inputDeviceText)
                statusRow(title: "Target App", value: controller.targetAppText)
                statusRow(title: "Fn Event", value: controller.fnEventText)
                statusRow(title: "Last Recording", value: controller.lastRecordingInfo)
                statusRow(title: "Accessibility", value: controller.accessibilityStatusText)
                statusRow(title: "Input Monitoring", value: controller.inputMonitoringStatusText)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Engine")
                        .foregroundStyle(.secondary)
                        .frame(width: 132, alignment: .leading)

                    Picker("Engine", selection: $controller.recognitionEngine) {
                        ForEach(RecognitionEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                    .onChange(of: controller.recognitionEngine) { _, _ in
                        controller.recognitionEngineDidChange()
                    }
                }

                HStack {
                    Text("Language")
                        .foregroundStyle(.secondary)
                        .frame(width: 132, alignment: .leading)

                    Picker("Language", selection: $controller.language) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                    .disabled(controller.recognitionEngine == .volcengine)
                }

                Toggle("Paste recognized text automatically", isOn: $controller.autoPaste)

                Toggle("Listen for Fn key", isOn: $controller.isEnabled)
                    .onChange(of: controller.isEnabled) { _, newValue in
                        controller.setListeningEnabled(newValue)
                    }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Last transcript")
                    .font(.headline)

                ScrollView {
                    Text(controller.lastTranscript.isEmpty ? "No transcript yet." : controller.lastTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .foregroundStyle(controller.lastTranscript.isEmpty ? .secondary : .primary)
                        .padding(10)
                }
                .frame(minHeight: 86)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)

            HStack {
                Button(controller.isRecording ? "Stop Test" : "Test Rec") {
                    controller.toggleManualRecording()
                }

                Button("Request Microphone") {
                    controller.requestMicrophonePermission()
                }

                Button("Request Accessibility") {
                    controller.requestAccessibilityPermission()
                }

                Button("Request Input Monitoring") {
                    controller.requestInputMonitoringPermission()
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: controller.headerSystemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(controller.isRecording ? Color.red : Color.accentColor)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("HoldToTalk")
                    .font(.title2.weight(.semibold))

                Text("Hold Fn, speak, release Fn to insert text into the focused app.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)

            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}
