import XCTest
import GRDB
@testable import MediaViewer

final class AnnotationTests: XCTestCase {

    // MARK: - NormalizedPoint Tests

    func testNormalizedPointScaling() {
        let point = NormalizedPoint(x: 0.5, y: 0.25)
        let size = CGSize(width: 800, height: 600)

        let scaled = point.scaled(to: size)

        XCTAssertEqual(scaled.x, 400, accuracy: 0.001)
        XCTAssertEqual(scaled.y, 150, accuracy: 0.001)
    }

    func testNormalizedPointFromCGPoint() {
        let cgPoint = CGPoint(x: 200, y: 150)
        let size = CGSize(width: 800, height: 600)

        let normalized = NormalizedPoint.normalized(from: cgPoint, in: size)

        XCTAssertEqual(normalized.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.25, accuracy: 0.001)
    }

    func testNormalizedPointDistance() {
        let p1 = NormalizedPoint(x: 0, y: 0)
        let p2 = NormalizedPoint(x: 0.3, y: 0.4)

        let distance = p1.distance(to: p2)

        XCTAssertEqual(distance, 0.5, accuracy: 0.001) // 3-4-5 triangle
    }

    // MARK: - NormalizedRect Tests

    func testNormalizedRectScaling() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let size = CGSize(width: 1000, height: 500)

        let scaled = rect.scaled(to: size)

        XCTAssertEqual(scaled.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(scaled.origin.y, 100, accuracy: 0.001)
        XCTAssertEqual(scaled.width, 500, accuracy: 0.001)
        XCTAssertEqual(scaled.height, 150, accuracy: 0.001)
    }

    func testNormalizedRectFromCGRect() {
        let cgRect = CGRect(x: 200, y: 100, width: 400, height: 200)
        let size = CGSize(width: 1000, height: 500)

        let normalized = NormalizedRect.normalized(from: cgRect, in: size)

        XCTAssertEqual(normalized.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(normalized.width, 0.4, accuracy: 0.001)
        XCTAssertEqual(normalized.height, 0.4, accuracy: 0.001)
    }

    func testNormalizedRectFromTwoPoints() {
        let p1 = NormalizedPoint(x: 0.1, y: 0.2)
        let p2 = NormalizedPoint(x: 0.6, y: 0.5)

        let rect = NormalizedRect(from: p1, to: p2)

        XCTAssertEqual(rect.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(rect.height, 0.3, accuracy: 0.001)
    }

    func testNormalizedRectContainsPoint() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)

        // Inside
        XCTAssertTrue(rect.contains(NormalizedPoint(x: 0.3, y: 0.35)))
        // On edge
        XCTAssertTrue(rect.contains(NormalizedPoint(x: 0.1, y: 0.2)))
        // Outside
        XCTAssertFalse(rect.contains(NormalizedPoint(x: 0.05, y: 0.35)))
        XCTAssertFalse(rect.contains(NormalizedPoint(x: 0.7, y: 0.35)))
    }

    // MARK: - ShapeStyle Tests

    func testShapeStyleColorComponents() {
        let style = ShapeStyle(strokeColor: 0xFF6B35FF, strokeWidth: 3, fillColor: nil)

        XCTAssertEqual(style.strokeRed, 1.0, accuracy: 0.01)
        XCTAssertEqual(style.strokeGreen, 0.42, accuracy: 0.01)
        XCTAssertEqual(style.strokeBlue, 0.21, accuracy: 0.01)
        XCTAssertEqual(style.strokeAlpha, 1.0, accuracy: 0.01)
    }

    func testShapeStyleRGBA() {
        let color = ShapeStyle.rgba(r: 1.0, g: 0.5, b: 0.25, a: 0.75)

        XCTAssertEqual((color >> 24) & 0xFF, 255) // R
        XCTAssertEqual((color >> 16) & 0xFF, 127, accuracy: 1) // G
        XCTAssertEqual((color >> 8) & 0xFF, 63, accuracy: 1) // B
        XCTAssertEqual(color & 0xFF, 191, accuracy: 1) // A
    }

    // MARK: - AnnotationShape Tests

    func testAnnotationShapeRectangleId() {
        let id = UUID()
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let shape = AnnotationShape.rectangle(id: id, rect: rect, style: .defaultRectangle)

        XCTAssertEqual(shape.id, id)
    }

    func testAnnotationShapeBoundingRect() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let shape = AnnotationShape.rectangle(id: UUID(), rect: rect, style: .defaultRectangle)

        let bounds = shape.boundingRect

        XCTAssertEqual(bounds.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(bounds.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 0.3, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 0.4, accuracy: 0.001)
    }

    func testAnnotationShapeArrowBoundingRect() {
        let from = NormalizedPoint(x: 0.2, y: 0.3)
        let to = NormalizedPoint(x: 0.5, y: 0.6)
        let shape = AnnotationShape.arrow(id: UUID(), from: from, to: to, style: .defaultArrow)

        let bounds = shape.boundingRect

        // Should contain both points with some padding for stroke
        XCTAssertLessThan(bounds.x, 0.2)
        XCTAssertLessThan(bounds.y, 0.3)
        XCTAssertGreaterThan(bounds.x + bounds.width, 0.5)
        XCTAssertGreaterThan(bounds.y + bounds.height, 0.6)
    }

    func testAnnotationShapeContainsPoint() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let shape = AnnotationShape.rectangle(id: UUID(), rect: rect, style: .defaultRectangle)

        // Inside
        XCTAssertTrue(shape.contains(point: NormalizedPoint(x: 0.25, y: 0.4)))
        // Outside (with tolerance)
        XCTAssertFalse(shape.contains(point: NormalizedPoint(x: 0.5, y: 0.7)))
    }

    // MARK: - AnnotationSet Tests

    func testAnnotationSetEmpty() {
        let set = AnnotationSet()

        XCTAssertTrue(set.isEmpty)
        XCTAssertTrue(set.shapes.isEmpty)
        XCTAssertNil(set.cropRegion)
    }

    func testAnnotationSetNotEmpty() {
        let shape = AnnotationShape.rectangle(
            id: UUID(),
            rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            style: .defaultRectangle
        )
        let set = AnnotationSet(shapes: [shape])

        XCTAssertFalse(set.isEmpty)
        XCTAssertEqual(set.shapes.count, 1)
    }

    // MARK: - Serialization Tests

    func testAnnotationSetCodable() throws {
        let original = AnnotationSet(
            shapes: [
                .rectangle(
                    id: UUID(),
                    rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                    style: ShapeStyle(strokeColor: 0xFF0000FF, strokeWidth: 5, fillColor: 0x00FF0080)
                ),
                .ellipse(
                    id: UUID(),
                    rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                    style: .defaultEllipse
                ),
                .arrow(
                    id: UUID(),
                    from: NormalizedPoint(x: 0.1, y: 0.1),
                    to: NormalizedPoint(x: 0.5, y: 0.5),
                    style: .defaultArrow
                ),
                .freeform(
                    id: UUID(),
                    points: [
                        NormalizedPoint(x: 0.1, y: 0.1),
                        NormalizedPoint(x: 0.2, y: 0.15),
                        NormalizedPoint(x: 0.3, y: 0.12)
                    ],
                    style: .defaultFreeform
                ),
                .text(
                    id: UUID(),
                    position: NormalizedPoint(x: 0.5, y: 0.8),
                    content: "Test label",
                    style: .default
                )
            ],
            cropRegion: NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnnotationSet.self, from: data)

        XCTAssertEqual(decoded.shapes.count, 5)
        XCTAssertNotNil(decoded.cropRegion)
        XCTAssertEqual(Double(decoded.cropRegion?.width ?? 0), 0.9, accuracy: 0.001)
    }

    func testAnnotationSetJSONRoundtrip() throws {
        let shape = AnnotationShape.rectangle(
            id: UUID(),
            rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            style: .defaultRectangle
        )
        let original = AnnotationSet(shapes: [shape])

        let json = try JSONEncoder().encode(original)
        let jsonString = String(data: json, encoding: .utf8)!
        let decoded = try JSONDecoder().decode(AnnotationSet.self, from: jsonString.data(using: .utf8)!)

        XCTAssertEqual(decoded.shapes.count, 1)
    }

    // MARK: - AnnotationRecord Tests

    func testAnnotationRecordCreation() {
        let itemId = UUID()
        let annotationSet = AnnotationSet(shapes: [
            .rectangle(
                id: UUID(),
                rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                style: .defaultRectangle
            )
        ])

        let record = AnnotationRecord(
            itemId: itemId,
            mediaFileIndex: 1,
            annotationSet: annotationSet
        )

        XCTAssertEqual(record.itemId, itemId)
        XCTAssertEqual(record.mediaFileIndex, 1)
        XCTAssertFalse(record.annotationsJSON.isEmpty)
    }

    func testAnnotationRecordToAnnotationSet() {
        let annotationSet = AnnotationSet(shapes: [
            .ellipse(
                id: UUID(),
                rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                style: .defaultEllipse
            )
        ])

        let record = AnnotationRecord(
            itemId: UUID(),
            mediaFileIndex: 0,
            annotationSet: annotationSet
        )

        let recovered = record.toAnnotationSet()

        XCTAssertEqual(recovered.shapes.count, 1)
        if case .ellipse(_, let rect, _) = recovered.shapes[0] {
            XCTAssertEqual(rect.x, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected ellipse shape")
        }
    }

    // MARK: - Database Tests

    func testAnnotationRecordDatabaseRoundtrip() async throws {
        let fixture = try await ProductionAssetFixture()
        defer { fixture.cleanUp() }
        let dbQueue = fixture.database

        try await dbQueue.write { db in
            let itemId = UUID()
            try fixture.insertItem(itemId, in: db)
            let annotationSet = AnnotationSet(shapes: [
                .rectangle(
                    id: UUID(),
                    rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                    style: .defaultRectangle
                ),
                .arrow(
                    id: UUID(),
                    from: NormalizedPoint(x: 0.1, y: 0.1),
                    to: NormalizedPoint(x: 0.5, y: 0.5),
                    style: .defaultArrow
                )
            ])

            let record = AnnotationRecord(
                itemId: itemId,
                mediaFileIndex: 0,
                annotationSet: annotationSet
            )

            try record.upsert(db: db)

            // Fetch back
            let fetched = try AnnotationRecord.fetch(db: db, itemId: itemId, mediaFileIndex: 0)
            XCTAssertNotNil(fetched)

            let recovered = fetched?.toAnnotationSet()
            XCTAssertEqual(recovered?.shapes.count, 2)
        }
    }

    func testAnnotationRecordUpsert() async throws {
        let fixture = try await ProductionAssetFixture()
        defer { fixture.cleanUp() }
        let dbQueue = fixture.database

        try await dbQueue.write { db in
            let itemId = UUID()
            try fixture.insertItem(itemId, in: db)

            // Insert first
            let record1 = AnnotationRecord(
                itemId: itemId,
                mediaFileIndex: 0,
                annotationSet: AnnotationSet(shapes: [
                    .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), style: .defaultRectangle)
                ])
            )
            try record1.upsert(db: db)

            // Upsert with same itemId/mediaFileIndex should update
            let record2 = AnnotationRecord(
                itemId: itemId,
                mediaFileIndex: 0,
                annotationSet: AnnotationSet(shapes: [
                    .ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse),
                    .arrow(id: UUID(), from: NormalizedPoint(x: 0, y: 0), to: NormalizedPoint(x: 1, y: 1), style: .defaultArrow)
                ])
            )
            try record2.upsert(db: db)

            // Should still have only 1 record
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations")
            XCTAssertEqual(count, 1)

            // Fetch and verify updated content
            let fetched = try AnnotationRecord.fetch(db: db, itemId: itemId, mediaFileIndex: 0)
            XCTAssertEqual(fetched?.toAnnotationSet().shapes.count, 2)
        }
    }

    func testAnnotationRecordDeleteAll() async throws {
        let fixture = try await ProductionAssetFixture()
        defer { fixture.cleanUp() }
        let dbQueue = fixture.database

        try await dbQueue.write { db in
            let itemId = UUID()
            try fixture.insertItem(itemId, in: db)

            // Insert multiple file indices
            for i in 0..<3 {
                let record = AnnotationRecord(
                    itemId: itemId,
                    mediaFileIndex: i,
                    annotationSet: AnnotationSet(shapes: [
                        .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), style: .defaultRectangle)
                    ])
                )
                try record.upsert(db: db)
            }

            // Insert for different item
            let otherId = UUID()
            try fixture.insertItem(otherId, in: db)
            let otherRecord = AnnotationRecord(
                itemId: otherId,
                mediaFileIndex: 0,
                annotationSet: AnnotationSet(shapes: [])
            )
            try otherRecord.upsert(db: db)

            // Delete all for first item
            try AnnotationRecord.deleteAll(db: db, itemId: itemId)

            // Should have deleted 3 records, leaving 1
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations")
            XCTAssertEqual(count, 1)

            // The remaining record should be for otherId
            let remaining = try AnnotationRecord.fetchAll(db: db, itemId: otherId)
            XCTAssertEqual(remaining.count, 1)
        }
    }

    // MARK: - AnnotationTool Tests

    func testAnnotationToolProperties() {
        XCTAssertEqual(AnnotationTool.rectangle.displayName, "Rectangle")
        XCTAssertEqual(AnnotationTool.ellipse.displayName, "Circle")
        XCTAssertEqual(AnnotationTool.arrow.displayName, "Arrow")
        XCTAssertEqual(AnnotationTool.freeform.displayName, "Freeform")
        XCTAssertEqual(AnnotationTool.text.displayName, "Text")
        XCTAssertEqual(AnnotationTool.highlighter.displayName, "Highlighter")
        XCTAssertEqual(AnnotationTool.select.displayName, "Select")

        XCTAssertEqual(AnnotationTool.rectangle.systemImage, "rectangle")
        XCTAssertEqual(AnnotationTool.ellipse.systemImage, "circle")
    }

    func testAnnotationToolDefaultStyles() {
        XCTAssertEqual(AnnotationTool.rectangle.defaultStyle.strokeWidth, 3)
        XCTAssertEqual(AnnotationTool.highlighter.defaultStyle.strokeWidth, 20)
    }

    // MARK: - TextStyle Tests

    func testTextStyleDefaults() {
        let style = TextStyle.default

        XCTAssertEqual(style.fontSize, 16)
        XCTAssertEqual(style.fontWeight, .regular)
        XCTAssertNotNil(style.backgroundColor)
    }

    func testTextStyleColorComponents() {
        let style = TextStyle(textColor: 0xFF8800FF)

        XCTAssertEqual(style.textRed, 1.0, accuracy: 0.01)
        XCTAssertEqual(style.textGreen, 0.53, accuracy: 0.01)
        XCTAssertEqual(style.textBlue, 0, accuracy: 0.01)
        XCTAssertEqual(style.textAlpha, 1.0, accuracy: 0.01)
    }

}
