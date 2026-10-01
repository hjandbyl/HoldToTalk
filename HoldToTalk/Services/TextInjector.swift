import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TextInjector: TextInserting {
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

    func insert(_ text: String, target: InsertionTarget?) async throws -> InsertionOutcome {
        try Task.checkCancellation()
        guard let target, let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated, application.bundleIdentifier == target.bundleIdentifier else {
            throw DictationError.targetUnavailable
        }
        guard PermissionHelper.isAccessibilityTrusted else { throw DictationError.insertionFailed }
        let trimmedText = Self.normalizedInsertionText(from: text)
        guard !trimmedText.isEmpty else { throw DictationError.insertionFailed }
        if !application.isActive {
            application.activate(options: [.activateAllWindows])
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        guard !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            throw DictationError.targetUnavailable
        }
        let outcome = try inject(trimmedText, targetApplication: application)
        // A paste must consume its temporary clipboard before the next queued insertion.
        if outcome == .pasteShortcut {
            defer { restorePendingPasteboard() }
            try await Task.sleep(for: .seconds(Self.pasteboardRestoreDelay))
        }
        return outcome
    }

    private func inject(_ text: String, targetApplication: NSRunningApplication) throws -> InsertionOutcome {
        let focusedElement = focusedAccessibilityElement(in: targetApplication)
        let requiresKeyboardInput = Self.prefersKeyboardEvents(for: targetApplication)
            || focusedElement.map(isInsideWebArea) == true
        if !requiresKeyboardInput, let focusedElement, insertUsingAccessibility(text, into: focusedElement) {
            return .accessibilityWrite
        }
        guard !targetApplication.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApplication.processIdentifier else {
            throw DictationError.targetUnavailable
        }
        if postUnicodeKeyboardInput(text, targetPID: targetApplication.processIdentifier) { return .keyboardEvents }
        guard pasteUsingTemporaryPasteboard(text, targetPID: targetApplication.processIdentifier) else { throw DictationError.insertionFailed }
        return .pasteShortcut
    }

    private static func prefersKeyboardEvents(for application: NSRunningApplication?) -> Bool {
        guard let bundleIdentifier = application?.bundleIdentifier?.lowercased() else { return false }
        return keyboardEventPreferredBundleIdentifiers.contains(bundleIdentifier)
    }

    private func focusedAccessibilityElement(in application: NSRunningApplication) -> AXUIElement? {
        guard PermissionHelper.isAccessibilityTrusted else { return nil }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                applicationElement,
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

    private func postUnicodeKeyboardInput(_ text: String, targetPID: pid_t) -> Bool {
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
        keyDown.postToPid(targetPID)
        keyUp.postToPid(targetPID)
        return true
    }

    private func pasteUsingTemporaryPasteboard(_ text: String, targetPID: pid_t) -> Bool {
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

        guard postPasteShortcut(targetPID: targetPID) else {
            restorePasteboardIfUnchanged(
                pasteboard,
                injectedChangeCount: injectedChangeCount,
                revision: revision
            )
            return false
        }

        return true
    }

    private func restorePendingPasteboard() {
        guard let lastInjectedChangeCount else { return }
        restorePasteboardIfUnchanged(.general, injectedChangeCount: lastInjectedChangeCount,
                                     revision: pasteboardInjectionRevision)
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

        _ = preservedPasteboard?.restoreIfUnchanged(to: pasteboard, expectedChangeCount: injectedChangeCount)
    }

    private func postPasteShortcut(targetPID: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let keyCodeForV: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)
        guard let keyDown, let keyUp else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.postToPid(targetPID)
        keyUp.postToPid(targetPID)
        return true
    }
}

struct PasteboardSnapshot {
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

    @discardableResult
    func restoreIfUnchanged(to pasteboard: NSPasteboard, expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        restore(to: pasteboard)
        return true
    }

    private func restore(to pasteboard: NSPasteboard) {
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
