import XCTest
@testable import MediaViewer

/// Tests for duplicate detection functionality (DuplicateGroup model and related logic)
/// Note: PerceptualHash tests are in PerceptualHashTests.swift
final class DuplicateDetectorTests: XCTestCase {

    // MARK: - DuplicateGroup Model Tests

    func testDuplicateGroupInitialization() {
        let itemIds = [UUID(), UUID(), UUID()]
        let group = DuplicateGroup(
            itemIds: itemIds,
            detectionMethod: .perceptualHash,
            similarity: 0.95
        )

        XCTAssertEqual(group.itemIds.count, 3)
        XCTAssertEqual(group.status, .pending)
        XCTAssertEqual(group.detectionMethod, .perceptualHash)
        XCTAssertEqual(group.similarity, 0.95)
        XCTAssertNil(group.primaryItemId)
    }

    func testDuplicateGroupWithPrimary() {
        let id1 = UUID()
        let id2 = UUID()
        let group = DuplicateGroup(
            itemIds: [id1, id2],
            primaryItemId: id1,
            detectionMethod: .featureVector,
            similarity: 0.88
        )

        XCTAssertEqual(group.primaryItemId, id1)
        XCTAssertEqual(group.count, 2)
    }

    func testDuplicateGroupSimilarityPercent() {
        let testCases: [(Float, String)] = [
            (1.0, "100%"),
            (0.95, "95%"),
            (0.875, "88%"),  // rounds to 88%
            (0.5, "50%"),
            (0.0, "0%")
        ]

        for (similarity, expected) in testCases {
            let group = DuplicateGroup(
                itemIds: [UUID(), UUID()],
                detectionMethod: .perceptualHash,
                similarity: similarity
            )

            XCTAssertEqual(group.similarityPercent, expected, "Expected \(expected) for similarity \(similarity)")
        }
    }

    func testDuplicateGroupCount() {
        let group = DuplicateGroup(
            itemIds: [UUID(), UUID(), UUID(), UUID()],
            detectionMethod: .perceptualHash,
            similarity: 1.0
        )

        XCTAssertEqual(group.count, 4)
        XCTAssertFalse(group.isEmpty)
    }

    func testDuplicateGroupEmpty() {
        let group = DuplicateGroup(
            itemIds: [],
            detectionMethod: .perceptualHash,
            similarity: 0.0
        )

        XCTAssertTrue(group.isEmpty)
        XCTAssertEqual(group.count, 0)
    }

    // MARK: - Status Tests

    func testStatusDisplayNames() {
        XCTAssertEqual(DuplicateGroup.Status.pending.displayName, "Pending")
        XCTAssertEqual(DuplicateGroup.Status.reviewed.displayName, "Reviewed")
        XCTAssertEqual(DuplicateGroup.Status.resolved.displayName, "Resolved")
        XCTAssertEqual(DuplicateGroup.Status.dismissed.displayName, "Dismissed")
    }

    func testStatusRawValues() {
        XCTAssertEqual(DuplicateGroup.Status.pending.rawValue, "pending")
        XCTAssertEqual(DuplicateGroup.Status.reviewed.rawValue, "reviewed")
        XCTAssertEqual(DuplicateGroup.Status.resolved.rawValue, "resolved")
        XCTAssertEqual(DuplicateGroup.Status.dismissed.rawValue, "dismissed")
    }

    func testStatusFromRawValue() {
        XCTAssertEqual(DuplicateGroup.Status(rawValue: "pending"), .pending)
        XCTAssertEqual(DuplicateGroup.Status(rawValue: "reviewed"), .reviewed)
        XCTAssertEqual(DuplicateGroup.Status(rawValue: "resolved"), .resolved)
        XCTAssertEqual(DuplicateGroup.Status(rawValue: "dismissed"), .dismissed)
        XCTAssertNil(DuplicateGroup.Status(rawValue: "invalid"))
    }

    // MARK: - Detection Method Tests

    func testDetectionMethodDisplayNames() {
        XCTAssertEqual(DuplicateGroup.DetectionMethod.perceptualHash.displayName, "Visual candidate")
        XCTAssertEqual(DuplicateGroup.DetectionMethod.featureVector.displayName, "Legacy similarity")
    }

    func testDetectionMethodIcons() {
        XCTAssertEqual(DuplicateGroup.DetectionMethod.perceptualHash.icon, "number.square")
        XCTAssertEqual(DuplicateGroup.DetectionMethod.featureVector.icon, "eye")
    }

    func testDetectionMethodRawValues() {
        XCTAssertEqual(DuplicateGroup.DetectionMethod.perceptualHash.rawValue, "perceptualHash")
        XCTAssertEqual(DuplicateGroup.DetectionMethod.featureVector.rawValue, "featureVector")
    }

    func testDetectionMethodFromRawValue() {
        XCTAssertEqual(DuplicateGroup.DetectionMethod(rawValue: "perceptualHash"), .perceptualHash)
        XCTAssertEqual(DuplicateGroup.DetectionMethod(rawValue: "featureVector"), .featureVector)
        XCTAssertNil(DuplicateGroup.DetectionMethod(rawValue: "invalid"))
    }

    // MARK: - Equatable/Hashable Tests

    func testDuplicateGroupEquatable() {
        let id = UUID()
        let itemIds = [UUID(), UUID()]
        let date = Date()

        let group1 = DuplicateGroup(
            id: id,
            itemIds: itemIds,
            detectionMethod: .perceptualHash,
            similarity: 0.9,
            createdAt: date,
            updatedAt: date
        )

        let group2 = DuplicateGroup(
            id: id,
            itemIds: itemIds,
            detectionMethod: .perceptualHash,
            similarity: 0.9,
            createdAt: date,
            updatedAt: date
        )

        XCTAssertEqual(group1, group2)
    }

    func testDuplicateGroupHashable() {
        let group1 = DuplicateGroup(
            itemIds: [UUID()],
            detectionMethod: .perceptualHash,
            similarity: 0.9
        )

        let group2 = DuplicateGroup(
            itemIds: [UUID()],
            detectionMethod: .featureVector,
            similarity: 0.85
        )

        var set = Set<DuplicateGroup>()
        set.insert(group1)
        set.insert(group2)

        XCTAssertEqual(set.count, 2)
    }

    // MARK: - DuplicateGroupRecord Tests

    func testDuplicateGroupRecordFromGroup() {
        let id = UUID()
        let primaryId = UUID()
        let date = Date()

        let group = DuplicateGroup(
            id: id,
            itemIds: [primaryId, UUID()],
            primaryItemId: primaryId,
            status: .reviewed,
            detectionMethod: .featureVector,
            similarity: 0.87,
            createdAt: date,
            updatedAt: date
        )

        let record = DuplicateGroupRecord(from: group)

        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.primaryItemId, primaryId)
        XCTAssertEqual(record.status, "reviewed")
        XCTAssertEqual(record.detectionMethod, "featureVector")
        XCTAssertEqual(record.similarity, 0.87)
    }

    func testDuplicateGroupRecordToDuplicateGroup() {
        let id = UUID()
        let primaryId = UUID()
        let itemIds = [primaryId, UUID(), UUID()]
        let date = Date()

        let record = DuplicateGroupRecord(from: DuplicateGroup(
            id: id,
            itemIds: itemIds,
            primaryItemId: primaryId,
            status: .pending,
            detectionMethod: .perceptualHash,
            similarity: 0.95,
            createdAt: date,
            updatedAt: date
        ))

        let group = record.toDuplicateGroup(itemIds: itemIds)

        XCTAssertNotNil(group)
        XCTAssertEqual(group?.id, id)
        XCTAssertEqual(group?.itemIds, itemIds)
        XCTAssertEqual(group?.primaryItemId, primaryId)
        XCTAssertEqual(group?.status, .pending)
        XCTAssertEqual(group?.detectionMethod, .perceptualHash)
    }

    // MARK: - DuplicateGroupMemberRecord Tests

    func testDuplicateGroupMemberRecordInit() {
        let groupId = UUID()
        let itemId = UUID()

        let member = DuplicateGroupMemberRecord(
            groupId: groupId,
            itemId: itemId,
            isPrimary: true
        )

        XCTAssertEqual(member.groupId, groupId)
        XCTAssertEqual(member.itemId, itemId)
        XCTAssertTrue(member.isPrimary)
    }

    func testDuplicateGroupMemberRecordDefaultIsPrimary() {
        let groupId = UUID()
        let itemId = UUID()

        let member = DuplicateGroupMemberRecord(
            groupId: groupId,
            itemId: itemId
        )

        XCTAssertFalse(member.isPrimary)
    }
}
