import Foundation
@testable import MediaViewer

/// Loads test fixtures from the Fixtures directory.
enum FixtureLoader {
    /// Load a JSON fixture file and decode as AnnotationSet
    static func loadAnnotationSet(named name: String) throws -> AnnotationSet {
        let data = try loadJSON(named: name)
        return try JSONDecoder().decode(AnnotationSet.self, from: data)
    }

    /// Load raw JSON data from a fixture file
    static func loadJSON(named name: String) throws -> Data {
        // #filePath gives us the source location of this file at compile time
        let thisFile = URL(fileURLWithPath: #filePath)
        let fixturesDir = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
        let fileURL = fixturesDir.appendingPathComponent(name)
        return try Data(contentsOf: fileURL)
    }

    /// Build a sample multi-layer AnnotationSet programmatically
    static func sampleMultiLayerSet() -> AnnotationSet {
        var set = AnnotationSet()

        // Layer 1: Shapes
        let _ = set.addLayer(name: "Shapes")
        set.addShape(.rectangle(
            id: UUID(),
            rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
            style: .defaultRectangle
        ))
        set.addShape(.ellipse(
            id: UUID(),
            rect: NormalizedRect(x: 0.5, y: 0.3, width: 0.2, height: 0.2),
            style: .defaultEllipse
        ))

        // Layer 2: Text
        let _ = set.addLayer(name: "Text")
        set.addShape(.text(
            id: UUID(),
            position: NormalizedPoint(x: 0.5, y: 0.8),
            content: "Sample text",
            style: .default
        ))

        // Layer 3: Masks
        let _ = set.addLayer(name: "Masks")
        set.addShape(.mask(
            id: UUID(),
            maskData: Data([0xFF, 0x00, 0xFF]),
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            blendMode: .maskRemove,
            opacity: 1.0,
            featherRadius: 2.0
        ))

        return set
    }
}
