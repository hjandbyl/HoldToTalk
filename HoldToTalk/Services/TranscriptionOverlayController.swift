import AppKit
import SwiftUI

@MainActor
final class TranscriptionOverlayController {
    private let recording: RecordingStore
    private var panel: NSPanel?
    private var presentation: TranscriptionOverlayPresentation?
    private var displayRevision = 0

    // Leave room for the 60-point glass surface's glow outside its bounds.
    private let panelSize = NSSize(width: 600, height: 100)
    private let materializeAnimation = Animation.easeOut(duration: 0.10)
    private let settleAnimation = Animation.spring(duration: 0.18, bounce: 0.10)
    private let dismissalAnimation = Animation.easeIn(duration: 0.14)
    private let orbSettleDelay: Duration = .milliseconds(30)
    private let dismissalDuration: Duration = .milliseconds(140)

    init(recording: RecordingStore) {
        self.recording = recording
    }

    func show() {
        displayRevision += 1
        let revision = displayRevision

        let presentation: TranscriptionOverlayPresentation
        let panel: NSPanel
        if let existingPanel = self.panel, let existingPresentation = self.presentation {
            panel = existingPanel
            presentation = existingPresentation
            panel.orderOut(nil)
        } else {
            presentation = TranscriptionOverlayPresentation()
            panel = makePanel(presentation: presentation)
            self.panel = panel
            self.presentation = presentation
        }

        var resetTransaction = Transaction(animation: nil)
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            presentation.reset()
        }
        positionPanel(panel)

        panel.orderFrontRegardless()

        DispatchQueue.main.async { [weak self, weak panel, weak presentation] in
            guard
                let self,
                let panel,
                let presentation,
                self.displayRevision == revision,
                self.panel === panel,
                self.presentation === presentation
            else {
                return
            }

            withAnimation(self.materializeAnimation) {
                presentation.isVisible = true
                presentation.stage = .droplet
            }

            self.promoteDropletToOrb(
                presentation: presentation,
                panel: panel,
                revision: revision
            )
        }
    }

    func hide() {
        guard let panel, let presentation else { return }

        displayRevision += 1
        let revision = displayRevision

        withAnimation(dismissalAnimation) {
            presentation.isDismissing = true
            presentation.isVisible = false
        }

        let dismissalDuration = dismissalDuration
        Task { [weak self, weak panel, weak presentation] in
            try? await Task.sleep(for: dismissalDuration)

            await MainActor.run {
                guard
                    let self,
                    let panel,
                    let presentation,
                    self.displayRevision == revision,
                    self.panel === panel,
                    self.presentation === presentation
                else {
                    return
                }

                panel.orderOut(nil)
                presentation.reset()
            }
        }
    }

    private func makePanel(presentation: TranscriptionOverlayPresentation) -> NSPanel {
        let hostingView = NSHostingView(
            rootView: TranscriptionOverlayView(
                recording: recording,
                liveTranscription: recording.liveTranscription,
                presentation: presentation
            )
            .frame(width: panelSize.width, height: panelSize.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        return panel
    }

    private func promoteDropletToOrb(
        presentation: TranscriptionOverlayPresentation,
        panel: NSPanel,
        revision: Int
    ) {
        let orbSettleDelay = orbSettleDelay

        Task { [weak self, weak panel, weak presentation] in
            try? await Task.sleep(for: orbSettleDelay)

            await MainActor.run {
                guard
                    let self,
                    let panel,
                    let presentation,
                    self.displayRevision == revision,
                    self.panel === panel,
                    self.presentation === presentation,
                    presentation.isVisible
                else {
                    return
                }

                withAnimation(self.settleAnimation) {
                    presentation.stage = .orb
                }
            }
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            // Keep the surface centered at its original height above the visible bottom.
            y: visibleFrame.minY + 117 - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}
