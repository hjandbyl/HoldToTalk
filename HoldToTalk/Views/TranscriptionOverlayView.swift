import SwiftUI

struct TranscriptionOverlayView: View {
    @ObservedObject var recording: RecordingStore
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
    private var formingOrbGlassSurface: some View {
        ZStack {
            if nucleusDiameter > 0 {
                Circle()
                    .fill(.clear)
                    .frame(width: nucleusDiameter, height: nucleusDiameter)
                    .offset(x: nucleusOffset)
                    .glassEffect(in: Circle())
                    .glassEffectUnion(id: "forming-voice-surface", namespace: glassNamespace)
                    .glassEffectTransition(.materialize)
            }

            if bodyDiameter > 0 {
                Circle()
                    .fill(.clear)
                    .frame(width: bodyDiameter, height: bodyDiameter)
                    .offset(x: bodyOffset)
                    .glassEffect(in: Circle())
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
            .glassEffect(in: Capsule())
            .glassEffectID("voice-surface", in: glassNamespace)
            .glassEffectTransition(.matchedGeometry)
    }

    private var orbContentSurface: some View {
        RecordingWaveform(
            visualization: recording.inputVisualization,
            isRecording: recording.isRecording
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
                visualization: recording.inputVisualization,
                isRecording: recording.isRecording
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
                visualization: recording.inputVisualization,
                isRecording: recording.isRecording
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

    func reset() {
        isVisible = false
        isDismissing = false
        stage = .hidden
    }
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

        let spectrum = visualization.snapshot.spectrum
        guard !spectrum.isEmpty else {
            return Array(repeating: 0, count: displayBarCount)
        }

        let inputCount = min(spectrum.count, sourceBandCount * 2)
        var result = [Double](repeating: 0, count: displayBarCount)
        for index in 0..<displayBarCount {
            let sourceIndex = min(sourceBandCount - 1, abs(index - centerBarIndex))
            result[index] = sample(
                spectrum,
                count: inputCount,
                at: sourceIndex,
                outputCount: sourceBandCount
            )
        }
        return result
    }

    var body: some View {
        let samples = displaySamples
        let activity = CGFloat(min(1, max(0, visualization.snapshot.level)))

        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let availableBarWidth = (size.width - CGFloat(displayBarCount - 1) * barSpacing) / CGFloat(displayBarCount)
            let barWidth = max(1.1, min(2.4, availableBarWidth))
            let cornerRadius = barWidth / 2
            var bars = Path()

            for index in samples.indices {
                let height = barHeight(
                    for: samples[index],
                    activity: activity,
                    at: index,
                    in: size
                )
                let x = CGFloat(index) * (barWidth + barSpacing)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                bars.addRoundedRect(
                    in: rect,
                    cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
                )
            }

            context.addFilter(.shadow(
                color: .black.opacity(isRecording ? 0.14 : 0.04),
                radius: 2,
                x: 0,
                y: 1
            ))
            context.fill(
                bars,
                with: .linearGradient(
                    Gradient(colors: waveformColors(activity: activity)),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )
        }
    }

    private func sample(_ values: [Double], count: Int, at index: Int, outputCount: Int) -> Double {
        guard count > 0 else { return 0 }
        guard count > 1, outputCount > 1 else { return min(1, max(0, values[0])) }

        let position = Double(index) / Double(outputCount - 1) * Double(count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(count - 1, lowerIndex + 1)
        let fraction = position - Double(lowerIndex)
        let value = values[lowerIndex] * (1 - fraction) + values[upperIndex] * fraction
        return min(1, max(0, value))
    }

    private func barHeight(
        for sample: Double,
        activity: CGFloat,
        at index: Int,
        in size: CGSize
    ) -> CGFloat {
        let sourceIndex = min(sourceBandCount - 1, abs(index - centerBarIndex))
        let envelope = sourceIndex < barEnvelope.count ? barEnvelope[sourceIndex] : 0.72
        let shapedSample = pow(CGFloat(min(1, max(0, sample))), 0.38)
        let quietFloor = isRecording ? size.height * 0.14 : size.height * 0.07
        let activeHeight = shapedSample * size.height * 1.32 * envelope * (0.73 + activity * 0.44)
        return min(size.height, max(quietFloor, activeHeight))
    }

    private func waveformColors(activity: CGFloat) -> [Color] {
        let intensity = Double(activity)
        return [
            Color.recordingAccent.opacity(isRecording ? 0.86 + intensity * 0.12 : 0.28),
            Color.recordingAccentHighlight.opacity(isRecording ? 0.68 + intensity * 0.22 : 0.18)
        ]
    }
}
