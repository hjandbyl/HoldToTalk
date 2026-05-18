import AppKit
import Foundation

final class TextInjector {
    func insert(_ text: String, targetApplication: NSRunningApplication?) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if let targetApplication, !targetApplication.isTerminated {
            if #available(macOS 14.0, *) {
                targetApplication.activate(options: [.activateAllWindows])
            } else {
                targetApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay(for: targetApplication)) { [weak self] in
            self?.paste(trimmedText)
        }
    }

    private func paste(_ trimmedText: String) {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(trimmedText, forType: .string)
        let injectedChangeCount = pasteboard.changeCount

        postPasteShortcut()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pasteboard.changeCount == injectedChangeCount else { return }

            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
            }
        }
    }

    private func pasteDelay(for targetApplication: NSRunningApplication?) -> TimeInterval {
        targetApplication == nil ? 0 : 0.2
    }

    private func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let keyCodeForV: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
