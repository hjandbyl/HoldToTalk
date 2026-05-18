import SwiftUI

struct TranscriptionOverlayView: View {
    @ObservedObject var controller: HoldToTalkController

    private let surfaceHeight: CGFloat = 64
    private let maxSurfaceWidth: CGFloat = 560

    private var transcriptText: String {
        controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTranscript: Bool {
        !transcriptText.isEmpty
    }

    private var surfaceWidth: CGFloat {
        guard hasTranscript else { return surfaceHeight }

        let font = NSFont.systemFont(ofSize: 21, weight: .medium)
        let textWidth = (transcriptText as NSString).size(withAttributes: [.font: font]).width
        return min(maxSurfaceWidth, max(144, textWidth + 94))
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            surfaceBody
                .glassEffect()
                .frame(width: maxSurfaceWidth, height: surfaceHeight)
        } else {
            surfaceBody
                .background(.regularMaterial, in: Capsule())
                .frame(width: maxSurfaceWidth, height: surfaceHeight)
        }
    }

    private var surfaceBody: some View {
        HStack(spacing: hasTranscript ? 14 : 0) {
            RecordingWaveform(level: controller.inputLevel, isRecording: controller.isRecording)
                .frame(width: 26, height: 24)

            if hasTranscript {
                Text(transcriptText)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .animation(nil, value: transcriptText)
            }
        }
        .padding(.horizontal, hasTranscript ? 20 : 0)
        .frame(width: surfaceWidth, height: surfaceHeight)
        .animation(.spring(duration: 0.36, bounce: 0.14), value: hasTranscript)
        .animation(.spring(duration: 0.28, bounce: 0.10), value: surfaceWidth)
    }
}

private struct RecordingWaveform: View {
    let level: Double
    let isRecording: Bool
    @State private var samples = Array(repeating: 0.0, count: 5)

    private let barScales: [CGFloat] = [0.62, 0.86, 1.0, 0.78, 0.56]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                let displayLevel = CGFloat(sample)
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.45 + Double(displayLevel) * 0.55))
                    .frame(width: 4, height: 6 + displayLevel * 22 * barScales[index])
            }
        }
        .onAppear {
            samples = Array(repeating: isRecording ? min(1, max(0, level)) : 0, count: barScales.count)
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
        .animation(.easeOut(duration: 0.09), value: samples)
    }
}
