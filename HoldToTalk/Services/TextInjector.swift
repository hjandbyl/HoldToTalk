import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TextInjector {
    private static let accessibilityWebAreaRole = "AXWebArea"
    private static let pasteboardRestoreDelay: TimeInterval = 0.8
    private static let keyboardEventPreferredBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.chatgpt",
        "com.openai.codex",
    ]

    private var pasteboardInjectionRevision = 0
    private var preservedPasteboard: PasteboardSnapshot?
    private var lastInjectedChangeCount: Int?

    static func normalizedInsertionText(from text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func insert(_ text: String, targetApplication: NSRunningApplication?) {
        let trimmedText = Self.normalizedInsertionText(from: text)
        guard !trimmedText.isEmpty else { return }

        if let targetApplication, !targetApplication.isTerminated {
            let requiresActivation = !targetApplication.isActive
            if #available(macOS 14.0, *) {
                targetApplication.activate(options: [.activateAllWindows])
            } else {
                targetApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }

            if requiresActivation {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.inject(trimmedText, targetApplication: targetApplication)
                }
                return
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.inject(trimmedText, targetApplication: targetApplication)
        }
    }

    private func inject(_ text: String, targetApplication: NSRunningApplication?) {
        let focusedElement = focusedAccessibilityElement()
        let requiresKeyboardInput = Self.prefersKeyboardEvents(for: targetApplication)
            || focusedElement.map(isInsideWebArea) == true

        if requiresKeyboardInput {
            guard !postUnicodeKeyboardInput(text) else { return }
            pasteUsingTemporaryPasteboard(text)
            return
        }

        if let focusedElement, insertUsingAccessibility(text, into: focusedElement) {
            return
        }

        guard !postUnicodeKeyboardInput(text) else { return }
        pasteUsingTemporaryPasteboard(text)
    }

    private static func prefersKeyboardEvents(for application: NSRunningApplication?) -> Bool {
        guard let bundleIdentifier = application?.bundleIdentifier?.lowercased() else { return false }
        return keyboardEventPreferredBundleIdentifiers.contains(bundleIdentifier)
    }

    private func focusedAccessibilityElement() -> AXUIElement? {
        guard PermissionHelper.isAccessibilityTrusted else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWideElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (focusedValue as! AXUIElement)
    }

    private func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var currentElement: AXUIElement? = element

        for _ in 0..<32 {
            guard let elementToInspect = currentElement else { return false }

            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                elementToInspect,
                kAXRoleAttribute as CFString,
                &roleValue
            ) == .success,
               let role = roleValue as? String,
               role == Self.accessibilityWebAreaRole {
                return true
            }

            var parentValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    elementToInspect,
                    kAXParentAttribute as CFString,
                    &parentValue
                ) == .success,
                let parentValue,
                CFGetTypeID(parentValue) == AXUIElementGetTypeID()
            else {
                return false
            }

            currentElement = (parentValue as! AXUIElement)
        }

        return false
    }

    private func insertUsingAccessibility(_ text: String, into focusedElement: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                &isSettable
            ) == .success,
            isSettable.boolValue
        else {
            return false
        }

        return AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private func postUnicodeKeyboardInput(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        guard let keyDown, let keyUp else { return false }

        let unicodeUnits = Array(text.utf16)
        unicodeUnits.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func pasteUsingTemporaryPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        if let lastInjectedChangeCount, pasteboard.changeCount != lastInjectedChangeCount {
            preservedPasteboard = PasteboardSnapshot(pasteboard: pasteboard)
        } else if preservedPasteboard == nil {
            preservedPasteboard = PasteboardSnapshot(pasteboard: pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let injectedChangeCount = pasteboard.changeCount
        lastInjectedChangeCount = injectedChangeCount
        pasteboardInjectionRevision += 1
        let revision = pasteboardInjectionRevision

        guard postPasteShortcut() else {
            restorePasteboardIfUnchanged(
                pasteboard,
                injectedChangeCount: injectedChangeCount,
                revision: revision
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteboardRestoreDelay) { [weak self] in
            self?.restorePasteboardIfUnchanged(
                pasteboard,
                injectedChangeCount: injectedChangeCount,
                revision: revision
            )
        }
    }

    private func restorePasteboardIfUnchanged(
        _ pasteboard: NSPasteboard,
        injectedChangeCount: Int,
        revision: Int
    ) {
        guard revision == pasteboardInjectionRevision else { return }
        defer {
            preservedPasteboard = nil
            lastInjectedChangeCount = nil
        }

        guard pasteboard.changeCount == injectedChangeCount else { return }
        preservedPasteboard?.restore(to: pasteboard)
    }

    private func postPasteShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let keyCodeForV: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)
        guard let keyDown, let keyUp else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        let pasteboardItems = items.compactMap { contents -> NSPasteboardItem? in
            guard !contents.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }

        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }
    }
}
