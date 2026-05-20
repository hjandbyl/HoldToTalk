import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: HoldToTalkController

    @AppStorage(AppLanguage.storageKey) var appLanguageID = AppLanguage.system.rawValue
    @AppStorage(AppDisplayModePreference.storageKey) var appDisplayModeID = AppDisplayModePreference.savedMode().rawValue
    @State var selectedSection: MainSection? = .overview
    @State var apiKeyAutosaveTask: Task<Void, Never>?

    let labelWidth: CGFloat = 136
    let volcengineAPIKeyURL = URL(string: "https://console.volcengine.com/speech/new/overview?projectName=default")!

    var appLanguage: AppLanguage {
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

}
