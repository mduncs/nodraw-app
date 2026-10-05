import Foundation
import SwiftUI
import Combine
import GRDB

// MARK: - Timeline Granularity

/// Time bucket granularity for the timeline visualization
enum TimelineGranularity: String, CaseIterable, Sendable {
    case day
    case week
    case month

    /// Calendar component for bucketing dates
    var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    /// Typical number of items per bucket before suggesting zoom out
    var typicalBucketCount: Int {
        switch self {
        case .day: return 30
        case .week: return 12
        case .month: return 12
        }
    }

    /// Label format for bucket display
    func formatLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        switch self {
        case .day:
            formatter.dateFormat = "MMM d"
        case .week:
            formatter.dateFormat = "MMM d"
        case .month:
            formatter.dateFormat = "MMM yyyy"
        }
        return formatter.string(from: date)
    }

    /// Axis tick label that names the month (or year) whenever it changes from the previous
    /// tick, so a day axis reads "Jul 31 · 8 · 16 · Aug 1" instead of bare day numbers.
    func formatAxisLabel(for date: Date, previous: Date?, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        switch self {
        case .day, .week:
            let sameMonth = previous.map { calendar.isDate($0, equalTo: date, toGranularity: .month) } ?? false
            formatter.dateFormat = sameMonth ? "d" : "MMM d"
        case .month:
            let sameYear = previous.map { calendar.isDate($0, equalTo: date, toGranularity: .year) } ?? false
            formatter.dateFormat = sameYear ? "MMM" : "MMM yyyy"
        }
        return formatter.string(from: date)
    }

    /// Short label for axis ticks
    func formatShortLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        switch self {
        case .day:
            formatter.dateFormat = "d"
        case .week:
            formatter.dateFormat = "d"
        case .month:
            formatter.dateFormat = "MMM"
        }
        return formatter.string(from: date)
    }
}

enum TimelineRangeBoundary: Sendable {
    case lower
    case upper
}

// MARK: - Timeline Bucket

/// A single time bucket with count data
struct TimelineBucket: Identifiable, Equatable {
    let id: Date  // Start of bucket period
    let date: Date
    let count: Int
    let normalizedHeight: CGFloat  // 0.0 - 1.0, relative to max count

    init(date: Date, count: Int, maxCount: Int) {
        self.id = date
        self.date = date
        self.count = count
        self.normalizedHeight = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
    }
}

// MARK: - Timeline ViewModel

/// Observable state manager for the timeline filter view.
/// Computes buckets, handles range selection, and syncs with FilterState.
@MainActor
final class TimelineViewModel: ObservableObject {
    // MARK: - Published State

    /// Full date range of all items in current filter (excluding date filter itself)
    @Published private(set) var dataRange: ClosedRange<Date>?

    /// User-selected date range for filtering (nil = no date filter)
    @Published var selectedRange: ClosedRange<Date>?

    /// Computed buckets for density visualization
    @Published private(set) var buckets: [TimelineBucket] = []

    /// Current granularity level
    @Published var granularity: TimelineGranularity = .month

    /// Whether timeline data is loading
    @Published private(set) var isLoading: Bool = false

    /// Whether the timeline is expanded (visible)
    @Published var isExpanded: Bool = true

    // MARK: - Private State

    private var mediaStore: MediaStore?
    private var cancellables = Set<AnyCancellable>()
    private let calendar = Calendar.current
    private var timelineDates: [Date] = []
    /// Test seam; production reads archived dates from the database.
    private let dateLoader: (@MainActor () async throws -> [Date])?
    private var archiveChangeSubscription: AnyCancellable?
    private var reloadTask: Task<Void, Never>?
    private var loadGeneration = 0

    // Cache for bucket computation
    private var bucketCache: (granularity: TimelineGranularity, dataRange: ClosedRange<Date>?, items: [Date], result: [TimelineBucket])?

    // MARK: - Initialization

    init(dateLoader: (@MainActor () async throws -> [Date])? = nil) {
        self.dateLoader = dateLoader
    }

    /// Attach to a MediaStore for data loading. Archive changes (first scan, import,
    /// delete, restore) reload the density, so it cannot stay "No data" or stale.
    func attach(to store: MediaStore) {
        self.mediaStore = store
        observeArchiveChanges(
            Publishers.Merge(
                store.changes,
                NotificationCenter.default.publisher(for: .mediaStoreDidChange).map { _ in () }
            ).eraseToAnyPublisher()
        )
    }

    func observeArchiveChanges(_ changes: AnyPublisher<Void, Never>, debounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(400)) {
        archiveChangeSubscription = changes
            .debounce(for: debounce, scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reloadAfterArchiveChange() }
    }

    private func reloadAfterArchiveChange() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let hadData = self.dataRange != nil
            await self.loadTimelineData()
            // Data arriving after an empty start gets the launch-time automatic zoom;
            // afterwards the user's chosen zoom is kept.
            if !Task.isCancelled, !hadData { self.autoSelectGranularity() }
        }
    }

    // MARK: - Data Loading

    /// Load timeline data from the database
    /// Fetches all archived dates to compute buckets
    func loadTimelineData() async {
        guard dateLoader != nil || mediaStore != nil else { return }
        loadGeneration += 1
        let generation = loadGeneration

        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            // Fetch date range and bucket data from database
            let (range, dates): (ClosedRange<Date>?, [Date])
            if let dateLoader {
                let loaded = try await dateLoader().sorted()
                (range, dates) = (loaded.first.flatMap { first in loaded.last.map { first...$0 } }, loaded)
            } else {
                (range, dates) = try await fetchDateData()
            }
            // A superseded reload must not overwrite newer archive state.
            guard generation == loadGeneration else { return }

            self.dataRange = range
            self.timelineDates = dates
            computeBuckets(from: dates)

        } catch {
            logError("Failed to load timeline data: \(error.localizedDescription)")
        }
    }

    /// Fetch date data from the media store
    private func fetchDateData() async throws -> (ClosedRange<Date>?, [Date]) {
        // Use a direct database query for efficiency
        // We want min/max dates and all dates for bucketing
        let database = mediaStore?.database ?? DatabaseManager.shared

        return try await database.read { db in
            // Get date range (excluding soft-deleted items)
            let rangeRow = try Row.fetchOne(db, sql: """
                SELECT MIN(archivedDate) as minDate, MAX(archivedDate) as maxDate
                FROM media_items
                WHERE (deletedAt IS NULL OR deletedAt = '')
            """)

            guard let row = rangeRow,
                  let minDate: Date = row["minDate"],
                  let maxDate: Date = row["maxDate"] else {
                return (nil, [])
            }

            // Fetch all archived dates for bucketing (excluding soft-deleted items)
            let dates = try Date.fetchAll(db, sql: """
                SELECT archivedDate FROM media_items
                WHERE (deletedAt IS NULL OR deletedAt = '')
                ORDER BY archivedDate
            """)

            return (minDate...maxDate, dates)
        }
    }

    // MARK: - Bucket Computation

    /// Compute buckets from a list of dates
    private func computeBuckets(from dates: [Date]) {
        guard !dates.isEmpty, let range = dataRange else {
            buckets = []
            return
        }

        // Check cache
        if let cached = bucketCache,
           cached.granularity == granularity,
           cached.dataRange == range,
           cached.items == dates {
            buckets = cached.result
            return
        }

        // Group dates into buckets based on granularity
        var bucketCounts: [Date: Int] = [:]

        for date in dates {
            let bucketStart = startOfBucket(for: date)
            bucketCounts[bucketStart, default: 0] += 1
        }

        // Find max count for normalization
        let maxCount = bucketCounts.values.max() ?? 1

        // Generate all buckets in range (including empty ones)
        var allBuckets: [TimelineBucket] = []
        var currentDate = startOfBucket(for: range.lowerBound)
        let endDate = startOfBucket(for: range.upperBound)

        while currentDate <= endDate {
            let count = bucketCounts[currentDate] ?? 0
            allBuckets.append(TimelineBucket(date: currentDate, count: count, maxCount: maxCount))
            currentDate = nextBucketStart(after: currentDate)
        }

        buckets = allBuckets
        bucketCache = (granularity, range, dates, allBuckets)
    }

    /// Get the start of the bucket period for a given date
    private func startOfBucket(for date: Date) -> Date {
        switch granularity {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? date
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? date
        }
    }

    /// Get the start of the next bucket after a given bucket start
    func nextBucketStart(after date: Date) -> Date {
        calendar.date(byAdding: granularity.calendarComponent, value: 1, to: date) ?? date
    }

    // MARK: - Granularity Control

    /// Zoom in to finer granularity
    func zoomIn() {
        switch granularity {
        case .month:
            granularity = .week
        case .week:
            granularity = .day
        case .day:
            break // Already at finest level
        }
        invalidateCache()
        recomputeBuckets()
    }

    /// Zoom out to coarser granularity
    func zoomOut() {
        switch granularity {
        case .day:
            granularity = .week
        case .week:
            granularity = .month
        case .month:
            break // Already at coarsest level
        }
        invalidateCache()
        recomputeBuckets()
    }

    /// Auto-select granularity based on data range
    func autoSelectGranularity() {
        guard let range = dataRange else { return }

        let daysDiff = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0

        if daysDiff <= 60 {
            granularity = .day
        } else if daysDiff <= 365 {
            granularity = .week
        } else {
            granularity = .month
        }

        invalidateCache()
        recomputeBuckets()
    }

    // MARK: - Range Selection

    /// Set the selected date range for filtering
    func setSelectedRange(_ range: ClosedRange<Date>?) {
        selectedRange = range
    }

    /// Move one visible range endpoint while keeping the closed range ordered.
    /// Crossing the opposite endpoint naturally swaps which date is lower/upper.
    func moveSelectedRangeBoundary(_ boundary: TimelineRangeBoundary, to date: Date) {
        guard let current = selectedRange else {
            selectedRange = date...date
            return
        }

        switch boundary {
        case .lower:
            selectedRange = min(date, current.upperBound)...max(date, current.upperBound)
        case .upper:
            selectedRange = min(current.lowerBound, date)...max(current.lowerBound, date)
        }
    }

    /// Clear the date filter
    func clearSelection() {
        selectedRange = nil
    }

    /// Select a single bucket (expand to full bucket range)
    func selectBucket(_ bucket: TimelineBucket) {
        let start = bucket.date
        let end = nextBucketStart(after: start).addingTimeInterval(-1)
        selectedRange = start...end
    }

    /// Extend selection to include a bucket
    func extendSelectionTo(_ bucket: TimelineBucket) {
        guard let current = selectedRange else {
            selectBucket(bucket)
            return
        }

        let bucketEnd = nextBucketStart(after: bucket.date).addingTimeInterval(-1)

        if bucket.date < current.lowerBound {
            selectedRange = bucket.date...current.upperBound
        } else {
            selectedRange = current.lowerBound...bucketEnd
        }
    }

    // MARK: - Helpers

    /// The plotted axis: the first bucket's start through the end of the last bucket. Bars, the
    /// selection band, hover and pointer mapping all share it, so a bar sits exactly under the
    /// dates it counts (the raw min...max archived dates would drift from bucket edges).
    var plotRange: ClosedRange<Date>? {
        guard let first = buckets.first, let last = buckets.last else { return dataRange }
        return first.date...nextBucketStart(after: last.date)
    }

    /// Every archived date falls in one bucket: there is nothing to scrub at this granularity.
    var hasSinglePeriod: Bool { buckets.count == 1 }

    /// Total archived items the timeline counts.
    var itemCount: Int { buckets.reduce(0) { $0 + $1.count } }

    /// Normalized horizontal extent (0...1) of a bucket on the plot axis.
    func span(of bucket: TimelineBucket) -> ClosedRange<CGFloat>? {
        guard let start = positionForDate(bucket.date),
              let end = positionForDate(nextBucketStart(after: bucket.date)) else { return nil }
        return min(start, end)...max(start, end)
    }

    /// Convert a screen position to a date within the timeline
    func dateForPosition(_ position: CGFloat, in width: CGFloat) -> Date? {
        guard let range = plotRange, width > 0 else { return nil }

        let progress = max(0, min(1, position / width))
        let totalSeconds = range.upperBound.timeIntervalSince(range.lowerBound)
        let offsetSeconds = totalSeconds * Double(progress)

        return range.lowerBound.addingTimeInterval(offsetSeconds)
    }

    /// Convert a date to a normalized position (0-1)
    func positionForDate(_ date: Date) -> CGFloat? {
        guard let range = plotRange else { return nil }

        let totalSeconds = range.upperBound.timeIntervalSince(range.lowerBound)
        guard totalSeconds > 0 else { return 0 }

        let offsetSeconds = date.timeIntervalSince(range.lowerBound)
        return CGFloat(offsetSeconds / totalSeconds)
    }

    private func invalidateCache() {
        bucketCache = nil
    }

    private func recomputeBuckets() {
        computeBuckets(from: timelineDates)
    }

    /// Check if a bucket is within the selected range
    func isBucketSelected(_ bucket: TimelineBucket) -> Bool {
        guard let selected = selectedRange else { return false }
        let bucketEnd = nextBucketStart(after: bucket.date).addingTimeInterval(-1)
        return bucket.date <= selected.upperBound && bucketEnd >= selected.lowerBound
    }
}

// MARK: - Date Formatting Helpers

extension TimelineViewModel {
    /// Format the selected range for display
    var selectedRangeLabel: String? {
        guard let range = selectedRange else { return nil }

        // A whole calendar month (a clicked month bar) reads as that month.
        if let month = Calendar.current.dateInterval(of: .month, for: range.lowerBound),
           month.start == range.lowerBound,
           abs(month.end.timeIntervalSince(range.upperBound)) <= 1 {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM yyyy"
            return formatter.string(from: range.lowerBound)
        }

        // "Feb 1 – 28, 2026" rather than repeating the month and year on both ends.
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: range.lowerBound, to: range.upperBound)
    }

    /// Format the data range for display
    var dataRangeLabel: String? {
        guard let range = dataRange else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"

        let start = formatter.string(from: range.lowerBound)
        let end = formatter.string(from: range.upperBound)

        if start == end {
            return start
        }
        return "\(start) – \(end)"
    }
}
