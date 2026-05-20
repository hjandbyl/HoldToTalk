import SwiftUI

struct TranscriptionOverlayView: View {
    @ObservedObject var controller: HoldToTalkController
    @ObservedObject var presentation: TranscriptionOverlayPresentation
    @Namespace private var glassNamespace

    private let surfaceHeight: CGFloat = 60
    private let maxSurfaceWidth: CGFloat = 560

    private var transcriptText: String {
        controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTranscript: Bool {
        !transcriptText.isEmpty
    }

    private var surfaceWidth: CGFloat {
        guard hasTranscript else { return surfaceHeight }

        let font = NSFont.systemFont(ofSize: 17, weight: .medium)
        let textWidth = (transcriptText as NSString).size(withAttributes: [.font: font]).width
        return min(maxSurfaceWidth, max(132, textWidth + 82))
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            liquidGlassSurface
            .frame(width: maxSurfaceWidth, height: surfaceHeight)
        } else {
            fallbackSurface
            .frame(width: maxSurfaceWidth, height: surfaceHeight)
        }
    }

    @available(macOS 26.0, *)
    private var liquidGlassSurface: some View {
        ZStack {
            GlassEffectContainer(spacing: 18) {
                switch currentStage {
                case .hidden:
                    EmptyView()
                case .droplet, .orb:
                    formingOrbGlassSurface
                case .capsule:
                    capsuleGlassSurface
                }
            }

            switch currentStage {
            case .hidden, .droplet:
                EmptyView()
            case .orb:
                orbContentSurface
            case .capsule:
                EmptyView()
            }
        }
    }

    private var fallbackSurface: some View {
        ZStack {
            switch currentStage {
            case .hidden:
                EmptyView()
            case .droplet, .orb:
                fallbackFormingOrbSurface
                    .background(.regularMaterial, in: Circle())
                    .transition(.scale(scale: 0.35).combined(with: .opacity))
            case .capsule:
                capsuleContentSurface
                    .background(.regularMaterial, in: Capsule())
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
    }

    private var currentStage: TranscriptionOverlayPresentation.Stage {
        guard presentation.isVisible else { return .hidden }
        if presentation.isDismissing { return presentation.stage }
        if hasTranscript { return .capsule }
        return presentation.stage
    }

    private var nucleusDiameter: CGFloat {
        switch presentation.stage {
        case .hidden:
            return 0
        case .droplet:
            return 18
        case .orb, .capsule:
            return 0
        }
    }

    private var bodyDiameter: CGFloat {
        switch presentation.stage {
        case .hidden:
            return 0
        case .droplet:
            return 44
        case .orb, .capsule:
            return surfaceHeight
        }
    }

    private var nucleusOffset: CGFloat {
        switch presentation.stage {
        case .hidden:
            return 0
        case .droplet:
            return -12
        case .orb, .capsule:
            return 0
        }
    }

    private var bodyOffset: CGFloat {
        switch presentation.stage {
        case .hidden:
            return 0
        case .droplet:
            return 7
        case .orb, .capsule:
            return 0
        }
    }

    private var showsWaveformInOrb: Bool {
        presentation.stage == .orb || currentStage == .capsule
    }

    @available(macOS 26.0, *)
    private var voiceGlass: Glass {
        .regular.tint(Color.red.opacity(0.12))
    }

    @available(macOS 26.0, *)
    private var formingOrbGlassSurface: some View {
        ZStack {
            if nucleusDiameter > 0 {
                Circle()
                    .fill(.clear)
                    .frame(width: nucleusDiameter, height: nucleusDiameter)
                    .offset(x: nucleusOffset)
                    .glassEffect(voiceGlass, in: Circle())
                    .glassEffectUnion(id: "forming-voice-surface", namespace: glassNamespace)
                    .glassEffectTransition(.materialize)
            }

            if bodyDiameter > 0 {
                Circle()
                    .fill(.clear)
                    .frame(width: bodyDiameter, height: bodyDiameter)
                    .offset(x: bodyOffset)
                    .glassEffect(voiceGlass, in: Circle())
                    .glassEffectUnion(id: "forming-voice-surface", namespace: glassNamespace)
                    .glassEffectID("voice-surface", in: glassNamespace)
                    .glassEffectTransition(.materialize)
            }
        }
        .frame(width: surfaceHeight, height: surfaceHeight)
    }

    @available(macOS 26.0, *)
    private var capsuleGlassSurface: some View {
        surfaceBody
            .glassEffect(voiceGlass, in: Capsule())
            .glassEffectID("voice-surface", in: glassNamespace)
            .glassEffectTransition(.matchedGeometry)
    }

    private var orbContentSurface: some View {
        RecordingWaveform(level: controller.inputLevel, isRecording: controller.isRecording)
            .frame(width: 32, height: 22)
            .opacity(showsWaveformInOrb ? 1 : 0)
            .scaleEffect(showsWaveformInOrb ? 1 : 0.72)
            .frame(width: surfaceHeight, height: surfaceHeight)
    }

    private var fallbackFormingOrbSurface: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .frame(width: max(nucleusDiameter, bodyDiameter), height: max(nucleusDiameter, bodyDiameter))

            RecordingWaveform(level: controller.inputLevel, isRecording: controller.isRecording)
                .frame(width: 32, height: 22)
                .opacity(showsWaveformInOrb ? 1 : 0)
                .scaleEffect(showsWaveformInOrb ? 1 : 0.72)
        }
        .frame(width: surfaceHeight, height: surfaceHeight)
    }

    private var capsuleContentSurface: some View {
        surfaceBody
    }

    private var surfaceBody: some View {
        HStack(spacing: 14) {
            RecordingWaveform(level: controller.inputLevel, isRecording: controller.isRecording)
                .frame(width: 32, height: 22)

            Text(transcriptText)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .animation(nil, value: transcriptText)
        }
        .padding(.horizontal, 16)
        .frame(width: surfaceWidth, height: surfaceHeight)
        .animation(.spring(duration: 0.28, bounce: 0.10), value: surfaceWidth)
    }
}

@MainActor
final class TranscriptionOverlayPresentation: ObservableObject {
    enum Stage {
        case hidden
        case droplet
        case orb
        case capsule
    }

    @Published var isVisible = false
    @Published var isDismissing = false
    @Published var stage: Stage = .hidden
}

private struct RecordingWaveform: View {
    let level: Double
    let isRecording: Bool
    @State private var samples = Array(repeating: 0.0, count: 5)
    @State private var isBreathing = false

    private let barScales: [CGFloat] = [0.62, 0.86, 1.0, 0.78, 0.56]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                let displayLevel = CGFloat(max(sample, breathingFloor(for: index)))
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.30 + Double(displayLevel) * 0.52))
                    .frame(width: 4, height: 4 + displayLevel * 18 * barScales[index])
            }
        }
        .animation(.easeOut(duration: 0.09), value: samples)
        .onAppear {
            samples = Array(repeating: isRecording ? min(1, max(0, level)) : 0, count: barScales.count)
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
        .onChange(of: level) { _, newValue in
            let clamped = isRecording ? min(1, max(0, newValue)) : 0
            samples.removeFirst()
            samples.append(clamped)
        }
        .onChange(of: isRecording) { _, newValue in
            if !newValue {
                samples = Array(repeating: 0, count: barScales.count)
            }
        }
    }

    private func breathingFloor(for index: Int) -> Double {
        guard isRecording else { return 0 }

        let pulse = isBreathing ? 1.0 : 0.0
        let baseline = 0.08 + Double(barScales[index]) * 0.03
        return baseline + pulse * 0.02
    }
}
