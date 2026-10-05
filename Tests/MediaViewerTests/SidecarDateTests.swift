import XCTest
import Yams
@testable import MediaViewer

final class SidecarDateTests: XCTestCase {
    override func setUpWithError() throws {
        // Set TZ before starting XCTest so cached Foundation formatters agree too.
        // Run with: TZ=America/Chicago swift test --skip-build --filter SidecarDateTests
        try XCTSkipUnless(TimeZone.current.identifier == "America/Chicago", "Requires TZ=America/Chicago")
    }

    private func content(_ fields: String) -> String {
        "---\nsource: https://example.com/item\n\(fields)\n---\nBody stays exact.\n"
    }

    private func instant(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        let parts = value.dropLast().split(separator: ".")
        let wholeSecond = try XCTUnwrap(formatter.date(from: "\(parts[0])Z"))
        return wholeSecond.addingTimeInterval(try XCTUnwrap(Double("0.\(parts[1])")))
    }

    private func checkArchived(_ fields: String, expected: Date) throws {
        let strict = try MetadataParser.parse(content: content(fields))
        let graceful = try XCTUnwrap(MetadataParser.parseGracefully(content: content(fields)).metadata)
        XCTAssertEqual(strict.archivedDate.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(graceful.archivedDate.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testZonelessArchivedUsesLocalDaylightTime() throws {
        try checkArchived("archived: 2026-10-02T23:33:13.640333", expected: instant("2026-10-03T04:33:13.640333Z"))
    }

    func testZonelessArchivedUsesLocalStandardTime() throws {
        try checkArchived("archived: 2026-01-02T23:33:13.640333", expected: instant("2026-01-03T05:33:13.640333Z"))
    }

    func testZonelessDateOnlyAndSpaceSeparatedTimeUseLocalTime() throws {
        try checkArchived("archived: 2024-01-02", expected: instant("2024-01-02T06:00:00.000Z"))
        try checkArchived("archived: 2024-01-02 10:00:00", expected: instant("2024-01-02T16:00:00.000Z"))
    }

    func testZonedArchivedKeepsInstant() throws {
        for value in ["2026-10-02T23:33:13.640333Z", "2026-10-03T05:03:13.640333+05:30",
                      "2026-10-03T04:33:13.640333 +5", "2026-10-02T17:33:13.640333 -06"] {
            try checkArchived("archived: \(value)", expected: instant("2026-10-02T23:33:13.640333Z"))
        }
    }

    func testFrontmatterEditKeepsLocalTimestampInstant() throws {
        // Yams.dump represents Dates at millisecond precision.
        let original = content("archived: 2026-10-02T23:33:13.640")
        let expected = try instant("2026-10-03T04:33:13.640Z")
        let updated = try FrontmatterWriter.processContent(original) { $0["starred"] = true }
        let values = try XCTUnwrap(Yams.load(yaml: FrontmatterWriter.parseBoundaries(updated).yamlText) as? [String: Any])
        let archived = try XCTUnwrap(values["archived"] as? Date)
        // Yams.dump emits an explicit zone, so even its default loader must see the right instant.
        XCTAssertEqual(archived.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(values["starred"] as? Bool, true)
        XCTAssertTrue(updated.hasSuffix("\nBody stays exact.\n"))
        let reparsed = try MetadataParser.parse(content: updated)
        XCTAssertEqual(reparsed.archivedDate.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testOriginalDateAliasesFallThroughToFirstParseableValue() throws {
        let aliases = ["date", "originalDate", "created", "tweet_date", "post_date"]
        let expected = try instant("2024-01-02T16:00:00.000Z")
        for index in aliases.indices {
            let invalid = aliases.prefix(index).map { "\($0): invalid" }
            let fields = (invalid + ["\(aliases[index]): '2024-01-02 10:00:00'", "date_taken: '2020-01-01 10:00:00'"]).joined(separator: "\n")
            let strict = try MetadataParser.parse(content: content(fields))
            let graceful = try XCTUnwrap(MetadataParser.parseGracefully(content: content(fields)).metadata)
            XCTAssertEqual(strict.originalDate, expected, aliases[index])
            XCTAssertEqual(graceful.originalDate, expected, aliases[index])
            XCTAssertEqual(graceful.originalDateString, "2024-01-02 10:00:00", aliases[index])
        }
    }

    func testDateTakenTextUsesLocalTime() throws {
        try checkDateTaken("2024-01-02 10:00:00")
    }

    func testDateTakenEXIFUsesLocalTime() throws {
        try checkDateTaken("2024:01:02 10:00:00")
    }

    private func checkDateTaken(_ value: String) throws {
        let text = content("date: invalid\npost_date: invalid\ndate_taken: '\(value)'")
        let expected = try instant("2024-01-02T16:00:00.000Z")
        let strict = try MetadataParser.parse(content: text)
        let graceful = try XCTUnwrap(MetadataParser.parseGracefully(content: text).metadata)
        XCTAssertEqual(strict.originalDate, expected)
        XCTAssertEqual(graceful.originalDate, expected)
        XCTAssertEqual(graceful.originalDateString, value)
    }
}
