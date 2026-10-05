import XCTest
@testable import MediaViewer

/// Hold-to-tag overlay at the owner's scale: hundreds of hierarchical tags.
@MainActor
final class TagOverlayScaleTests: XCTestCase {

    // MARK: - Fixture

    /// 10 roots × 5 children × 5 grandchildren = 310 tags, three levels deep, with
    /// long names and one oversized branch.
    private struct Fixture {
        var definitions: [TagDefinition] = []
        var childrenByParent: [UUID?: [TagDefinition]] = [:]

        mutating func add(_ name: String, parent: UUID?) -> TagDefinition {
            var tag = TagDefinition(name: name)
            tag.parentId = parent
            tag.sortOrder = childrenByParent[parent, default: []].count
            definitions.append(tag)
            childrenByParent[parent, default: []].append(tag)
            return tag
        }

        func children(_ parent: UUID?) -> [TagDefinition] { childrenByParent[parent] ?? [] }

        static func hierarchy(roots: Int = 10, children: Int = 5, grandchildren: Int = 5) -> Fixture {
            var fixture = Fixture()
            for r in 0..<roots {
                let root = fixture.add("Aesthetic family \(r) with a long name", parent: nil)
                for c in 0..<children {
                    let child = fixture.add("Branch \(r).\(c) era", parent: root.id)
                    for g in 0..<grandchildren {
                        _ = fixture.add("Leaf \(r).\(c).\(g) hair metal", parent: child.id)
                    }
                }
            }
            return fixture
        }
    }

    private func layout(_ fixture: Fixture, style: TagWheelLayout.Style = .sunburst,
                        diameter: CGFloat = 400, focus: TagWheelLayout.Focus = .root) -> TagWheelLayout {
        TagWheelLayout(style: style, diameter: diameter, focus: focus, children: fixture.children)
    }

    // MARK: - Sunburst sizing

    func testSunburstAtThreeHundredTagsIsBoundedAndEverySegmentIsReadable() {
        let fixture = Fixture.hierarchy()
        XCTAssertEqual(fixture.definitions.count, 310)
        let wheel = layout(fixture)

        // Only the focus level and its children are drawn; grandchildren sit behind the rim.
        let inner = wheel.segments.filter { $0.ring == 0 }
        let outer = wheel.segments.filter { $0.ring == 1 }
        let rim = wheel.segments.filter { $0.ring == 2 }
        XCTAssertEqual(inner.count, 10)
        XCTAssertEqual(outer.count, 50)
        XCTAssertEqual(rim.count, 50)
        XCTAssertTrue(rim.allSatisfy { if case .drill = $0.kind { return true } else { return false } })

        // Inner ring tiles the circle exactly, starting at 12 o'clock.
        XCTAssertEqual(inner.first?.startDegrees ?? 0, -90, accuracy: 1e-9)
        XCTAssertEqual(inner.last?.endDegrees ?? 0, 270, accuracy: 1e-9)
        for (a, b) in zip(inner, inner.dropFirst()) {
            XCTAssertEqual(a.endDegrees, b.startDegrees, accuracy: 1e-9)
        }

        for (ringIndex, ring) in [inner, outer].enumerated() {
            for segment in ring {
                XCTAssertGreaterThanOrEqual(segment.span, wheel.metrics.minDegrees(ring: ringIndex) - 1e-9, segment.id)
                XCTAssertNotNil(segment.label, "segment \(segment.id) should fit a label")
            }
        }

        // Nothing is drawn outside the requested diameter.
        XCTAssertTrue(wheel.segments.allSatisfy { $0.outer <= 200 && $0.inner >= wheel.metrics.hubRadius })

        // Children stay inside their parent's angular span.
        for parent in inner {
            guard let parentTag = parent.tag else { continue }
            let kids = outer.filter { $0.tag?.parentId == parentTag.id }
            XCTAssertEqual(kids.count, 5)
            for kid in kids {
                XCTAssertGreaterThanOrEqual(kid.startDegrees, parent.startDegrees - 1e-9)
                XCTAssertLessThanOrEqual(kid.endDegrees, parent.endDegrees + 1e-9)
            }
        }
    }

    func testLabelsStayInsideTheirOwnSegmentSoTheyCannotCollide() {
        let wheel = layout(Fixture.hierarchy())
        for segment in wheel.segments {
            guard let label = segment.label else { continue }
            XCTAssertEqual(wheel.segment(at: label.center)?.id, segment.id, "label centre of \(segment.id)")
            XCTAssertGreaterThanOrEqual(label.maxLength, TagWheelLayout.minLabelLength)
            // Along the ring the label is bounded by the arc; across it by the ring width.
            let arc = CGFloat(segment.span * .pi / 180) * (segment.inner + segment.outer) / 2
            let bound = label.orientation == .tangential ? arc : segment.outer - segment.inner
            XCTAssertLessThanOrEqual(label.maxLength, bound)
            XCTAssertLessThanOrEqual(abs(label.rotationDegrees), 90, "text must never read upside down")
        }
    }

    func testOversizedLevelPagesThroughEveryTagExactlyOnce() {
        var fixture = Fixture()
        for index in 0..<300 {
            _ = fixture.add("flat tag \(index)", parent: nil)
        }

        var seen: [UUID] = []
        var focus = TagWheelLayout.Focus.root
        var pages = 0
        while pages < 20 {
            pages += 1
            let wheel = layout(fixture, style: .radial, focus: focus)
            let capacity = wheel.metrics.capacity(ring: 0, span: 360)
            XCTAssertLessThanOrEqual(wheel.segments.count, capacity)
            seen += wheel.segments.compactMap(\.tag?.id)
            guard let more = wheel.segments.first(where: { if case .more = $0.kind { return true } else { return false } }),
                  case .more(let count, let next) = more.kind else { break }
            XCTAssertEqual(count, 300 - seen.count)
            focus = next
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(seen, fixture.definitions.map(\.id))
    }

    func testBranchTooLargeForItsSliceCollapsesIntoDrillableMoreSegment() {
        var fixture = Fixture.hierarchy(roots: 12, children: 2, grandchildren: 0)
        let big = fixture.add("Huge branch", parent: nil)
        for index in 0..<120 {
            _ = fixture.add("item \(index)", parent: big.id)
        }

        let wheel = layout(fixture)
        let bigChildren = wheel.segments.filter { $0.ring == 1 && $0.tag?.parentId == big.id }
        let more = wheel.segments.first { segment in
            if case .more(_, let focus) = segment.kind { return focus == TagWheelLayout.Focus(parentID: big.id) }
            return false
        }
        XCTAssertNotNil(more)
        if case .more(let count, _)? = more?.kind {
            XCTAssertEqual(count + bigChildren.count, 120)
        }
        XCTAssertTrue(wheel.segments.filter { $0.ring == 1 }.allSatisfy { $0.span >= wheel.metrics.minDegrees(ring: 1) - 1e-9 })

        // Drilling in shows the branch's own children in the inner ring.
        let drilled = layout(fixture, focus: TagWheelLayout.Focus(parentID: big.id))
        XCTAssertTrue(drilled.segments.filter { $0.ring == 0 }.allSatisfy { segment in
            segment.tag.map { $0.parentId == big.id } ?? true
        })
    }

    func testDrillIntoBranchAndLeafFocus() {
        let fixture = Fixture.hierarchy()
        let branch = fixture.children(fixture.children(nil)[3].id)[2]
        let wheel = layout(fixture, focus: TagWheelLayout.Focus(parentID: branch.id))
        XCTAssertEqual(wheel.segments.compactMap(\.tag?.id), fixture.children(branch.id).map(\.id))

        let leaf = fixture.children(branch.id)[0]
        XCTAssertTrue(layout(fixture, focus: TagWheelLayout.Focus(parentID: leaf.id)).segments.isEmpty)
    }

    func testHitTestingFindsEverySegmentAndIgnoresHubAndOutside() {
        let wheel = layout(Fixture.hierarchy())
        for segment in wheel.segments {
            let mid = segment.midDegrees * .pi / 180
            let radius = (segment.inner + segment.outer) / 2
            let point = CGPoint(x: cos(mid) * radius, y: sin(mid) * radius)
            XCTAssertEqual(wheel.segment(at: point)?.id, segment.id)
        }
        XCTAssertNil(wheel.segment(at: .zero))
        XCTAssertTrue(wheel.isInsideHub(CGPoint(x: 10, y: 10)))
        XCTAssertNil(wheel.segment(at: CGPoint(x: 0, y: -199.5)))
        XCTAssertNil(wheel.segment(at: CGPoint(x: 300, y: 0)))
    }

    func testLargerSizePresetFitsMoreSegmentsPerRing() {
        let small = TagWheelLayout.Metrics(style: .sunburst, diameter: 400 * 0.85)
        let wide = TagWheelLayout.Metrics(style: .sunburst, diameter: 400 * 1.45)
        XCTAssertGreaterThan(wide.capacity(ring: 1, span: 360), small.capacity(ring: 1, span: 360))
        XCTAssertLessThanOrEqual(wide.capacity(ring: 1, span: 360), TagWheelLayout.Metrics.maxSegmentsPerRing)
    }

    func testLayoutIsCheapAtScale() {
        let fixture = Fixture.hierarchy()
        let start = Date()
        for _ in 0..<50 {
            _ = layout(fixture)
        }
        // Rebuilt on hover; generous bound so a loaded CI machine does not flake.
        XCTAssertLessThan(Date().timeIntervalSince(start) / 50, 0.02)
    }

    // MARK: - Filtering

    func testFilterIsPathAwareAcrossTheWholeTree() {
        let fixture = Fixture.hierarchy()
        let hits = TagDefinitionSearch.matches(query: "branch 4.2", in: fixture.definitions)
        XCTAssertEqual(hits.first?.definition.name, "Branch 4.2 era")
        // Leaves under that branch are found through their path, ranked after the name hit.
        let pathHits = hits.filter(\.matchedPathOnly)
        XCTAssertEqual(pathHits.count, 5)
        XCTAssertTrue(pathHits.allSatisfy { $0.ancestorLabel.hasSuffix("Branch 4.2 era") })

        // Case and composition variants resolve to the same tag.
        let caseHits = TagDefinitionSearch.matches(query: "LEAF 7.1.3 HAIR METAL", in: fixture.definitions)
        XCTAssertEqual(caseHits.first?.definition.name, "Leaf 7.1.3 hair metal")
    }

    // MARK: - Preference migration

    func testLegacyLayoutBoolsMigrateToSingleLayout() {
        XCTAssertEqual(TagOverlayLayout.migrated(storedValue: nil, legacyAlwaysGrid: false, legacyAlwaysRadial: false), .sunburst)
        XCTAssertEqual(TagOverlayLayout.migrated(storedValue: nil, legacyAlwaysGrid: true, legacyAlwaysRadial: false), .grid)
        XCTAssertEqual(TagOverlayLayout.migrated(storedValue: nil, legacyAlwaysGrid: false, legacyAlwaysRadial: true), .radial)
        // A stored new-style value wins over any leftover legacy flag.
        XCTAssertEqual(TagOverlayLayout.migrated(storedValue: "radial", legacyAlwaysGrid: true, legacyAlwaysRadial: false), .radial)
        XCTAssertEqual(TagOverlayLayout.migrated(storedValue: "bogus", legacyAlwaysGrid: true, legacyAlwaysRadial: false), .grid)
    }

    func testLoadLayoutWritesResolvedValueAndRemovesLegacyKeys() throws {
        let suite = "TagOverlayScaleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "tagAlwaysUseGrid")
        defaults.set(false, forKey: "tagAlwaysUseRadio")
        defaults.set(25, forKey: "tagGridThreshold")

        XCTAssertEqual(TagSettings.loadLayout(from: defaults), .grid)
        XCTAssertEqual(defaults.string(forKey: TagSettings.layoutKey), "grid")
        for key in TagSettings.legacyLayoutKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        // Second launch reads the migrated value.
        XCTAssertEqual(TagSettings.loadLayout(from: defaults), .grid)
    }

    // MARK: - Recents

    func testRecentsRecordByCanonicalNameAndStayCapped() {
        let settings = TagSettings.shared
        let savedDefinitions = settings.definitions
        let savedRecents = settings.recentTagIds
        defer {
            settings.definitions = savedDefinitions
            settings.recentTagIds = savedRecents
        }

        let fixture = Fixture.hierarchy(roots: 3, children: 4, grandchildren: 0)
        settings.definitions = fixture.definitions
        settings.recentTagIds = []

        settings.recordTagUsage(named: "BRANCH 1.2 ERA")
        settings.recordTagUsage(named: "not a tag")
        XCTAssertEqual(settings.recentTags.map(\.name), ["Branch 1.2 era"])

        for tag in fixture.definitions {
            settings.recordTagUsage(named: tag.name)
        }
        settings.recordTagUsage(named: "branch 1.2 era")
        XCTAssertEqual(settings.recentTags.count, 10)
        XCTAssertEqual(settings.recentTags.first?.name, "Branch 1.2 era")
        XCTAssertEqual(Set(settings.recentTagIds).count, 10)
    }

    // MARK: - Window clamping

    func testOverlayShiftsBackInsideWindow() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        XCTAssertEqual(KeepInsideWindow.correction(for: CGRect(x: 100, y: 100, width: 400, height: 480), within: bounds), .zero)
        XCTAssertEqual(KeepInsideWindow.correction(for: CGRect(x: -40, y: 300, width: 400, height: 480), within: bounds),
                       CGSize(width: 48, height: -88))
        // Larger than the window: pin the leading/top edge so the filter stays reachable.
        XCTAssertEqual(KeepInsideWindow.correction(for: CGRect(x: 0, y: -50, width: 400, height: 900), within: bounds).height, 58)
    }
}

@MainActor
final class TagWheelLabelTests: XCTestCase {
    func testChildLabelsDropARepeatedParentPrefixOnly() {
        XCTAssertEqual(TagWheelLayout.shortName("music 1980s", under: "Music"), "1980s")
        XCTAssertEqual(TagWheelLayout.shortName("café-noir", under: "Cafe"), "noir")
        XCTAssertEqual(TagWheelLayout.shortName("musical", under: "music"), "musical")
        XCTAssertEqual(TagWheelLayout.shortName("music", under: "music"), "music")
        XCTAssertEqual(TagWheelLayout.shortName("1980s punk", under: nil), "1980s punk")
    }

    func testLeafOnlyLevelUsesTheFullSizeSingleRing() {
        var leaves: [TagDefinition] = []
        for index in 0..<4 { leaves.append(TagDefinition(name: "leaf \(index)")) }
        let wheel = TagWheelLayout(style: .sunburst, diameter: 400, focus: .root) { $0 == nil ? leaves : [] }
        XCTAssertEqual(wheel.style, .radial)
        XCTAssertEqual(wheel.metrics.rings.count, 1)
        XCTAssertEqual(wheel.segments.count, 4)
    }
}
