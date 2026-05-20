import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    var isRecording: Bool
    var onCapture: (HoldShortcut) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.isRecording = isRecording

        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class RecorderNSView: NSView {
        var isRecording = false
        var onCapture: ((HoldShortcut) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }

            if event.keyCode == 53 {
                onCancel?()
                return
            }

            onCapture?(HoldShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags))
        }

        override func flagsChanged(with event: NSEvent) {
            guard isRecording else {
                super.flagsChanged(with: event)
                return
            }

            let flags = HoldShortcut.normalized(event.modifierFlags)
            if flags == [.function] {
                onCapture?(.defaultShortcut)
            }
        }
    }
}
