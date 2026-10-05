import Foundation
import AppKit

extension Notification.Name {
    static let appInteractionStateDidChange = Notification.Name("AppInteractionStateDidChange")
}

final class AppInteractionMonitor {
    enum State: Sendable, Equatable {
        case background
        case foregroundIdle
        case foregroundInteracting
    }

    static let shared = AppInteractionMonitor()

    private let stateLock = NSLock()
    private let interactionIdleWindow: TimeInterval = 1.5

    private var localEventMonitor: Any?
    private var becameActiveObserver: NSObjectProtocol?
    private var resignedActiveObserver: NSObjectProtocol?
    private var idleWorkItem: DispatchWorkItem?

    private var isStarted = false
    private var isAppActive = false
    private var lastInteractionAt = Date.distantPast
    private var currentState: State = .background

    private init() { }

    @MainActor
    func start() {
        guard !isStarted else { return }
        isStarted = true
        isAppActive = NSApp.isActive
        currentState = computeState(now: Date())

        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppInteractionMonitor.shared.handleApplicationActiveChange(isActive: true)
            }
        }

        resignedActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppInteractionMonitor.shared.handleApplicationActiveChange(isActive: false)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { event in
            Task { @MainActor in
                AppInteractionMonitor.shared.recordInteraction()
            }
            return event
        }
    }

    @MainActor
    func stop() {
        guard isStarted else { return }
        isStarted = false

        idleWorkItem?.cancel()
        idleWorkItem = nil

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
            self.becameActiveObserver = nil
        }

        if let resignedActiveObserver {
            NotificationCenter.default.removeObserver(resignedActiveObserver)
            self.resignedActiveObserver = nil
        }
    }

    func snapshot() -> State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    func shouldSuspendBackgroundProcessing() -> Bool {
        snapshot() == .foregroundInteracting
    }

    @MainActor
    private func handleApplicationActiveChange(isActive: Bool) {
        stateLock.lock()
        self.isAppActive = isActive
        if !isActive {
            idleWorkItem?.cancel()
            idleWorkItem = nil
        }
        let newState = computeState(now: Date())
        let oldState = currentState
        currentState = newState
        stateLock.unlock()

        if newState != oldState {
            notifyStateChanged(newState)
        }
    }

    @MainActor
    private func recordInteraction() {
        stateLock.lock()
        lastInteractionAt = Date()
        let newState = computeState(now: lastInteractionAt)
        let oldState = currentState
        currentState = newState
        scheduleIdleTransitionLocked()
        stateLock.unlock()

        if newState != oldState {
            notifyStateChanged(newState)
        }
    }

    private func computeState(now: Date) -> State {
        if !isAppActive {
            return .background
        }

        if now.timeIntervalSince(lastInteractionAt) < interactionIdleWindow {
            return .foregroundInteracting
        }

        return .foregroundIdle
    }

    @MainActor
    private func scheduleIdleTransitionLocked() {
        idleWorkItem?.cancel()
        guard isAppActive else { return }

        let workItem = DispatchWorkItem {
            Task { @MainActor in
                AppInteractionMonitor.shared.transitionToIdleIfNeeded()
            }
        }
        idleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interactionIdleWindow, execute: workItem)
    }

    @MainActor
    private func transitionToIdleIfNeeded() {
        stateLock.lock()
        let newState = computeState(now: Date())
        let oldState = currentState
        currentState = newState
        if newState != .foregroundInteracting {
            idleWorkItem = nil
        }
        stateLock.unlock()

        if newState != oldState {
            notifyStateChanged(newState)
        }
    }

    @MainActor
    private func notifyStateChanged(_ newState: State) {
        NotificationCenter.default.post(name: .appInteractionStateDidChange, object: newState)
    }
}
