import XCTest
import Yams
@testable import MediaViewer

/// Exercises global tag deletion and its undo/redo against disposable database
/// and sidecar state; no live archive paths are used.
@MainActor
final class DeleteTagDefinitionActionTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!
    private var savedDefinitions: [TagDefinition] = []
    private var parent: TagDefinition!
    private var child: TagDefinition!
    private var unrelated: TagDefinition!
    private var parentOnlyID: UUID!
    private var parentAndChildID: UUID!
    private var childOnlyID: UUID!
    private var unrelatedOnlyID: UUID!

    override func setUp() {
        super.setUp()
        savedDefinitions = TagSettings.shared.definitions
    }

    override func tearDown() async throws {
        TagSettings.shared.definitions = savedDefinitions
        store = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testDeleteUndoRedoRestoresOnlyExactReferencesAndTagTree() async throws {
        try await prepareFixtures()
        let settings = TagSettings.shared
        let action = DeleteTagDefinitionAction(
            tag: parent,
            children: settings.children(of: parent.id),
            mediaStore: store
        )
        let undoStack = UndoStack()

        try await undoStack.performAction(action)

        XCTAssertEqual(Set(action.affectedItemIDs), Set([parentOnlyID, parentAndChildID]))
        XCTAssertNil(settings.definitions.first(where: { $0.id == parent.id }))
        XCTAssertEqual(settings.definitions.first(where: { $0.id == child.id })?.parentId, nil)
        XCTAssertEqual(settings.definitions.first(where: { $0.id == child.id })?.shortcutKey, child.shortcutKey)
        await store.writeBackQueue.flushNow()
        try await assertTags(["Other"], for: parentOnlyID)
        try await assertTags(["Child", "Other"], for: parentAndChildID)
        try await assertTags(["Child", "Other"], for: childOnlyID)
        try await assertTags(["Other"], for: unrelatedOnlyID)

        _ = try await undoStack.undo()

        XCTAssertEqual(settings.definitions.first(where: { $0.id == parent.id }), parent)
        XCTAssertEqual(settings.definitions.first(where: { $0.id == child.id }), child)
        XCTAssertEqual(settings.definitions.first(where: { $0.id == unrelated.id }), unrelated)
        await store.writeBackQueue.flushNow()
        try await assertTags(["Parent", "Other"], for: parentOnlyID)
        try await assertTags(["Parent", "Child", "Other"], for: parentAndChildID)
        try await assertTags(["Child", "Other"], for: childOnlyID)
        try await assertTags(["Other"], for: unrelatedOnlyID)

        _ = try await undoStack.redo()

        XCTAssertEqual(Set(action.affectedItemIDs), Set([parentOnlyID, parentAndChildID]))
        XCTAssertNil(settings.definitions.first(where: { $0.id == parent.id }))
        XCTAssertEqual(settings.definitions.first(where: { $0.id == child.id })?.parentId, nil)
        await store.writeBackQueue.flushNow()
        try await assertTags(["Other"], for: parentOnlyID)
        try await assertTags(["Child", "Other"], for: parentAndChildID)
        try await assertTags(["Child", "Other"], for: childOnlyID)
        try await assertTags(["Other"], for: unrelatedOnlyID)
    }

    private func prepareFixtures() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeleteTagDefinition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)

        var keep = TagDefinition(name: "Other")
        keep.sortOrder = 0
        keep.shortcutKey = "k"
        unrelated = keep

        var root = TagDefinition(name: "Parent")
        root.sortOrder = 1
        root.shortcutKey = "p"
        parent = root

        var nested = TagDefinition(name: "Child")
        nested.parentId = root.id
        nested.sortOrder = 0
        nested.shortcutKey = "c"
        child = nested

        TagSettings.shared.definitions = [keep, root, nested]

        let fixtures: [(String, [String])] = [
            ("parent-only", ["Parent", "Other"]),
            ("parent-and-child", ["Parent", "Child", "Other"]),
            ("child-only", ["Child", "Other"]),
            ("unrelated-only", ["Other"])
        ]
        var items: [MediaItem] = []
        for (name, tags) in fixtures {
            let id = UUID()
            switch name {
            case "parent-only": parentOnlyID = id
            case "parent-and-child": parentAndChildID = id
            case "child-only": childOnlyID = id
            default: unrelatedOnlyID = id
            }
            let metadataFile = directory.appendingPathComponent("\(name).md")
            let serializedTags = tags.map { "  - \($0)" }.joined(separator: "\n")
            let frontmatter = """
            ---
            source: https://example.com/\(name)
            platform: local
            author: \(name)
            tags:
            \(serializedTags)
            ---
            """
            try frontmatter.write(to: metadataFile, atomically: true, encoding: .utf8)
            let item = SampleData.createMediaItem(
                id: id,
                basePath: directory,
                metadataFile: metadataFile,
                mediaFiles: [directory.appendingPathComponent("\(name).jpg")],
                source: "https://example.com/\(name)",
                platform: "local",
                author: name,
                tags: tags
            )
            items.append(item)
        }
        try await store.insertItemsBatch(items)
    }

    private func assertTags(_ expected: [String], for id: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fetched = try await store.fetchItem(id: id)
        let item = try XCTUnwrap(fetched, file: file, line: line)
        XCTAssertEqual(Set(item.metadata.tags), Set(expected), file: file, line: line)

        let content = try String(contentsOf: item.metadataFile, encoding: .utf8)
        let yamlText = try FrontmatterWriter.parseBoundaries(content).yamlText
        let yaml = try XCTUnwrap(Yams.load(yaml: yamlText) as? [String: Any], file: file, line: line)
        XCTAssertEqual(Set(yaml["tags"] as? [String] ?? []), Set(expected), file: file, line: line)
    }
}
