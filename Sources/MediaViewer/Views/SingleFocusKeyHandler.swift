import SwiftUI
import AppKit

enum SingleFocusKeyRouting {
    /// `X` is intentionally unmodified so Command-X remains the system Cut command and
    /// Option/Control/Shift combinations remain available to text input and other tools.
    static func shouldTogglePreferredDisplay(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> Bool {
        guard !isRepeat,
              charactersIgnoringModifiers?.lowercased() == "x" else {
            return false
        }
        return modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
}

// MARK: - SingleFocusKeyHandler

/// NSViewRepresentable for keyboard handling in SingleFocusView (macOS 13+).
///
/// ## Issue #12: Why This File Exists (Not Redundant)
/// KeyboardShortcutManager handles key DOWN events, but this handler does TWO things
/// that KeyboardShortcutManager cannot:
///
/// 1. **Modifier Key Tracking** (`flagsChanged`) - Detects when Option/Command is HELD
///    (not just pressed) for the tag overlay feature. NSEvent.addLocalMonitorForEvents
///    can't track modifier-only state changes the same way.
///
/// 2. **First Responder Focus** - By being an NSView that accepts first responder,
///    it ensures the focus view can receive keyboard events even when no text field
///    is focused. This is important for single-key shortcuts (S, T, N, P, etc.).
///
/// The actual shortcut handling (onClose, onLeft, onRight, onStar) is now DELEGATED
/// to the KeyboardShortcutManager. This class primarily exists for modifier tracking.
///
/// To consolidate: You'd need to add flagsChanged monitoring to KeyboardShortcutManager,
/// but SwiftUI's declarative model makes that tricky. Keeping this is simpler.
struct SingleFocusKeyHandler: NSViewRepresentable {
    let onClose: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onStar: () -> Void
    var onTogglePreferredDisplay: (() -> Void)?
    var onModifierChanged: ((Bool) -> Void)?
    var onShowShortcuts: (() -> Void)?
    var modifierKey: TagSettings.ModifierKey = .option
    var modifierHoldDelay: TimeInterval = TagOverlayModifierHoldGate.defaultHoldDelay

    func makeNSView(context: Context) -> SingleFocusKeyView {
        let view = SingleFocusKeyView()
        view.onClose = onClose
        view.onLeft = onLeft
        view.onRight = onRight
        view.onStar = onStar
        view.onTogglePreferredDisplay = onTogglePreferredDisplay
        view.onModifierChanged = onModifierChanged
        view.onShowShortcuts = onShowShortcuts
        view.modifierFlag = modifierKey.eventFlag
        view.modifierHoldDelay = modifierHoldDelay
        // Make this the first responder to capture key events
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: SingleFocusKeyView, context: Context) {
        nsView.onClose = onClose
        nsView.onLeft = onLeft
        nsView.onRight = onRight
        nsView.onStar = onStar
        nsView.onTogglePreferredDisplay = onTogglePreferredDisplay
        nsView.onModifierChanged = onModifierChanged
        nsView.onShowShortcuts = onShowShortcuts
        nsView.modifierFlag = modifierKey.eventFlag
        nsView.modifierHoldDelay = modifierHoldDelay
    }
}

// MARK: - SingleFocusKeyView

class SingleFocusKeyView: NSView {
    var onClose: (() -> Void)?
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onStar: (() -> Void)?
    var onTogglePreferredDisplay: (() -> Void)?
    var onModifierChanged: ((Bool) -> Void)? {
        didSet { modifierHoldGate.onStateChanged = onModifierChanged }
    }
    var onShowShortcuts: (() -> Void)?
    var modifierFlag: NSEvent.ModifierFlags = .option {
        didSet { modifierHoldGate.modifierFlag = modifierFlag }
    }
    var modifierHoldDelay: TimeInterval = TagOverlayModifierHoldGate.defaultHoldDelay {
        didSet { modifierHoldGate.holdDelay = modifierHoldDelay }
    }

    private var responderTimer: Timer?
    private var mouseMonitor: Any?
    private let modifierHoldGate = TagOverlayModifierHoldGate()

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stopMonitoring()
            modifierHoldGate.close(sendRelease: true)
            return
        }
        // Poll first responder — NSWindow has no notification for internal responder changes
        responderTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.reclaimFocusIfNeeded()
        }
        // Also reclaim after mouse clicks outside text fields
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.reclaimFocusIfNeeded()
            }
            return event
        }
    }

    private func stopMonitoring() {
        responderTimer?.invalidate()
        responderTimer = nil
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }

    /// Reclaim first responder if no text input is currently focused
    func reclaimFocusIfNeeded() {
        modifierHoldGate.refresh()

        guard let window = self.window else { return }
        guard KeyboardMenuFocus.active?.window !== window else { return }
        let currentResponder = window.firstResponder
        // Don't steal from text fields, text views, or search fields
        if currentResponder is NSTextView || currentResponder is NSTextField || currentResponder is NSSearchField {
            return
        }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onClose?()
        case 123: // Left arrow
            onLeft?()
        case 124: // Right arrow
            onRight?()
        default:
            if let characters = event.charactersIgnoringModifiers {
                switch characters {
                case "s":
                    onStar?()
                case "x", "X":
                    if SingleFocusKeyRouting.shouldTogglePreferredDisplay(
                        charactersIgnoringModifiers: characters,
                        modifierFlags: event.modifierFlags,
                        isRepeat: event.isARepeat
                    ), let onTogglePreferredDisplay {
                        onTogglePreferredDisplay()
                    } else {
                        super.keyDown(with: event)
                    }
                case "?":
                    onShowShortcuts?()
                default:
                    super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        modifierHoldGate.handle(modifierFlags: event.modifierFlags)
        super.flagsChanged(with: event)
    }
}

// MARK: - Tag Overlay Modifier Hold Gate

/// Delays modifier-only overlay opening so quick app/window switching does not leave
/// the tag selector visible after the modifier release is missed.
final class TagOverlayModifierHoldGate {
    static let defaultHoldDelay: TimeInterval = 0.45

    var modifierFlag: NSEvent.ModifierFlags = .option {
        didSet {
            if modifierFlag != oldValue {
                close(sendRelease: true)
            }
        }
    }
    var holdDelay: TimeInterval = defaultHoldDelay
    var onStateChanged: ((Bool) -> Void)?

    private var isPhysicallyPressed = false
    private var didOpen = false
    private var pendingOpen: DispatchWorkItem?

    func handle(modifierFlags: NSEvent.ModifierFlags, enabled: Bool = true) {
        let nextPressed = enabled && modifierFlags.contains(modifierFlag)
        guard nextPressed != isPhysicallyPressed else { return }

        isPhysicallyPressed = nextPressed
        if nextPressed {
            scheduleOpen()
        } else {
            close(sendRelease: true)
        }
    }

    func refresh(enabled: Bool = true) {
        handle(modifierFlags: NSEvent.modifierFlags, enabled: enabled)
    }

    func close(sendRelease: Bool) {
        pendingOpen?.cancel()
        pendingOpen = nil
        isPhysicallyPressed = false

        let wasOpen = didOpen
        didOpen = false
        if sendRelease || wasOpen {
            onStateChanged?(false)
        }
    }

    private func scheduleOpen() {
        pendingOpen?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isPhysicallyPressed,
                  NSEvent.modifierFlags.contains(self.modifierFlag) else { return }

            self.pendingOpen = nil
            self.didOpen = true
            self.onStateChanged?(true)
        }

        pendingOpen = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: workItem)
    }
}
