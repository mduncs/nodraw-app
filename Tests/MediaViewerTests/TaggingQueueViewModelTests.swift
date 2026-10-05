import XCTest
import Combine
@testable import MediaViewer

@MainActor
final class TaggingQueueViewModelTests: XCTestCase {
    private let tagSettings = TagSettings.shared
    private var savedDefinitions: [TagDefinition] = []
    private var savedResumeItemID: UUID?

    override func setUp() {
        super.setUp()
        savedDefinitions = tagSettings.definitions
        savedResumeItemID = SettingsStore.shared.taggingQueueResumeItemID
    }

    override func tearDown() {
        tagSettings.definitions = savedDefinitions
        SettingsStore.shared.taggingQueueResumeItemID = savedResumeItemID
        super.tearDown()
    }

    func testNewDefinitionAppearsWithoutChangingQueuePositionOrItem() async {
        let existing = makeTag("existing", order: 0)
        tagSettings.definitions = [existing]

        let viewModel = makeActiveViewModel()
        let item = makeItem()
        viewModel.currentIndex = 4
        viewModel.totalCount = 12
        viewModel.currentItem = item
        setRootLevel(on: viewModel)

        let created = makeTag("created", order: 1)
        tagSettings.definitions = [existing, created]

        await waitForCurrentLevel(on: viewModel) { nodes in
            nodes.contains { $0.id == created.id }
        }

        XCTAssertEqual(viewModel.currentLevel.map(\.id), [existing.id, created.id])
        XCTAssertEqual(viewModel.currentIndex, 4)
        XCTAssertEqual(viewModel.totalCount, 12)
        XCTAssertEqual(viewModel.currentItem, item)
    }

    func testRefreshPreservesValidBreadcrumbAndOnlyCurrentLeafSelections() async {
        let parent = makeTag("parent", order: 0)
        let keep = makeTag("keep", parent: parent.id, order: 0)
        let remove = makeTag("remove", parent: parent.id, order: 1)
        let becomesParent = makeTag("becomes-parent", parent: parent.id, order: 2)
        tagSettings.definitions = [parent, keep, remove, becomesParent]

        let viewModel = makeActiveViewModel()
        setRootLevel(on: viewModel)
        guard let parentNode = viewModel.currentLevel.first(where: { $0.id == parent.id }) else {
            return XCTFail("Expected parent at the root")
        }
        viewModel.selectNode(parentNode)
        viewModel.selectedLeafTags = ["keep", "remove", "becomes-parent", "missing"]

        var renamedParent = parent
        renamedParent.name = "renamed-parent"
        let newLeaf = makeTag("new-leaf", parent: parent.id, order: 3)
        let childOfSelected = makeTag("child", parent: becomesParent.id, order: 0)
        tagSettings.definitions = [renamedParent, keep, becomesParent, newLeaf, childOfSelected]

        await waitForCurrentLevel(on: viewModel) { nodes in
            nodes.contains { $0.id == newLeaf.id }
        }

        XCTAssertEqual(viewModel.navigationPath.map(\.id), [parent.id])
        XCTAssertEqual(viewModel.navigationPath.first?.name, "renamed-parent")
        XCTAssertTrue(viewModel.currentLevel.contains { $0.id == newLeaf.id })
        XCTAssertFalse(viewModel.currentLevel.contains { $0.id == childOfSelected.id })
        XCTAssertTrue(viewModel.currentLevel.contains { $0.id == becomesParent.id && !$0.isLeaf })
        XCTAssertEqual(viewModel.selectedLeafTags, ["keep"])
    }

    func testIncompatibleMovedPathFallsBackToDeepestValidBreadcrumb() async {
        let root = makeTag("root", order: 0)
        let branch = makeTag("branch", parent: root.id, order: 0)
        let leaf = makeTag("leaf", parent: branch.id, order: 0)
        tagSettings.definitions = [root, branch, leaf]

        let viewModel = makeActiveViewModel()
        setRootLevel(on: viewModel)
        guard let rootNode = viewModel.currentLevel.first(where: { $0.id == root.id }) else {
            return XCTFail("Expected root tag")
        }
        viewModel.selectNode(rootNode)
        guard let branchNode = viewModel.currentLevel.first(where: { $0.id == branch.id }) else {
            return XCTFail("Expected branch under root")
        }
        viewModel.selectNode(branchNode)
        XCTAssertEqual(viewModel.navigationPath.map(\.id), [root.id, branch.id])

        var movedBranch = branch
        let otherRoot = makeTag("other-root", order: 1)
        movedBranch.parentId = otherRoot.id
        tagSettings.definitions = [root, movedBranch, leaf, otherRoot]

        await waitForNavigationPath(on: viewModel, ids: [root.id])

        XCTAssertEqual(viewModel.navigationPath.map(\.id), [root.id])
        XCTAssertTrue(viewModel.currentLevel.isEmpty)
    }

    func testPendingLeafSelectionsSurviveBackAndBreadcrumbNavigationAcrossBranches() {
        let firstBranch = makeTag("first-branch", order: 0)
        let firstLeaf = makeTag("first-leaf", parent: firstBranch.id, order: 0)
        let secondBranch = makeTag("second-branch", order: 1)
        let secondLeaf = makeTag("second-leaf", parent: secondBranch.id, order: 0)
        tagSettings.definitions = [firstBranch, firstLeaf, secondBranch, secondLeaf]

        let viewModel = makeActiveViewModel()
        setRootLevel(on: viewModel)

        guard let firstBranchNode = viewModel.currentLevel.first(where: { $0.id == firstBranch.id }) else {
            return XCTFail("Expected the first branch")
        }
        viewModel.selectNode(firstBranchNode)
        guard let firstLeafNode = viewModel.currentLevel.first(where: { $0.id == firstLeaf.id }) else {
            return XCTFail("Expected the first leaf")
        }
        viewModel.selectNode(firstLeafNode)

        viewModel.goBack()

        XCTAssertTrue(viewModel.navigationPath.isEmpty)
        XCTAssertEqual(viewModel.selectedLeafTags, ["first-leaf"])

        guard let secondBranchNode = viewModel.currentLevel.first(where: { $0.id == secondBranch.id }) else {
            return XCTFail("Expected the second branch")
        }
        viewModel.selectNode(secondBranchNode)
        guard let secondLeafNode = viewModel.currentLevel.first(where: { $0.id == secondLeaf.id }) else {
            return XCTFail("Expected the second leaf")
        }
        viewModel.selectNode(secondLeafNode)
        viewModel.jumpToLevel(-1)

        XCTAssertTrue(viewModel.navigationPath.isEmpty)
        XCTAssertEqual(viewModel.selectedLeafTags, ["first-leaf", "second-leaf"])

        // At root, Escape retains its existing clear-then-exit behavior.
        viewModel.goBack()
        XCTAssertTrue(viewModel.isActive)
        XCTAssertTrue(viewModel.selectedLeafTags.isEmpty)
    }

    func testKeyboardAndDirectNodeActivationUseTheSameLeafToggle() {
        let leaf = makeTag("leaf", order: 0)
        tagSettings.definitions = [leaf]

        let viewModel = makeActiveViewModel()
        setRootLevel(on: viewModel)
        guard let leafNode = viewModel.currentLevel.first else {
            return XCTFail("Expected a leaf node")
        }

        XCTAssertTrue(viewModel.handleKeyPress("1"))
        XCTAssertEqual(viewModel.selectedLeafTags, ["leaf"])

        // TaggingHUD chip clicks call selectNode(_:), the same path reached by handleKeyPress(_:).
        viewModel.selectNode(leafNode)
        XCTAssertTrue(viewModel.selectedLeafTags.isEmpty)
    }

    func testCreateTagAtRootMakesItVisibleAndImmediatelySelected() {
        tagSettings.definitions = []
        let viewModel = makeActiveViewModel()
        setRootLevel(on: viewModel)

        XCTAssertTrue(viewModel.createTag(named: "  New Tag  "))

        let created = tagSettings.definitions.first(where: { $0.name == "New Tag" })
        XCTAssertNotNil(created)
        XCTAssertNil(created?.parentId)
        XCTAssertTrue(viewModel.currentLevel.contains { $0.id == created?.id })
        XCTAssertEqual(viewModel.selectedLeafTags, ["New Tag"])
        XCTAssertNil(viewModel.tagCreationError)
    }

    func testCreateTagUsesCurrentBranchAndAppendsToItsChildren() {
        let branch = makeTag("branch", order: 0)
        let existing = makeTag("existing", parent: branch.id, order: 0)
        tagSettings.definitions = [branch, existing]

        let viewModel = makeActiveViewModel()
        setRootLevel(on: viewModel)
        guard let branchNode = viewModel.currentLevel.first(where: { $0.id == branch.id }) else {
            return XCTFail("Expected a branch node")
        }
        viewModel.selectNode(branchNode)

        XCTAssertTrue(viewModel.createTag(named: "Created"))

        guard let created = tagSettings.definitions.first(where: { $0.name == "Created" }) else {
            return XCTFail("Expected the created definition")
        }
        XCTAssertEqual(created.parentId, branch.id)
        XCTAssertEqual(created.sortOrder, 1)
        XCTAssertEqual(viewModel.navigationPath.map(\.id), [branch.id])
        XCTAssertTrue(viewModel.currentLevel.contains { $0.id == created.id })
        XCTAssertEqual(viewModel.selectedLeafTags, ["Created"])
    }

    func testCreateTagReportsEmptyAndDuplicateNamesWithoutMutation() {
        let existing = makeTag("existing", order: 0)
        tagSettings.definitions = [existing]

        let viewModel = makeActiveViewModel()
        setRootLevel(on: viewModel)

        XCTAssertFalse(viewModel.createTag(named: "   "))
        XCTAssertEqual(viewModel.tagCreationError, .emptyName)
        XCTAssertEqual(tagSettings.definitions, [existing])

        XCTAssertFalse(viewModel.createTag(named: " EXISTING "))
        XCTAssertEqual(viewModel.tagCreationError, .duplicateName("existing"))
        XCTAssertEqual(tagSettings.definitions, [existing])

        viewModel.clearTagCreationError()
        XCTAssertNil(viewModel.tagCreationError)
    }

    func testFocusArrowNavigationSynchronizesQueueCursorAndResetsStagedTagsBothDirections() {
        let branch = makeTag("branch", order: 0)
        let leaf = makeTag("leaf", parent: branch.id, order: 0)
        tagSettings.definitions = [branch, leaf]

        let items = [makeItem(), makeItem(), makeItem()]
        let viewModel = makeActiveViewModel()
        XCTAssertTrue(
            viewModel.synchronizeFocusedItem(
                items[0],
                navigationItemsIfQueueUnavailable: items
            )
        )

        stageLeafSelection(on: viewModel, branchID: branch.id, leafID: leaf.id)
        XCTAssertTrue(viewModel.synchronizeFocusedItem(items[2]))
        XCTAssertEqual(viewModel.currentIndex, 2)
        XCTAssertEqual(viewModel.currentItem?.id, items[2].id)
        XCTAssertTrue(viewModel.navigationPath.isEmpty)
        XCTAssertTrue(viewModel.selectedLeafTags.isEmpty)
        if case .backward = viewModel.navigationDirection {
            XCTFail("Forward focus navigation should mark the queue direction forward")
        }

        stageLeafSelection(on: viewModel, branchID: branch.id, leafID: leaf.id)
        XCTAssertTrue(viewModel.synchronizeFocusedItem(items[1]))
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertEqual(viewModel.currentItem?.id, items[1].id)
        XCTAssertTrue(viewModel.navigationPath.isEmpty)
        XCTAssertTrue(viewModel.selectedLeafTags.isEmpty)
        if case .forward = viewModel.navigationDirection {
            XCTFail("Backward focus navigation should mark the queue direction backward")
        }
    }

    func testExistingTagsStageRemovalWhileNewTagsStageAddition() {
        let existing = makeTag("Existing", order: 0)
        let new = makeTag("New", order: 1)
        tagSettings.definitions = [existing, new]

        var item = makeItem()
        item.metadata.tags = ["Existing"]
        let viewModel = makeActiveViewModel()
        XCTAssertTrue(viewModel.synchronizeFocusedItem(item, navigationItemsIfQueueUnavailable: [item]))
        setRootLevel(on: viewModel)

        viewModel.toggleLeafTag(named: "existing")
        XCTAssertEqual(viewModel.stagedRemovalTags, ["Existing"])
        XCTAssertTrue(viewModel.selectedLeafTags.isEmpty)
        XCTAssertEqual(viewModel.stagingState(for: "Existing"), .removing)

        viewModel.toggleLeafTag(named: "New")
        XCTAssertEqual(viewModel.selectedLeafTags, ["New"])
        XCTAssertEqual(viewModel.stagingState(for: "New"), .adding)

        viewModel.toggleLeafTag(named: "EXISTING")
        XCTAssertTrue(viewModel.stagedRemovalTags.isEmpty)
        XCTAssertEqual(viewModel.stagingState(for: "Existing"), .onItem)
    }

    func testStagedChangesRestoreWhenBrowsingAwayAndBack() {
        let firstTag = makeTag("First", order: 0)
        let secondTag = makeTag("Second", order: 1)
        tagSettings.definitions = [firstTag, secondTag]
        let items = [makeItem(), makeItem()]
        let viewModel = makeActiveViewModel()
        XCTAssertTrue(viewModel.synchronizeFocusedItem(items[0], navigationItemsIfQueueUnavailable: items))

        viewModel.toggleLeafTag(named: "First")
        XCTAssertTrue(viewModel.moveToNextItem())
        viewModel.toggleLeafTag(named: "Second")
        XCTAssertTrue(viewModel.moveToPreviousItem())

        XCTAssertEqual(viewModel.currentItem?.id, items[0].id)
        XCTAssertEqual(viewModel.selectedLeafTags, ["First"])
        XCTAssertTrue(viewModel.stagedRemovalTags.isEmpty)

        XCTAssertTrue(viewModel.moveToNextItem())
        XCTAssertEqual(viewModel.selectedLeafTags, ["Second"])
    }

    func testSkipTracksTruthfulProgressAndUndoRestoresCounts() async {
        tagSettings.definitions = []
        let items = [makeItem(), makeItem()]
        let viewModel = makeActiveViewModel()
        XCTAssertTrue(viewModel.synchronizeFocusedItem(items[0], navigationItemsIfQueueUnavailable: items))

        await viewModel.skipItem()

        XCTAssertEqual(viewModel.currentItem?.id, items[1].id)
        XCTAssertEqual(viewModel.completedCount, 1)
        XCTAssertEqual(viewModel.skippedCount, 1)
        XCTAssertEqual(viewModel.remainingCount, 1)
        XCTAssertEqual(viewModel.history.last?.wasSkipped, true)

        await viewModel.undoAndGoBack()
        XCTAssertEqual(viewModel.currentItem?.id, items[0].id)
        XCTAssertEqual(viewModel.completedCount, 0)
        XCTAssertEqual(viewModel.skippedCount, 0)
    }

    func testSiblingShortcutOverridesRejectConflictsAndAutoFillUnusedKeys() {
        let first = makeTag("First", order: 0)
        let second = makeTag("Second", order: 1)
        tagSettings.definitions = [first, second]

        XCTAssertEqual(tagSettings.setShortcutKey("2", for: first.id), .success("2"))
        XCTAssertEqual(
            tagSettings.setShortcutKey("2", for: second.id),
            .failure(.duplicateKey(key: "2", existingTagName: "First"))
        )
        XCTAssertEqual(tagSettings.setShortcutKey("!", for: second.id), .failure(.invalidKey("!")))

        var roots = TagTreeNode.buildTree(from: tagSettings)
        TagTreeNode.assignKeyBindings(to: &roots)
        XCTAssertEqual(roots.first(where: { $0.id == first.id })?.keyBinding, "2")
        XCTAssertEqual(roots.first(where: { $0.id == second.id })?.keyBinding, "1")
    }

    func testFuzzyTagMatcherRanksExactPrefixAndSubsequence() {
        XCTAssertEqual(TagCanonicalizer.matchScore(query: "hair metal", candidate: "Hair Metal"), 0)
        XCTAssertLessThan(
            TagCanonicalizer.matchScore(query: "hair", candidate: "hair metal")!,
            TagCanonicalizer.matchScore(query: "hair", candidate: "1980s hair metal")!
        )
        XCTAssertNotNil(TagCanonicalizer.matchScore(query: "hmt", candidate: "hair metal"))
        XCTAssertNil(TagCanonicalizer.matchScore(query: "xyz", candidate: "hair metal"))

        XCTAssertEqual(
            TagSuggestionEngine.suggestions(
                query: "hm",
                existingTags: ["Home", "Hair Metal", "Ambient"],
                recentlyUsedTags: ["Hair Metal"],
                excluding: []
            ).first,
            "Home"
        )
    }

    func testFindAnyTagReturnsOnlyStageableLeavesIncludingThoseFoundByParentName() {
        let genre = makeTag("Genre", order: 0)
        let metal = makeTag("Metal", parent: genre.id, order: 0)
        let hairMetal = makeTag("Hair Metal", parent: metal.id, order: 0)
        let ambient = makeTag("Ambient", parent: genre.id, order: 1)
        let mood = makeTag("Mood", order: 1)
        let calm = makeTag("Calm", parent: mood.id, order: 0)
        var fillers: [TagDefinition] = []
        for index in 0..<200 {
            fillers.append(makeTag(String(format: "Filler %03d", index), parent: mood.id, order: index + 1))
        }
        tagSettings.definitions = [genre, metal, hairMetal, ambient, mood, calm] + fillers
        let viewModel = makeActiveViewModel()

        // "metal" names a branch; only its leaf is offered, with the branch as context.
        let metalResults = viewModel.tagSearchResults(for: "METAL")
        XCTAssertEqual(metalResults.map(\.definition.id), [hairMetal.id])
        XCTAssertEqual(metalResults.first?.ancestorLabel, "Genre › Metal")

        // A root name finds its leaves through the path.
        let genreResults = viewModel.tagSearchResults(for: "genre")
        XCTAssertEqual(Set(genreResults.map(\.definition.id)), [hairMetal.id, ambient.id])
        XCTAssertTrue(genreResults.allSatisfy(\.matchedPathOnly))

        XCTAssertEqual(viewModel.tagSearchResults(for: "filler", limit: 8).count, 8)
        XCTAssertTrue(viewModel.tagSearchResults(for: "").isEmpty)
    }

    func testEmptyQueueAndIncompleteUndoMessagesStateTheActualScope() {
        XCTAssertEqual(TaggingQueueViewModel.QueueScope.untagged.emptyMessage, "No untagged items in the library")
        XCTAssertEqual(TaggingQueueViewModel.QueueScope.folder("/tmp/x").emptyMessage, "No untagged items in this folder")
        XCTAssertEqual(
            TaggingQueueViewModel.QueueScope.selection([UUID()]).emptyMessage,
            "None of the selected items are available to tag"
        )

        let message = TaggingQueueViewModel.incompleteUndoMessage(notRemoved: ["Added"], notRestored: ["Old A", "Old B"])
        XCTAssertTrue(message.contains("couldn’t remove ‘Added’"))
        XCTAssertTrue(message.contains("couldn’t restore ‘Old A’, ‘Old B’"))
    }

    private func makeActiveViewModel() -> TaggingQueueViewModel {
        let viewModel = TaggingQueueViewModel(mediaStore: MediaStore(), tagSettings: tagSettings)
        viewModel.isActive = true
        return viewModel
    }

    private func setRootLevel(on viewModel: TaggingQueueViewModel) {
        var roots = TagTreeNode.buildTree(from: tagSettings)
        TagTreeNode.assignKeyBindings(to: &roots)
        viewModel.currentLevel = roots
    }

    private func stageLeafSelection(
        on viewModel: TaggingQueueViewModel,
        branchID: UUID,
        leafID: UUID
    ) {
        setRootLevel(on: viewModel)
        guard let branch = viewModel.currentLevel.first(where: { $0.id == branchID }) else {
            return XCTFail("Expected branch in tagging tree")
        }
        viewModel.selectNode(branch)
        guard let leaf = viewModel.currentLevel.first(where: { $0.id == leafID }) else {
            return XCTFail("Expected leaf in tagging branch")
        }
        viewModel.selectNode(leaf)
        XCTAssertFalse(viewModel.navigationPath.isEmpty)
        XCTAssertFalse(viewModel.selectedLeafTags.isEmpty)
    }

    private func makeTag(_ name: String, parent: UUID? = nil, order: Int) -> TagDefinition {
        var tag = TagDefinition(name: name)
        tag.parentId = parent
        tag.sortOrder = order
        return tag
    }

    private func makeItem() -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/archive/2025-01")
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id)")!,
                platform: "test"
            ),
            aspectRatio: 1.0
        )
    }

    private func waitForCurrentLevel(
        on viewModel: TaggingQueueViewModel,
        where predicate: @escaping ([TagTreeNode]) -> Bool
    ) async {
        guard !predicate(viewModel.currentLevel) else { return }

        let expectation = XCTestExpectation(description: "Tagging tree refreshes")
        var fulfilled = false
        let cancellable = viewModel.$currentLevel.sink { nodes in
            guard !fulfilled, predicate(nodes) else { return }
            fulfilled = true
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        cancellable.cancel()
    }

    private func waitForNavigationPath(
        on viewModel: TaggingQueueViewModel,
        ids: [UUID]
    ) async {
        guard viewModel.navigationPath.map(\.id) != ids else { return }

        let expectation = XCTestExpectation(description: "Tagging breadcrumb reconciles")
        var fulfilled = false
        let cancellable = viewModel.$navigationPath.sink { path in
            guard !fulfilled, path.map(\.id) == ids else { return }
            fulfilled = true
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        cancellable.cancel()
    }
}
