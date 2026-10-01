import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case overview
    case recognition
    case shortcut
    case permissions
    case transcript
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.tr("Overview")
        case .recognition: return L10n.tr("Recognition")
        case .shortcut: return L10n.tr("Shortcut")
        case .permissions: return L10n.tr("Permissions")
        case .transcript: return L10n.tr("Transcript")
        case .diagnostics: return L10n.tr("Diagnostics")
        case .settings: return L10n.tr("Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .recognition: return "waveform"
        case .shortcut: return "keyboard"
        case .permissions: return "lock.shield"
        case .transcript: return "text.alignleft"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .labelStyle(.titleAndIcon)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.35), radius: 4)
    }
}

struct ProminentGlassButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(title, systemImage: systemImage, action: action)
            .buttonStyle(.glassProminent)
            .tint(tint)
            .accessibilityLabel(title)
        } else {
            Button(title, systemImage: systemImage, action: action)
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .accessibilityLabel(title)
        }
    }
}

extension View {
    func contentSurface() -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func insetContentSurface(selected: Bool = false) -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
    }
}
