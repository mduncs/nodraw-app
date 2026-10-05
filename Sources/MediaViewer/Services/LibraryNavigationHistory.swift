import Foundation

/// The user-visible transition that produced a library navigation entry.
///
/// Keeping this separate from view presentation state lets every input path (menu,
/// keyboard, and mouse) consume the same history without teaching views how to unwind it.
enum LibraryNavigationTransitionKind: Equatable {
    case destination
    case search
    case filter
    case detail
}

/// A small, pure back-stack with explicit support for coalesced transitions.
///
/// Search fields can call `stageCoalescedTransition` for every edit and commit once after
/// their debounce window. Other transitions automatically commit a pending edit first,
/// preserving the meaningful order without creating an entry per keystroke.
struct LibraryNavigationHistory<State: Equatable>: Equatable {
    struct Entry: Equatable {
        let state: State
        let transition: LibraryNavigationTransitionKind
    }

    private struct PendingTransition: Equatable {
        let baselineState: State
        var latestState: State
        let transition: LibraryNavigationTransitionKind
    }

    private(set) var entries: [Entry] = []
    private var pendingTransition: PendingTransition?
    private let maximumDepth: Int

    init(maximumDepth: Int = 100) {
        self.maximumDepth = max(1, maximumDepth)
    }

    var canNavigateBack: Bool {
        if let pendingTransition,
           pendingTransition.baselineState != pendingTransition.latestState {
            return true
        }
        return !entries.isEmpty
    }

    var count: Int {
        entries.count + (hasMeaningfulPendingTransition ? 1 : 0)
    }

    /// Record a committed, non-coalesced transition.
    @discardableResult
    mutating func recordTransition(
        from previousState: State,
        to currentState: State,
        kind: LibraryNavigationTransitionKind
    ) -> Bool {
        _ = commitCoalescedTransition()
        guard previousState != currentState else { return false }
        append(Entry(state: previousState, transition: kind))
        return true
    }

    /// Stage one update in a coalesced transition such as live search editing.
    mutating func stageCoalescedTransition(
        from previousState: State,
        to currentState: State,
        kind: LibraryNavigationTransitionKind
    ) {
        if var pendingTransition, pendingTransition.transition == kind {
            pendingTransition.latestState = currentState
            self.pendingTransition = pendingTransition
            return
        }

        _ = commitCoalescedTransition()
        pendingTransition = PendingTransition(
            baselineState: previousState,
            latestState: currentState,
            transition: kind
        )
    }

    /// Commit the current coalesced transition as exactly one back-stack entry.
    @discardableResult
    mutating func commitCoalescedTransition() -> Bool {
        guard let pendingTransition else { return false }
        self.pendingTransition = nil
        guard pendingTransition.baselineState != pendingTransition.latestState else {
            return false
        }
        append(
            Entry(
                state: pendingTransition.baselineState,
                transition: pendingTransition.transition
            )
        )
        return true
    }

    /// Pop exactly one user-visible transition. A pending search edit is committed first.
    mutating func navigateBack() -> Entry? {
        _ = commitCoalescedTransition()
        return entries.popLast()
    }

    /// Consume an explicit transition that was exited through a non-Back affordance.
    /// For example, closing detail with Escape must not leave a stale detail entry behind.
    @discardableResult
    mutating func discardLatestTransition(ifKind kind: LibraryNavigationTransitionKind) -> Bool {
        guard entries.last?.transition == kind else { return false }
        entries.removeLast()
        return true
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        pendingTransition = nil
    }

    private var hasMeaningfulPendingTransition: Bool {
        guard let pendingTransition else { return false }
        return pendingTransition.baselineState != pendingTransition.latestState
    }

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maximumDepth {
            entries.removeFirst(entries.count - maximumDepth)
        }
    }
}

/// A generation-stamped handoff to whichever browse presentation is currently visible.
enum LibraryScrollTarget: Equatable {
    case top
    case item(UUID)
}

struct LibraryScrollRequest: Equatable {
    private(set) var generation: Int = 0
    private(set) var target: LibraryScrollTarget = .top

    mutating func issue(_ target: LibraryScrollTarget) {
        generation &+= 1
        self.target = target
    }
}
