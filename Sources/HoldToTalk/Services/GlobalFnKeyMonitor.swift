import ApplicationServices
import Foundation

protocol GlobalFnKeyMonitorDelegate: AnyObject {
    func globalFnKeyMonitor(_ monitor: GlobalFnKeyMonitor, didChangeFnKeyDown isDown: Bool)
}

final class GlobalFnKeyMonitor {
    weak var delegate: GlobalFnKeyMonitorDelegate?

    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorRunLoop: CFRunLoop?
    private var monitorThread: Thread?
    private var isFnDown = false

    var isRunning: Bool {
        stateLock.lock()
        let tap = eventTap
        stateLock.unlock()

        guard let tap else { return false }
        return CFMachPortIsValid(tap)
    }

    deinit {
        stop()
    }

    func start() throws {
        if let tap = currentEventTap(), CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }

        guard PermissionHelper.isAccessibilityTrusted else {
            throw GlobalFnKeyMonitorError.missingAccessibilityPermission
        }

        guard PermissionHelper.hasInputMonitoringPermission else {
            throw GlobalFnKeyMonitorError.missingInputMonitoringPermission
        }

        stop()

        let startResult = EventTapStartResult()
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                startResult.set(error: GlobalFnKeyMonitorError.couldNotCreateEventTap)
                started.signal()
                return
            }

            do {
                try self.installEventTapOnCurrentThread()
                started.signal()
                CFRunLoopRun()
                self.clearStoppedEventTap()
            } catch {
                startResult.set(error: error)
                started.signal()
            }
        }

        thread.name = "HoldToTalk Fn Key Monitor"

        stateLock.lock()
        monitorThread = thread
        stateLock.unlock()

        thread.start()

        guard started.wait(timeout: .now() + 2) == .success else {
            stop()
            throw GlobalFnKeyMonitorError.couldNotCreateEventTap
        }

        if let error = startResult.error {
            stop()
            throw error
        }
    }

    func rearm() throws {
        DispatchQueue.main.async { [weak self] in
            self?.isFnDown = false
        }

        if let tap = currentEventTap(), CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }

        try start()
    }

    func stop() {
        stateLock.lock()
        let source = runLoopSource
        let tap = eventTap
        let runLoop = monitorRunLoop

        runLoopSource = nil
        eventTap = nil
        monitorRunLoop = nil
        monitorThread = nil
        stateLock.unlock()

        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        if let runLoop {
            CFRunLoopStop(runLoop)
        }

        DispatchQueue.main.async { [weak self] in
            self?.isFnDown = false
        }
    }

    private func currentEventTap() -> CFMachPort? {
        stateLock.lock()
        let tap = eventTap
        stateLock.unlock()
        return tap
    }

    private func installEventTapOnCurrentThread() throws {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: fnKeyEventCallback,
            userInfo: userInfo
        ) else {
            throw GlobalFnKeyMonitorError.couldNotCreateEventTap
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw GlobalFnKeyMonitorError.couldNotCreateEventTap
        }

        let runLoop = CFRunLoopGetCurrent()

        stateLock.lock()
        eventTap = tap
        runLoopSource = source
        monitorRunLoop = runLoop
        stateLock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func clearStoppedEventTap() {
        stateLock.lock()
        eventTap = nil
        runLoopSource = nil
        monitorRunLoop = nil
        monitorThread = nil
        stateLock.unlock()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = currentEventTap(), CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard type == .flagsChanged else { return }

        let nextFnDown = event.flags.contains(.maskSecondaryFn)
        DispatchQueue.main.async { [weak self] in
            self?.updateFnDown(nextFnDown)
        }
    }

    private func updateFnDown(_ nextFnDown: Bool) {
        guard nextFnDown != isFnDown else { return }

        isFnDown = nextFnDown
        delegate?.globalFnKeyMonitor(self, didChangeFnKeyDown: nextFnDown)
    }
}

private final class EventTapStartResult {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        let error = storedError
        lock.unlock()
        return error
    }

    func set(error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private let fnKeyEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<GlobalFnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

enum GlobalFnKeyMonitorError: LocalizedError {
    case missingAccessibilityPermission
    case missingInputMonitoringPermission
    case couldNotCreateEventTap

    var errorDescription: String? {
        switch self {
        case .missingAccessibilityPermission:
            return "Accessibility permission is required for global key detection and text insertion."
        case .missingInputMonitoringPermission:
            return "Input Monitoring permission is required to detect the Fn key globally."
        case .couldNotCreateEventTap:
            return "Could not create the global Fn key monitor."
        }
    }
}
