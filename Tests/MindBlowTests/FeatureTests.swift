import XCTest
import SwiftUI
@testable import MindBlow

final class FeatureTests: XCTestCase {
    func testLegacyFilesWithoutNewFieldsStillLoad() throws {
        let legacy = """
        {
          "id" : "E6D58866-2915-42CA-815F-3239E196E0F2",
          "isCollapsed" : false,
          "text" : "Central Topic",
          "children" : [
            { "id" : "66542C34-8565-4D7D-B2DB-AB49D9580228",
              "isCollapsed" : false, "text" : "Old child", "children" : [] }
          ]
        }
        """
        let node = try JSONDecoder().decode(MindNode.self, from: Data(legacy.utf8))
        XCTAssertEqual(node.text, "Central Topic")
        XCTAssertNil(node.colorIndex)
        XCTAssertEqual(node.notes, "")
        XCTAssertEqual(node.children.first?.text, "Old child")
    }

    func testColorAndNotesRoundTrip() throws {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "A", colorIndex: 3, notes: "# Heading\n- point one")]
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(MindNode.self, from: data)
        XCTAssertEqual(decoded, root)
        XCTAssertEqual(decoded.children[0].colorIndex, 3)
        XCTAssertEqual(decoded.children[0].notes, "# Heading\n- point one")
    }

    func testEmptyNotesAreOmittedFromJSON() throws {
        let data = try JSONEncoder().encode(MindNode(text: "plain"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("notes"))
        XCTAssertFalse(json.contains("colorIndex"))
    }

    /// The agenda's derived cache invalidates by comparing the document tree,
    /// so a due-date-only change MUST make the tree compare unequal. If it
    /// didn't, the sidebar would keep showing the old date after an edit —
    /// the exact bug this guards.
    func testDueDateChangeMakesTreeUnequal() {
        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = Date(timeIntervalSince1970: 1_700_600_000)
        var a = MindNode(text: "Root")
        a.children = [MindNode(text: "Task", dueDate: date1)]
        var b = a
        XCTAssertEqual(a, b, "identical trees compare equal")
        b.children[0].dueDate = date2
        XCTAssertNotEqual(a, b, "a due-date-only change must be observable via ==")
    }

    /// "Expand to filter matches" is the filter-aware expand: branches leading
    /// to a tagged match open, branches with no match collapse.
    func testExpandToMatchesLogic() {
        // Root ─┬─ Alpha (#keep) ── AlphaChild
        //       └─ Beta ── BetaChild (no tags)
        var alpha = MindNode(text: "Alpha", tags: ["keep"])
        alpha.children = [MindNode(text: "AlphaChild")]
        var beta = MindNode(text: "Beta")
        beta.children = [MindNode(text: "BetaChild")]
        var root = MindNode(text: "Root")
        root.children = [alpha, beta]

        let active: Set<String> = ["keep"]
        func matches(_ n: MindNode) -> Bool { !active.isDisjoint(with: Set(n.tags)) }
        @discardableResult
        func walk(_ node: inout MindNode) -> Bool {
            var hit = matches(node)
            for i in node.children.indices where walk(&node.children[i]) { hit = true }
            if !node.children.isEmpty { node.isCollapsed = !hit }
            return hit
        }
        walk(&root)

        XCTAssertFalse(root.isCollapsed, "root leads to a match → open")
        XCTAssertFalse(root.children[0].isCollapsed, "Alpha matches → open")
        XCTAssertTrue(root.children[1].isCollapsed, "Beta has no match in its subtree → collapsed")
    }

    func testColorOverrideWinsOverLevelColor() {
        var root = MindNode(text: "Root")
        root.children = [
            MindNode(text: "default"),
            MindNode(text: "override", colorIndex: 4),
        ]
        let layout = MapLayout(root: root)
        let defaultGeom = layout.nodes[root.children[0].id]!
        let overrideGeom = layout.nodes[root.children[1].id]!
        XCTAssertEqual(defaultGeom.color, Palette.branch(0), "level default")
        XCTAssertEqual(overrideGeom.color, Palette.branches[4], "explicit override")
    }

    func testInvalidColorIndexFallsBackToLevelColor() {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "bad", colorIndex: 99)]
        let layout = MapLayout(root: root)
        XCTAssertEqual(layout.nodes[root.children[0].id]?.color, Palette.branch(0))
    }

    func testNotesFlagInLayout() {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "with", notes: "hello"), MindNode(text: "without")]
        let layout = MapLayout(root: root)
        XCTAssertTrue(layout.nodes[root.children[0].id]!.hasNotes)
        XCTAssertFalse(layout.nodes[root.children[1].id]!.hasNotes)
    }
}

final class NodeDetailsTests: XCTestCase {
    func testDueDateLinkTagsRoundTrip() throws {
        var root = MindNode(text: "Root")
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        root.children = [MindNode(text: "A", dueDate: due, link: "https://apple.com", tags: ["work", "q3"])]
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(MindNode.self, from: data)
        XCTAssertEqual(decoded, root)
        XCTAssertEqual(decoded.children[0].tags, ["work", "q3"])
        XCTAssertEqual(decoded.children[0].link, "https://apple.com")
        XCTAssertEqual(decoded.children[0].dueDate, due)
    }

    func testEmptyDetailsOmittedFromJSON() throws {
        let data = try JSONEncoder().encode(MindNode(text: "plain"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("dueDate"))
        XCTAssertFalse(json.contains("link"))
        XCTAssertFalse(json.contains("tags"))
    }

    func testMetaChipsGrowNodeHeight() {
        let plain = MindNode(text: "Topic")
        let withDue = MindNode(text: "Topic", dueDate: Date())
        let withTags = MindNode(text: "Topic", tags: ["one", "two"])
        let plainSize = Metrics.nodeSize(for: plain, level: 1)
        // Due date renders as a corner badge — it must NOT change node size.
        XCTAssertEqual(Metrics.nodeSize(for: withDue, level: 1).height, plainSize.height)
        XCTAssertGreaterThan(Metrics.nodeSize(for: withTags, level: 1).height, plainSize.height)
        XCTAssertGreaterThan(Metrics.nodeSize(for: withTags, level: 1).width, 0)
    }

    func testGeometryCarriesDetails() {
        var root = MindNode(text: "Root")
        let due = Date()
        root.children = [MindNode(text: "A", dueDate: due, link: "https://x.com", tags: ["t1"])]
        let layout = MapLayout(root: root)
        let geom = layout.nodes[root.children[0].id]!
        XCTAssertEqual(geom.dueDate, due)
        XCTAssertEqual(geom.link, "https://x.com")
        XCTAssertEqual(geom.tags, ["t1"])
    }
}

final class SideBalanceTests: XCTestCase {
    func testForcedSideIsHonored() {
        var root = MindNode(text: "Root")
        root.children = [
            MindNode(text: "A", side: .left),
            MindNode(text: "B", side: .left),
            MindNode(text: "C", side: .right),
        ]
        let layout = MapLayout(root: root)
        XCTAssertEqual(layout.nodes[root.children[0].id]?.side, .left)
        XCTAssertEqual(layout.nodes[root.children[1].id]?.side, .left)
        XCTAssertEqual(layout.nodes[root.children[2].id]?.side, .right)
    }

    func testAutoBranchesBalanceBothSides() {
        var root = MindNode(text: "Root")
        root.children = (0..<6).map { MindNode(text: "Node \($0)") }
        let layout = MapLayout(root: root)
        let sides = root.children.compactMap { layout.nodes[$0.id]?.side }
        XCTAssertTrue(sides.contains(.left) && sides.contains(.right))
        let leftCount = sides.filter { $0 == .left }.count
        XCTAssertTrue((2...4).contains(leftCount), "roughly even split, got \(leftCount) left")
    }

    func testSideRoundTrip() throws {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "A", side: .left)]
        let decoded = try JSONDecoder().decode(MindNode.self, from: JSONEncoder().encode(root))
        XCTAssertEqual(decoded.children[0].side, .left)
    }
}

final class DueClearanceTests: XCTestCase {
    func testSiblingsWithDueDatesGetExtraGap() {
        var root = MindNode(text: "Root")
        root.children = [
            MindNode(text: "First", side: .right),
            MindNode(text: "Second", side: .right, children: []),
        ]
        root.children[1].dueDate = Date()
        let layout = MapLayout(root: root)
        let first = layout.nodes[root.children[0].id]!.rect
        let second = layout.nodes[root.children[1].id]!.rect
        let gap = second.minY - first.maxY
        XCTAssertGreaterThanOrEqual(gap, Metrics.vGap + Metrics.dueClearance - 0.5,
                                    "chip needs headroom above the dated node, gap was \(gap)")
    }
}

final class CollapsedDueTests: XCTestCase {
    func testCollapsedBranchExposesEarliestDescendantDue() {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_900_000_000)
        var branch = MindNode(text: "Branch", isCollapsed: true)
        let earlyNode = MindNode(text: "Early", dueDate: early)
        branch.children = [
            MindNode(text: "Late", dueDate: late),
            MindNode(text: "Deep", children: [earlyNode]),
        ]
        var root = MindNode(text: "Root")
        root.children = [branch]
        let layout = MapLayout(root: root)
        let info = layout.nodes[branch.id]?.collapsedDue
        XCTAssertEqual(info?.date, early)
        XCTAssertEqual(info?.nodeID, earlyNode.id)
    }

    func testExpandedBranchHasNoRollup() {
        var branch = MindNode(text: "Branch")
        branch.children = [MindNode(text: "Child", dueDate: Date())]
        var root = MindNode(text: "Root")
        root.children = [branch]
        let layout = MapLayout(root: root)
        XCTAssertNil(layout.nodes[branch.id]?.collapsedDue)
    }
}
