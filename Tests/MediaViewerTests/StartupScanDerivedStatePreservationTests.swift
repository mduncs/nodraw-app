import XCTest
@testable import MediaViewer

final class StartupScanDerivedStatePreservationTests: XCTestCase {
    func testChangedScannedItemPreservesTranscriptionAndVideoUnderstandingState() {
        let existing = MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/archive/old"),
            metadataFile: URL(fileURLWithPath: "/archive/old/item.md"),
            mediaFiles: [URL(fileURLWithPath: "/archive/old/item.mp4")],
            metadata: metadata(source: "https://example.com/old", notes: "old"),
            aspectRatio: 1.0,
            videoUnderstandingStatus: "failed",
            videoUnderstandingLastError: "existing video error",
            videoUnderstandingFailedAt: "2026-08-28T20:15:00Z",
            videoUnderstandingRetryCount: 3,
            videoUnderstandingVersion: 7,
            transcriptionStatus: "complete",
            transcriptionLastError: "existing transcription warning",
            transcriptionFailedAt: "2026-08-27T19:45:00Z",
            transcriptionRetryCount: 2,
            transcriptionVersion: 11
        )
        let parsed = MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/archive/new"),
            metadataFile: URL(fileURLWithPath: "/archive/new/item.md"),
            mediaFiles: [URL(fileURLWithPath: "/archive/new/item.webm")],
            contextImage: URL(fileURLWithPath: "/archive/new/item.context.png"),
            metadata: metadata(source: "https://example.com/new", notes: "changed"),
            aspectRatio: 16.0 / 9.0
        )

        let updated = AppCoordinator.changedScannedItem(parsed, preserving: existing)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.basePath, parsed.basePath)
        XCTAssertEqual(updated.metadataFile, parsed.metadataFile)
        XCTAssertEqual(updated.mediaFiles, parsed.mediaFiles)
        XCTAssertEqual(updated.contextImage, parsed.contextImage)
        XCTAssertEqual(updated.metadata, parsed.metadata)
        XCTAssertEqual(updated.aspectRatio, parsed.aspectRatio)

        XCTAssertEqual(updated.videoUnderstandingStatus, existing.videoUnderstandingStatus)
        XCTAssertEqual(updated.videoUnderstandingLastError, existing.videoUnderstandingLastError)
        XCTAssertEqual(updated.videoUnderstandingFailedAt, existing.videoUnderstandingFailedAt)
        XCTAssertEqual(updated.videoUnderstandingRetryCount, existing.videoUnderstandingRetryCount)
        XCTAssertEqual(updated.videoUnderstandingVersion, existing.videoUnderstandingVersion)

        XCTAssertEqual(updated.transcriptionStatus, existing.transcriptionStatus)
        XCTAssertEqual(updated.transcriptionLastError, existing.transcriptionLastError)
        XCTAssertEqual(updated.transcriptionFailedAt, existing.transcriptionFailedAt)
        XCTAssertEqual(updated.transcriptionRetryCount, existing.transcriptionRetryCount)
        XCTAssertEqual(updated.transcriptionVersion, existing.transcriptionVersion)
    }

    private func metadata(source: String, notes: String) -> MediaMetadata {
        MediaMetadata(
            source: URL(string: source)!,
            platform: "test",
            archivedDate: Date(timeIntervalSince1970: 1_777_118_400),
            notes: notes
        )
    }
}
