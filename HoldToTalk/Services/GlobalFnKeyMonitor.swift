import AppKit
import Foundation

protocol GlobalFnKeyMonitorDelegate: AnyObject {
    func globalFnKeyMonitor(_ monitor: GlobalFnKeyMonitor, didChangeFnKeyDown isDown: Bool)
}

final class GlobalFnKeyMonitor {
    weak var delegate: GlobalFnKeyMonitorDelegate?

    var shortcut: HoldShortcut = .defaultShortcut {
        didSet {
            stopModifierStateReconciliation()
            isFnDown = false
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isFnDown = false
    private var modifierStateReconciliationTimer: DispatchSourceTimer?

    var isRunning: Bool {
        globalMonitor != nil && localMonitor != nil
    }

    deinit {
        stop()
    }

    func start() throws {
        guard PermissionHelper.isAccessibilityTrusted else {
            throw GlobalFnKeyMonitorError.missingAccessibilityPermission
        }

        guard !isRunning else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
            return event
        }

        guard isRunning else {
            stop()
            throw GlobalFnKeyMonitorError.couldNotCreateEventMonitor
        }
    }

    func rearm() throws {
        stopModifierStateReconciliation()
        isFnDown = false

        guard isRunning else {
            try start()
            return
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        globalMonitor = nil
        localMonitor = nil
        stopModifierStateReconciliation()
        isFnDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            if shortcut.keyCode == nil {
                updateFnDown(shortcut.matchesModifierState(event.modifierFlags))
            } else if isFnDown, !shortcut.matchesKeyEvent(event) {
                updateFnDown(false)
            }
        case .keyDown:
            guard !event.isARepeat else { return }
            if shortcut.matchesKeyEvent(event) {
                updateFnDown(true)
            }
        case .keyUp:
            if shortcut.keyCode == event.keyCode {
                updateFnDown(false)
            }
        default:
            return
        }
    }

    private func updateFnDown(_ nextFnDown: Bool) {
        guard nextFnDown != isFnDown else { return }

        isFnDown = nextFnDown
        if nextFnDown, shortcut.keyCode == nil {
            startModifierStateReconciliation()
        } else {
            stopModifierStateReconciliation()
        }
        delegate?.globalFnKeyMonitor(self, didChangeFnKeyDown: nextFnDown)
    }

    private func startModifierStateReconciliation() {
        guard modifierStateReconciliationTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(100),
            repeating: .milliseconds(100),
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self] in
            self?.reconcileModifierState()
        }
        modifierStateReconciliationTimer = timer
        timer.resume()
    }

    private func stopModifierStateReconciliation() {
        modifierStateReconciliationTimer?.cancel()
        modifierStateReconciliationTimer = nil
    }

    private func reconcileModifierState() {
        guard isFnDown, shortcut.keyCode == nil else {
            stopModifierStateReconciliation()
            return
        }

        let eventFlags = CGEventSource.flagsState(.combinedSessionState)
        var modifierFlags: NSEvent.ModifierFlags = []
        if eventFlags.contains(.maskCommand) { modifierFlags.insert(.command) }
        if eventFlags.contains(.maskAlternate) { modifierFlags.insert(.option) }
        if eventFlags.contains(.maskControl) { modifierFlags.insert(.control) }
        if eventFlags.contains(.maskShift) { modifierFlags.insert(.shift) }
        if eventFlags.contains(.maskSecondaryFn) { modifierFlags.insert(.function) }

        if !shortcut.matchesModifierState(modifierFlags) {
            updateFnDown(false)
        }
    }
}

enum GlobalFnKeyMonitorError: LocalizedError {
    case missingAccessibilityPermission
    case couldNotCreateEventMonitor

    var errorDescription: String? {
        switch self {
        case .missingAccessibilityPermission:
            return L10n.tr("Accessibility permission is required for global shortcut detection and text insertion.")
        case .couldNotCreateEventMonitor:
            return L10n.tr("Could not create the global shortcut monitor.")
        }
    }
}
