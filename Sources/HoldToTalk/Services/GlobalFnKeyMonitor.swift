import AppKit
import Foundation

protocol GlobalFnKeyMonitorDelegate: AnyObject {
    func globalFnKeyMonitor(_ monitor: GlobalFnKeyMonitor, didChangeFnKeyDown isDown: Bool)
}

final class GlobalFnKeyMonitor {
    weak var delegate: GlobalFnKeyMonitorDelegate?

    var shortcut: HoldShortcut = .defaultShortcut {
        didSet {
            isFnDown = false
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isFnDown = false

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
        delegate?.globalFnKeyMonitor(self, didChangeFnKeyDown: nextFnDown)
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
