import XCTest
import Yams
@testable import MediaViewer

/// Large-vocabulary tag search plus Settings tree deletion (counted scope,
/// subtree delete, undo/redo) against disposable database and sidecar state.
@MainActor
final class TagManagementWorkflowTests: XCTestCase {
    private var directory: URL?
    private var database: DatabaseManager?
    private var store: MediaStore?
    private var savedDefinitions: [TagDefinition] = []

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

    // MARK: - Search over 200+ tags

    func testSearchIsCanonicalPathAwareAndRanksNameHitsBeforePathHits() {
        let vocabulary = makeLargeVocabulary()
        XCTAssertGreaterThanOrEqual(vocabulary.definitions.count, 200)

        // Case and Unicode composition variants find the same tag.
        let cafe = TagDefinitionSearch.matches(query: "CAFE\u{301} SCENE", in: vocabulary.definitions)
        XCTAssertEqual(cafe.first?.definition.id, vocabulary.cafe.id)
        XCTAssertEqual(cafe.first?.score, 0)

        // Identically named leaves stay distinguishable by their ancestor path.
        let reds = TagDefinitionSearch.matches(query: "red", in: vocabulary.definitions)
            .filter { $0.definition.name == "Red" }
        XCTAssertEqual(Set(reds.map(\.ancestorLabel)), ["Colors", "Flags › Nautical"])

        // A branch name finds the branch itself first, then its descendants by path only.
        let colors = TagDefinitionSearch.matches(query: "colors", in: vocabulary.definitions)
        XCTAssertEqual(colors.first?.definition.id, vocabulary.colors.id)
        XCTAssertFalse(colors.first?.matchedPathOnly ?? true)
        let pathHits = colors.filter(\.matchedPathOnly)
        XCTAssertEqual(Set(pathHits.map(\.definition.name)), ["Red", "Teal"])
        XCTAssertTrue(pathHits.allSatisfy { $0.score >= 1_000 })

        // Loose subsequence hits never come from the ancestor path.
        let loose = TagDefinitionSearch.matches(query: "clr", in: vocabulary.definitions)
        XCTAssertFalse(loose.contains { $0.matchedPathOnly })

        XCTAssertTrue(TagDefinitionSearch.matches(query: "   ", in: vocabulary.definitions).isEmpty)
        XCTAssertEqual(TagDefinitionSearch.matches(query: "topic", in: vocabulary.definitions, limit: 8).count, 8)
        XCTAssertFalse(
            TagDefinitionSearch.matches(query: "red", in: vocabulary.definitions, excluding: [vocabulary.colorsRed.id])
                .contains { $0.definition.id == vocabulary.colorsRed.id }
        )
    }

    func testTreeVisibilityKeepsEveryAncestorOfAHit() {
        let vocabulary = makeLargeVocabulary()
        let none = TagDefinitionSearch.treeVisibility(query: "zzqx", in: vocabulary.definitions)
        XCTAssertTrue(none.matchedIDs.isEmpty && none.visibleIDs.isEmpty)

        let deep = TagDefinitionSearch.treeVisibility(query: "Red", in: vocabulary.definitions)
        XCTAssertTrue(deep.matchedIDs.contains(vocabulary.nauticalRed.id))
        XCTAssertTrue(deep.visibleIDs.isSuperset(of: [vocabulary.flags.id, vocabulary.nautical.id, vocabulary.nauticalRed.id]))
        XCTAssertFalse(deep.matchedIDs.contains(vocabulary.flags.id))
        XCTAssertFalse(deep.visibleIDs.contains(vocabulary.cafe.id))
    }

    func testTypedNamesResolveToExistingSpellingAndListsStayCanonicallyUnique() {
        let vocabulary = makeLargeVocabulary()
        XCTAssertEqual(
            TagDefinitionSearch.resolvedDisplayName(for: "  café scene ", in: vocabulary.definitions),
            "Café Scene"
        )
        XCTAssertEqual(TagDefinitionSearch.resolvedDisplayName(for: " New Thing ", in: vocabulary.definitions), "New Thing")
        XCTAssertNil(TagDefinitionSearch.resolvedDisplayName(for: " \n", in: vocabulary.definitions))

        var tags = ["Café Scene"]
        XCTAssertFalse(TagDefinitionSearch.appendUnique("CAFE\u{301} scene", to: &tags))
        XCTAssertTrue(TagDefinitionSearch.appendUnique("Other", to: &tags))
        XCTAssertFalse(TagDefinitionSearch.appendUnique("  ", to: &tags))
        XCTAssertEqual(tags, ["Café Scene", "Other"])
        XCTAssertEqual(TagDefinitionSearch.uniqued([" Red ", "red", "RED", "Teal"]), ["Red", "Teal"])
    }

    // MARK: - Settings tree deletion

    func testDeletionRequestCountsExactReferencesForTagAndDescendants() async throws {
        let fixture = try await prepareSubtreeFixture()
        let request = try await TagTreeDeletionRequest.counted(
            tag: fixture.root,
            settings: TagSettings.shared,
            mediaStore: try XCTUnwrap(store)
        )

        XCTAssertEqual(request.children.map(\.id), [fixture.child.id])
        XCTAssertEqual(Set(request.descendants.map(\.id)), [fixture.child.id, fixture.grandchild.id])
        XCTAssertEqual(request.itemCount, 2)                   // rootOnly, all
        XCTAssertEqual(request.descendantAssignmentCount, 3)   // child: all, childOnly; grandchild: all
        XCTAssertTrue(request.confirmationMessage.contains("Removes ‘Root’ from 2 items."))
        XCTAssertTrue(request.confirmationMessage.contains("3 tag assignments"))
    }

    func testSubtreeDeleteUndoRedoRestoresExactReferencesAndTreePositions() async throws {
        let fixture = try await prepareSubtreeFixture()
        let settings = TagSettings.shared
        let action = DeleteTagSubtreeAction(
            root: fixture.root,
            descendants: settings.allDescendants(of: fixture.root.id),
            mediaStore: try XCTUnwrap(store)
        )
        let undoStack = UndoStack()

        try await undoStack.performAction(action)

        XCTAssertEqual(Set(action.affectedItemIDsByTag[fixture.root.id] ?? []), [fixture.rootOnlyID, fixture.allID])
        XCTAssertEqual(Set(action.affectedItemIDsByTag[fixture.child.id] ?? []), [fixture.allID, fixture.childOnlyID])
        XCTAssertEqual(settings.definitions.map(\.id), [fixture.other.id])
        try await assertTags(["Other"], for: fixture.rootOnlyID)
        try await assertTags(["Other"], for: fixture.allID)
        try await assertTags(["Other"], for: fixture.childOnlyID)
        try await assertTags(["Other"], for: fixture.otherOnlyID)

        _ = try await undoStack.undo()

        // Exact snapshots come back (hierarchy, color, shortcut) with no auto-created copies.
        XCTAssertEqual(settings.definitions.count, 4)
        for original in [fixture.other, fixture.root, fixture.child, fixture.grandchild] {
            XCTAssertEqual(settings.definitions.first(where: { $0.id == original.id }), original)
        }
        try await assertTags(["Root", "Other"], for: fixture.rootOnlyID)
        try await assertTags(["Root", "Child", "Grandchild", "Other"], for: fixture.allID)
        try await assertTags(["Child", "Other"], for: fixture.childOnlyID)
        try await assertTags(["Other"], for: fixture.otherOnlyID)

        _ = try await undoStack.redo()

        XCTAssertEqual(settings.definitions.map(\.id), [fixture.other.id])
        try await assertTags(["Other"], for: fixture.allID)
        try await assertTags(["Other"], for: fixture.childOnlyID)
    }

    func testConfirmedDeletionNeverBroadensWhenTheTreeChangesWhileTheDialogIsOpen() {
        let settings = TagSettings.shared
        var root = TagDefinition(name: "Root")
        root.sortOrder = 0
        var child = TagDefinition(name: "Child")
        child.parentId = root.id
        var grandchild = TagDefinition(name: "Grandchild")
        grandchild.parentId = child.id
        let base = [root, child, grandchild]
        let request = TagTreeDeletionRequest(
            tag: root,
            children: [child],
            descendants: [child, grandchild],
            itemCount: 1,
            descendantAssignmentCount: 2
        )

        // Cosmetic edits keep the request valid and hand back the live copies.
        var recolored = child
        recolored.colorHex = 0x123456
        settings.definitions = [root, recolored, grandchild]
        XCTAssertEqual(
            request.resolve(in: settings),
            .current(tag: root, children: [recolored], descendants: [recolored, grandchild])
        )

        // A child added under the scope makes the request stale instead of deleting it too.
        var late = TagDefinition(name: "Late")
        late.parentId = grandchild.id
        settings.definitions = base + [late]
        XCTAssertEqual(request.resolve(in: settings), .changed(root))

        // Renaming or moving a tag in scope changes what would be removed.
        var renamed = grandchild
        renamed.name = "Renamed"
        settings.definitions = [root, child, renamed]
        XCTAssertEqual(request.resolve(in: settings), .changed(root))

        var moved = grandchild
        moved.parentId = nil
        settings.definitions = [root, child, moved]
        XCTAssertEqual(request.resolve(in: settings), .changed(root))

        // Keep-children placement depends on the root's parent, so a moved root is stale too.
        let newParent = TagDefinition(name: "New Parent")
        var movedRoot = root
        movedRoot.parentId = newParent.id
        settings.definitions = [newParent, movedRoot, child, grandchild]
        XCTAssertEqual(request.resolve(in: settings), .changed(movedRoot))

        // A root deleted meanwhile is a no-op, never a fallback to the captured copy.
        settings.definitions = [child, grandchild]
        XCTAssertEqual(request.resolve(in: settings), .missing)
    }

    func testRestoringReattachesToRecreatedTagAndDropsCollidingShortcut() {
        var root = TagDefinition(name: "Root")
        root.shortcutKey = "r"
        var child = TagDefinition(name: "Child")
        child.parentId = root.id
        child.shortcutKey = "w"

        // Meanwhile the user recreated "root" and gave a new sibling the "w" key.
        let recreated = TagDefinition(name: "root")
        var sibling = TagDefinition(name: "Sibling")
        sibling.parentId = recreated.id
        sibling.shortcutKey = "w"

        let restored = DeleteTagSubtreeAction.restoring([root, child], into: [recreated, sibling])

        XCTAssertEqual(restored.filter { TagCanonicalizer.key($0.name) == "root" }.map(\.id), [recreated.id])
        let restoredChild = restored.first { $0.id == child.id }
        XCTAssertEqual(restoredChild?.parentId, recreated.id)
        XCTAssertNil(restoredChild?.shortcutKey)
        XCTAssertEqual(restored.first { $0.id == sibling.id }?.shortcutKey, "w")

        // A parent that no longer exists at all restores the child at the top level.
        let orphan = DeleteTagSubtreeAction.restoring([child], into: [])
        XCTAssertEqual(orphan.first?.parentId, nil)
        XCTAssertEqual(orphan.first?.shortcutKey, "w")
    }

    // MARK: - Fixtures

    private struct Vocabulary {
        var definitions: [TagDefinition]
        let colors: TagDefinition
        let colorsRed: TagDefinition
        let flags: TagDefinition
        let nautical: TagDefinition
        let nauticalRed: TagDefinition
        let cafe: TagDefinition
    }

    private func makeLargeVocabulary() -> Vocabulary {
        var definitions: [TagDefinition] = []
        func add(_ name: String, parent: TagDefinition? = nil) -> TagDefinition {
            var tag = TagDefinition(name: name)
            tag.parentId = parent?.id
            tag.sortOrder = definitions.filter { $0.parentId == parent?.id }.count
            definitions.append(tag)
            return tag
        }
        for group in 0..<10 {
            let root = add(String(format: "Group %02d", group))
            for topic in 0..<22 {
                _ = add(String(format: "Topic %02d-%02d with a deliberately long descriptive label", group, topic), parent: root)
            }
        }
        let colors = add("Colors")
        let colorsRed = add("Red", parent: colors)
        _ = add("Teal", parent: colors)
        let flags = add("Flags")
        let nautical = add("Nautical", parent: flags)
        let nauticalRed = add("Red", parent: nautical)
        let cafe = add("Café Scene")
        return Vocabulary(
            definitions: definitions,
            colors: colors,
            colorsRed: colorsRed,
            flags: flags,
            nautical: nautical,
            nauticalRed: nauticalRed,
            cafe: cafe
        )
    }

    private struct SubtreeFixture {
        let other: TagDefinition
        let root: TagDefinition
        let child: TagDefinition
        let grandchild: TagDefinition
        let rootOnlyID: UUID
        let allID: UUID
        let childOnlyID: UUID
        let otherOnlyID: UUID
    }

    private func prepareSubtreeFixture() async throws -> SubtreeFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagManagementWorkflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        self.database = database
        let store = MediaStore(database: database)
        self.store = store

        var other = TagDefinition(name: "Other")
        other.sortOrder = 0
        other.shortcutKey = "o"
        var root = TagDefinition(name: "Root")
        root.sortOrder = 1
        root.shortcutKey = "r"
        root.colorHex = 0xFF6B35
        var child = TagDefinition(name: "Child")
        child.parentId = root.id
        child.shortcutKey = "w"
        var grandchild = TagDefinition(name: "Grandchild")
        grandchild.parentId = child.id
        TagSettings.shared.definitions = [other, root, child, grandchild]

        let fixtures: [(String, [String])] = [
            ("root-only", ["Root", "Other"]),
            ("all", ["Root", "Child", "Grandchild", "Other"]),
            ("child-only", ["Child", "Other"]),
            ("other-only", ["Other"])
        ]
        var ids: [String: UUID] = [:]
        var items: [MediaItem] = []
        for (name, tags) in fixtures {
            let id = UUID()
            ids[name] = id
            let metadataFile = directory.appendingPathComponent("\(name).md")
            let frontmatter = """
            ---
            source: https://example.com/\(name)
            platform: local
            author: \(name)
            tags:
            \(tags.map { "  - \($0)" }.joined(separator: "\n"))
            ---
            """
            try frontmatter.write(to: metadataFile, atomically: true, encoding: .utf8)
            items.append(SampleData.createMediaItem(
                id: id,
                basePath: directory,
                metadataFile: metadataFile,
                mediaFiles: [directory.appendingPathComponent("\(name).jpg")],
                source: "https://example.com/\(name)",
                platform: "local",
                author: name,
                tags: tags
            ))
        }
        try await store.insertItemsBatch(items)

        return SubtreeFixture(
            other: other,
            root: root,
            child: child,
            grandchild: grandchild,
            rootOnlyID: try XCTUnwrap(ids["root-only"]),
            allID: try XCTUnwrap(ids["all"]),
            childOnlyID: try XCTUnwrap(ids["child-only"]),
            otherOnlyID: try XCTUnwrap(ids["other-only"])
        )
    }

    private func assertTags(_ expected: [String], for id: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
        let store = try XCTUnwrap(store, file: file, line: line)
        await store.writeBackQueue.flushNow()
        let fetched = try await store.fetchItem(id: id)
        let item = try XCTUnwrap(fetched, file: file, line: line)
        XCTAssertEqual(Set(item.metadata.tags), Set(expected), file: file, line: line)

        let content = try String(contentsOf: item.metadataFile, encoding: .utf8)
        let yamlText = try FrontmatterWriter.parseBoundaries(content).yamlText
        let yaml = try XCTUnwrap(Yams.load(yaml: yamlText) as? [String: Any], file: file, line: line)
        XCTAssertEqual(Set(yaml["tags"] as? [String] ?? []), Set(expected), file: file, line: line)
    }
}
