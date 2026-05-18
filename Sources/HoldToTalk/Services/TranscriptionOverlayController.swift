import AppKit
import SwiftUI

@MainActor
final class TranscriptionOverlayController {
    private let controller: HoldToTalkController
    private var panel: NSPanel?
    private var displayRevision = 0

    init(controller: HoldToTalkController) {
        self.controller = controller
    }

    func show() {
        displayRevision += 1
        let revision = displayRevision

        panel?.orderOut(nil)

        let panel = makePanel()
        self.panel = panel
        positionPanel(panel)

        panel.alphaValue = 0
        panel.contentView?.alphaValue = 1
        panel.contentView?.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        panel.contentView?.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.98, y: 0.98))
        panel.orderFrontRegardless()

        DispatchQueue.main.async { [weak self, weak panel] in
            guard
                let self,
                let panel,
                self.displayRevision == revision,
                self.panel === panel
            else {
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.contentView?.animator().layer?.setAffineTransform(.identity)
            }
        }
    }

    func hide() {
        guard let panel else { return }

        displayRevision += 1
        let revision = displayRevision

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard
                    let self,
                    let panel,
                    self.displayRevision == revision,
                    self.panel === panel
                else {
                    return
                }

                panel.orderOut(nil)
                self.panel = nil
            }
        })
    }

    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(rootView: TranscriptionOverlayView(controller: controller))
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 70)

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

    private func positionPanel(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 84
        )
        panel.setFrameOrigin(origin)
    }
}
