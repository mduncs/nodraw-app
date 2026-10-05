import XCTest
@testable import MediaViewer

@MainActor
final class TimelineViewModelRangeTests: XCTestCase {
    func testRangeEndpointMovementKeepsRangeOrderedWhenHandleCrosses() {
        let model = TimelineViewModel()
        let start = Date(timeIntervalSince1970: 1_000)
        let middle = Date(timeIntervalSince1970: 2_000)
        let end = Date(timeIntervalSince1970: 3_000)

        model.setSelectedRange(start...end)
        model.moveSelectedRangeBoundary(.lower, to: middle)
        XCTAssertEqual(model.selectedRange, middle...end)

        model.moveSelectedRangeBoundary(.upper, to: start)
        XCTAssertEqual(model.selectedRange, start...middle)
    }

    func testEndpointMovementWithoutExistingRangeCreatesSingleDateRange() {
        let model = TimelineViewModel()
        let date = Date(timeIntervalSince1970: 1_000)

        model.moveSelectedRangeBoundary(.lower, to: date)

        XCTAssertEqual(model.selectedRange, date...date)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testBucketSpansTileThePlotAxisSoBarsAndSelectionShareOneMapping() async {
        // Mid-month dates: the raw min...max data range would not line up with month edges.
        let dates = [date(2026, 1, 20), date(2026, 2, 3), date(2026, 3, 10)]
        let model = TimelineViewModel(dateLoader: { dates })
        await model.loadTimelineData()

        XCTAssertEqual(model.buckets.count, 3)
        XCTAssertFalse(model.hasSinglePeriod)
        XCTAssertEqual(model.itemCount, 3)
        let spans = model.buckets.compactMap { model.span(of: $0) }
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans.first!.lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(spans.last!.upperBound, 1, accuracy: 0.0001)
        for (a, b) in zip(spans, spans.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, accuracy: 0.0001)
        }

        // A pointer in the middle of the February bar maps back into February.
        let feb = spans[1]
        let hit = model.dateForPosition((feb.lowerBound + feb.upperBound) / 2 * 600, in: 600)!
        XCTAssertEqual(Calendar.current.component(.month, from: hit), 2)
    }

    func testSingleDayLibraryIsOnePeriod() async {
        let dates = [date(2026, 9, 21), date(2026, 9, 21)]
        let model = TimelineViewModel(dateLoader: { dates })
        await model.loadTimelineData()

        XCTAssertTrue(model.hasSinglePeriod)
        XCTAssertEqual(model.itemCount, 2)
        let span = model.span(of: model.buckets[0])!
        XCTAssertEqual(span.lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(span.upperBound, 1, accuracy: 0.0001)
    }

    func testAxisLabelsNameTheMonthOrYearWhenItChanges() {
        let jul31 = date(2026, 7, 31), aug1 = date(2026, 8, 1), aug8 = date(2026, 8, 8)
        let monthDay = DateFormatter(); monthDay.dateFormat = "MMM d"
        XCTAssertEqual(TimelineGranularity.day.formatAxisLabel(for: jul31, previous: nil), monthDay.string(from: jul31))
        XCTAssertEqual(TimelineGranularity.day.formatAxisLabel(for: aug1, previous: jul31), monthDay.string(from: aug1))
        XCTAssertEqual(TimelineGranularity.day.formatAxisLabel(for: aug8, previous: aug1), "8")

        let dec = date(2025, 12, 1), jan = date(2026, 1, 1), feb = date(2026, 2, 1)
        let monthOnly = DateFormatter(); monthOnly.dateFormat = "MMM"
        let monthYear = DateFormatter(); monthYear.dateFormat = "MMM yyyy"
        XCTAssertEqual(TimelineGranularity.month.formatAxisLabel(for: dec, previous: nil), monthYear.string(from: dec))
        XCTAssertEqual(TimelineGranularity.month.formatAxisLabel(for: jan, previous: dec), monthYear.string(from: jan))
        XCTAssertEqual(TimelineGranularity.month.formatAxisLabel(for: feb, previous: jan), monthOnly.string(from: feb))
    }

    func testWholeMonthSelectionReadsAsTheMonth() {
        let model = TimelineViewModel()
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1)
        model.setSelectedRange(start...end)
        let formatter = DateFormatter(); formatter.dateFormat = "MMM yyyy"
        XCTAssertEqual(model.selectedRangeLabel, formatter.string(from: start))

        model.setSelectedRange(start...calendar.date(byAdding: .day, value: 9, to: start)!)
        XCTAssertNotEqual(model.selectedRangeLabel, formatter.string(from: start))
    }
}
