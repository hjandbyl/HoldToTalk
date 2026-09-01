import SwiftUI

struct TranscriptionOverlayView: View {
    @ObservedObject var controller: HoldToTalkController
    @ObservedObject var liveTranscription: LiveTranscriptionState
    @ObservedObject var presentation: TranscriptionOverlayPresentation
    @Namespace private var glassNamespace

    private let surfaceHeight: CGFloat = 60
    private let maxSurfaceWidth: CGFloat = 560
    private let compactWaveformWidth: CGFloat = 46
    private let waveformWidth: CGFloat = 56

    private var transcriptText: String {
        liveTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTranscript: Bool {
        !transcriptText.isEmpty
    }

    private var surfaceWidth: CGFloat {
        guard hasTranscript else { return surfaceHeight }

        let font = NSFont.systemFont(ofSize: 17, weight: .medium)
        let textWidth = (transcriptText as NSString).size(withAttributes: [.font: font]).width
        return min(maxSurfaceWidth, max(158, textWidth + 112))
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
        .regular.tint(Color.recordingAccent.opacity(0.12))
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
        RecordingWaveform(
            visualization: controller.inputVisualization,
            isRecording: controller.isRecording
        )
            .frame(width: compactWaveformWidth, height: 32)
            .opacity(showsWaveformInOrb ? 1 : 0)
            .scaleEffect(showsWaveformInOrb ? 1 : 0.72)
            .frame(width: surfaceHeight, height: surfaceHeight)
    }

    private var fallbackFormingOrbSurface: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .frame(width: max(nucleusDiameter, bodyDiameter), height: max(nucleusDiameter, bodyDiameter))

            RecordingWaveform(
                visualization: controller.inputVisualization,
                isRecording: controller.isRecording
            )
                .frame(width: compactWaveformWidth, height: 32)
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
            RecordingWaveform(
                visualization: controller.inputVisualization,
                isRecording: controller.isRecording
            )
                .frame(width: waveformWidth, height: 32)

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
    @ObservedObject var visualization: AudioInputVisualization
    let isRecording: Bool

    private let sourceBandCount = 9
    private let displayBarCount = 17
    private let centerBarIndex = 8
    private let barSpacing: CGFloat = 1.2
    private let barEnvelope: [CGFloat] = [0.42, 0.62, 1.0, 0.78, 0.92, 0.62, 1.0, 0.78, 0.42]

    private var displaySamples: [Double] {
        guard isRecording else {
            return Array(repeating: 0, count: displayBarCount)
        }

        let shaped = visualization.snapshot.spectrum.map { min(1, max(0, $0)) }
        guard !shaped.isEmpty else {
            return Array(repeating: 0, count: displayBarCount)
        }

        let upperBound = min(shaped.count, sourceBandCount * 2)
        let focusedSpectrum = Array(shaped.prefix(upperBound))
        let sourceBands = (0..<sourceBandCount).map { index in
            sample(focusedSpectrum, at: index, outputCount: sourceBandCount)
        }

        return (0..<displayBarCount).map { index in
            let sourceIndex = min(sourceBandCount - 1, abs(index - centerBarIndex))
            return sourceBands[sourceIndex]
        }
    }

    var body: some View {
        let samples = displaySamples

        GeometryReader { proxy in
            let size = proxy.size
            let availableBarWidth = (size.width - CGFloat(displayBarCount - 1) * barSpacing) / CGFloat(displayBarCount)
            let barWidth = max(1.1, min(2.4, availableBarWidth))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(samples.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(barFill(for: samples[index]))
                        .frame(
                            width: barWidth,
                            height: barHeight(for: samples[index], at: index, in: size)
                        )
                        .shadow(color: .black.opacity(isRecording ? 0.16 : 0.04), radius: 2.5, x: 0, y: 1.5)
                        .shadow(color: Color.recordingAccent.opacity(isRecording ? 0.18 : 0), radius: 5, x: 0, y: 0)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .center)
        }
        .animation(.easeOut(duration: 0.08), value: samples)
        .animation(.easeOut(duration: 0.08), value: visualization.snapshot.level)
    }

    private func sample(_ values: [Double], at index: Int, outputCount: Int) -> Double {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1, outputCount > 1 else { return values[0] }

        let position = Double(index) / Double(outputCount - 1) * Double(values.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(values.count - 1, lowerIndex + 1)
        let fraction = position - Double(lowerIndex)
        return values[lowerIndex] * (1 - fraction) + values[upperIndex] * fraction
    }

    private func barHeight(for sample: Double, at index: Int, in size: CGSize) -> CGFloat {
        let activity = CGFloat(min(1, max(0, visualization.snapshot.level)))
        let sourceIndex = min(sourceBandCount - 1, abs(index - centerBarIndex))
        let envelope = sourceIndex < barEnvelope.count ? barEnvelope[sourceIndex] : 0.72
        let shapedSample = pow(CGFloat(min(1, max(0, sample))), 0.38)
        let quietFloor = isRecording ? size.height * 0.14 : size.height * 0.07
        let activeHeight = shapedSample * size.height * 1.32 * envelope * (0.73 + activity * 0.44)
        return min(size.height, max(quietFloor, activeHeight))
    }

    private func barFill(for sample: Double) -> LinearGradient {
        let intensity = min(1, max(0, sample))
        return LinearGradient(
            colors: [
                Color.recordingAccent.opacity(isRecording ? 0.86 + intensity * 0.12 : 0.28),
                Color.recordingAccentHighlight.opacity(isRecording ? 0.68 + intensity * 0.22 : 0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
