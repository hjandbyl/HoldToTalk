import AppKit
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
            RecordingWaveform()
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
    @State private var isAnimating = false

    private let bars: [(collapsed: CGFloat, expanded: CGFloat, delay: Double)] = [
        (10, 18, 0.00),
        (14, 26, 0.12),
        (8, 21, 0.24),
        (12, 24, 0.08)
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                Capsule(style: .continuous)
                    .fill(Color.red)
                    .frame(width: 4, height: isAnimating ? bar.expanded : bar.collapsed)
                    .animation(
                        .easeInOut(duration: 0.58)
                            .repeatForever(autoreverses: true)
                            .delay(bar.delay),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}
