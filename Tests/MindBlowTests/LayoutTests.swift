import XCTest
import SwiftUI
@testable import MindBlow

final class LayoutTests: XCTestCase {
    private func sampleTree(branches: Int = 4, depth: Int = 3) -> MindNode {
        func make(_ level: Int, _ label: String) -> MindNode {
            var node = MindNode(text: "Node \(label)")
            if level < depth {
                node.children = (0..<2).map { make(level + 1, "\(label).\($0)") }
            }
            return node
        }
        var root = MindNode(text: "Root")
        root.children = (0..<branches).map { make(1, "\($0)") }
        return root
    }

    func testAllNodesPlaced() {
        let root = sampleTree()
        let layout = MapLayout(root: root)
        var count = 0
        func walk(_ n: MindNode) {
            count += 1
            XCTAssertNotNil(layout.nodes[n.id], "missing geometry for \(n.text)")
            n.children.forEach(walk)
        }
        walk(root)
        XCTAssertEqual(layout.order.count, count)
        XCTAssertEqual(layout.edges.count, count - 1, "every non-root node has exactly one incoming edge")
    }

    func testNoOverlappingNodes() {
        let layout = MapLayout(root: sampleTree(branches: 6, depth: 4))
        let rects = layout.order.compactMap { layout.nodes[$0]?.rect }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i].insetBy(dx: 1, dy: 1)
                let b = rects[j].insetBy(dx: 1, dy: 1)
                XCTAssertFalse(a.intersects(b), "nodes overlap: \(a) vs \(b)")
            }
        }
    }

    func testSameLevelSameColor() {
        let layout = MapLayout(root: sampleTree())
        var colorsByLevel: [Int: Color] = [:]
        for id in layout.order {
            guard let geom = layout.nodes[id] else { continue }
            if let existing = colorsByLevel[geom.level] {
                XCTAssertEqual(existing, geom.color, "level \(geom.level) has inconsistent colors")
            } else {
                colorsByLevel[geom.level] = geom.color
            }
        }
        // Adjacent levels should differ (palette cycles every 8 levels).
        XCTAssertNotEqual(colorsByLevel[1], colorsByLevel[2])
        XCTAssertNotEqual(colorsByLevel[2], colorsByLevel[3])
    }

    func testCollapsedBranchHidesDescendants() {
        var root = sampleTree()
        let collapsed = root.children[0]
        root.update(collapsed.id) { $0.isCollapsed = true }
        let layout = MapLayout(root: root)
        XCTAssertNotNil(layout.nodes[collapsed.id])
        for child in collapsed.children {
            XCTAssertNil(layout.nodes[child.id], "collapsed branch leaked child \(child.text)")
        }
    }

    func testClosedNodeLeavesTheMapEntirely() {
        var root = sampleTree()
        let closed = root.children[0]
        root.update(closed.id) { $0.closedAt = Date() }
        let layout = MapLayout(root: root)
        XCTAssertNil(layout.nodes[closed.id], "closed topic still laid out")
        func walk(_ n: MindNode) {
            XCTAssertNil(layout.nodes[n.id], "closed subtree leaked \(n.text)")
            XCTAssertFalse(layout.edges.contains { $0.id == n.id })
            n.children.forEach(walk)
        }
        closed.children.forEach(walk)
        // The parent's geometry counts only open children, and surfaces the
        // closed one on the ✓N badge.
        let rootGeom = layout.nodes[root.id]
        XCTAssertEqual(rootGeom?.childCount, root.children.count - 1)
        XCTAssertEqual(rootGeom?.closedChildCount, 1)
    }

    func testEarliestDueSkipsClosedSubtrees() {
        var root = sampleTree()
        let a = root.children[0]
        let b = root.children[1]
        let soon = Date(timeIntervalSinceNow: 3600)
        let later = Date(timeIntervalSinceNow: 86400)
        root.update(a.children[0].id) { $0.dueDate = soon }
        root.update(b.id) { $0.dueDate = later }
        root.update(a.id) { $0.closedAt = Date() }
        let info = MapLayout.earliestDue(in: root, level: 0)
        XCTAssertEqual(info?.nodeID, b.id, "closed branch's due date advertised")
    }

    func testBranchesSplitAcrossSides() {
        let layout = MapLayout(root: sampleTree(branches: 6, depth: 2))
        let level1 = layout.order.compactMap { layout.nodes[$0] }.filter { $0.level == 1 }
        XCTAssertTrue(level1.contains { $0.side == .right })
        XCTAssertTrue(level1.contains { $0.side == .left })
    }

    func testChildrenSitOutwardOfParent() {
        let root = sampleTree()
        let layout = MapLayout(root: root)
        func walk(_ n: MindNode) {
            guard let parentGeom = layout.nodes[n.id] else { return }
            for child in n.children {
                guard let childGeom = layout.nodes[child.id] else { continue }
                if childGeom.side == .right {
                    XCTAssertGreaterThan(childGeom.rect.minX, parentGeom.rect.maxX)
                } else if n.id != root.id {
                    XCTAssertLessThan(childGeom.rect.maxX, parentGeom.rect.minX)
                }
                walk(child)
            }
        }
        walk(root)
    }
}

/// The map must not rearrange itself around a fold. These pin the two ways it
/// used to: branches swapping sides, and a side sliding to re-center.
final class LayoutStabilityTests: XCTestCase {
    private func tree(branches: Int = 6, depth: Int = 3) -> MindNode {
        func make(_ level: Int, _ label: String) -> MindNode {
            var node = MindNode(text: "Node \(label)")
            if level < depth {
                node.children = (0..<3).map { make(level + 1, "\(label).\($0)") }
            }
            return node
        }
        var root = MindNode(text: "Root")
        root.children = (0..<branches).map { make(1, "\($0)") }
        return root
    }

    /// The original bug: side assignment was recomputed from visible spans, so
    /// folding one branch flipped every later auto-sided branch to the other
    /// side of the root.
    func testCollapsingABranchNeverMovesAnyBranchToTheOtherSide() {
        var root = tree()
        let before = MapLayout(root: root)
        let sidesBefore = before.nodes.mapValues(\.side)

        // Fold the branch with the largest subtree — the one most able to
        // swing the old span comparison.
        let target = root.children[1].id
        root.update(target) { $0.isCollapsed = true }
        let after = MapLayout(root: root)

        for (id, side) in after.nodes.mapValues(\.side) {
            XCTAssertEqual(side, sidesBefore[id], "node \(id) changed side on collapse")
        }
    }

    func testCollapsingOneSideLeavesTheOtherSideUntouched() {
        var root = tree()
        let before = MapLayout(root: root)
        guard let target = root.children.first(where: { before.nodes[$0.id]?.side == .right })?.id
        else { return XCTFail("no right-hand branch to collapse") }

        root.update(target) { $0.isCollapsed = true }
        let after = MapLayout(root: root)

        for (id, geom) in after.nodes where geom.side == .left {
            XCTAssertEqual(geom.rect, before.nodes[id]?.rect, "left side moved when a right branch folded")
        }
    }

    func testSideOffsetShiftsOnlyItsOwnSide() {
        let layout = MapLayout(root: tree())
        let shifted = layout.applying(SideOffsets(left: 0, right: 40))

        for (id, geom) in shifted.nodes {
            guard let original = layout.nodes[id] else { return XCTFail("node vanished") }
            let expected: CGFloat = id == layout.rootID || geom.side == .left ? 0 : 40
            XCTAssertEqual(geom.rect.midY - original.rect.midY, expected, accuracy: 0.001)
            XCTAssertEqual(geom.rect.midX, original.rect.midX, accuracy: 0.001, "offsets are vertical only")
        }
    }

    /// A rigid per-side translation can't introduce overlap: each side is
    /// internally non-overlapping and the two never cross the root.
    func testOffsetLayoutStaysNonOverlapping() {
        let layout = MapLayout(root: tree()).applying(SideOffsets(left: -120, right: 200))
        let rects = layout.order.compactMap { layout.nodes[$0]?.rect }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(
                    rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j].insetBy(dx: 1, dy: 1)),
                    "nodes overlap after offset: \(rects[i]) vs \(rects[j])"
                )
            }
        }
    }

    /// The anchor rule itself: pin the toggled node by offsetting only its side.
    func testAnchoringPinsTheToggledNode() {
        var root = tree()
        let target = root.children[0].id
        let before = MapLayout(root: root)
        guard let old = before.nodes[target] else { return XCTFail("missing target") }

        root.update(target) { $0.isCollapsed = true }
        let after = MapLayout(root: root)
        guard let new = after.nodes[target] else { return XCTFail("missing target") }

        var offsets = SideOffsets()
        offsets[old.side] = old.rect.midY - new.rect.midY
        let anchored = after.applying(offsets)

        XCTAssertEqual(anchored.nodes[target]?.rect.midY ?? .nan, old.rect.midY, accuracy: 0.001)
    }

    /// Drives the real anchor rule the way the editor does, so these cover the
    /// shipping code path rather than a restatement of it.
    private func fold(_ id: UUID, in root: inout MindNode, offsets: inout SideOffsets) -> MapLayout {
        let shown = MapLayout(root: root).applying(offsets)
        root.update(id) { $0.isCollapsed.toggle() }
        let base = MapLayout(root: root)
        offsets.anchor(id, shown: shown, base: base)
        return base.applying(offsets)
    }

    func testFoldKeepsTheToggledNodeExactlyWhereItWas() {
        var root = tree()
        var offsets = SideOffsets()
        let target = root.children[3].id
        let before = MapLayout(root: root)

        let after = fold(target, in: &root, offsets: &offsets)

        XCTAssertEqual(
            after.nodes[target]?.rect.midY ?? .nan,
            before.nodes[target]?.rect.midY ?? .infinity,
            accuracy: 0.001
        )
    }

    /// Anchoring is absolute rather than cumulative, so a fold and an unfold
    /// must land back on the original map — no creep over a long session.
    func testFoldingAndUnfoldingReturnsTheMapToWhereItStarted() {
        var root = tree()
        var offsets = SideOffsets()
        let before = MapLayout(root: root)
        let targets = [root.children[0].id, root.children[3].id, root.children[1].id]

        for id in targets { _ = fold(id, in: &root, offsets: &offsets) }
        for id in targets.reversed() { _ = fold(id, in: &root, offsets: &offsets) }

        XCTAssertEqual(offsets, .zero, "offsets drifted across a round trip")
        let after = MapLayout(root: root).applying(offsets)
        for (id, geom) in after.nodes {
            XCTAssertEqual(geom.rect, before.nodes[id]?.rect, "node \(id) did not return home")
        }
    }

    func testFoldingOnOneSideNeverDisturbsTheOther() {
        var root = tree()
        var offsets = SideOffsets()
        let before = MapLayout(root: root)
        guard let target = root.children.first(where: { before.nodes[$0.id]?.side == .right })?.id
        else { return XCTFail("no right-hand branch") }

        let after = fold(target, in: &root, offsets: &offsets)

        XCTAssertEqual(offsets.left, 0, "the untouched side picked up an offset")
        for (id, geom) in after.nodes where geom.side == .left {
            XCTAssertEqual(geom.rect, before.nodes[id]?.rect, "a left-hand node moved")
        }
    }

    func testOffsetsAreReflectedInBounds() {
        let layout = MapLayout(root: tree())
        let shifted = layout.applying(SideOffsets(left: 0, right: 500))
        XCTAssertGreaterThan(shifted.bounds.maxY, layout.bounds.maxY)
    }

    /// Views compare `generation` to decide whether geometry changed at all.
    func testOffsettingProducesAFreshGeneration() {
        let layout = MapLayout(root: tree())
        XCTAssertNotEqual(layout.applying(SideOffsets(left: 0, right: 10)).generation, layout.generation)
        XCTAssertEqual(layout.applying(.zero).generation, layout.generation, "a no-op offset is free")
    }
}

final class LayoutPerformanceTests: XCTestCase {
    /// Wide + deep tree (485 nodes) — the shape that made the old
    /// O(nodes × depth) span recursion crawl.
    private func bigTree() -> MindNode {
        func make(_ level: Int, _ label: String) -> MindNode {
            var node = MindNode(text: "Topic \(label) with some wrapping text")
            if level < 5 {
                node.children = (0..<3).map { make(level + 1, "\(label).\($0)") }
            }
            return node
        }
        var root = MindNode(text: "Root")
        root.children = (0..<4).map { make(1, "\($0)") }
        return root
    }

    func testLargeMapLaysOutEveryNode() {
        let root = bigTree()
        let layout = MapLayout(root: root)
        var count = 0
        func walk(_ n: MindNode) {
            count += 1
            XCTAssertNotNil(layout.nodes[n.id])
            n.children.forEach(walk)
        }
        walk(root)
        XCTAssertEqual(layout.order.count, count)
        XCTAssertGreaterThan(count, 480)
    }

    func testGeometryCarriesNodeText() {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "Child A"), MindNode(text: "")]
        let layout = MapLayout(root: root)
        XCTAssertEqual(layout.nodes[root.id]?.text, "Root")
        XCTAssertEqual(layout.nodes[root.children[0].id]?.text, "Child A")
        XCTAssertEqual(layout.nodes[root.children[1].id]?.text, "")
    }

    func testTextMeasurementIsStableAcrossRepeatedCalls() {
        let first = Metrics.textSize(for: "A fairly long topic title that wraps", level: 2, scale: 1)
        let second = Metrics.textSize(for: "A fairly long topic title that wraps", level: 2, scale: 1)
        XCTAssertEqual(first, second)
        let scaled = Metrics.textSize(for: "A fairly long topic title that wraps", level: 2, scale: 1.5)
        XCTAssertGreaterThan(scaled.width, first.width)
    }

    func testRepeatedLayoutOfLargeMapStaysFast() {
        let root = bigTree()
        _ = MapLayout(root: root)  // warm the text cache
        let start = Date()
        for _ in 0..<10 { _ = MapLayout(root: root) }
        let elapsed = Date().timeIntervalSince(start)
        // 10 warm relayouts of ~500 nodes; generous bound to stay CI-safe.
        XCTAssertLessThan(elapsed, 2.0, "relayout too slow: \(elapsed)s for 10 runs")
    }
}
