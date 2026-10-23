import XCTest
import SwiftUI
@testable import MindBlow

/// Siblings hang off their parent at a fixed gap, so they share an edge: the
/// near edge, whichever side they are on. A branch that drifted out of that
/// column would be a real layout bug — this pins the invariant across subtree
/// sizes, due-date clearance, and mixed sides.
final class SiblingAlignmentTests: XCTestCase {

    private func assertSiblingsShareTheirNearEdge(_ root: MindNode,
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) {
        let layout = MapLayout(root: root)
        func walk(_ node: MindNode) {
            let placed = node.openChildren.compactMap { child -> (String, NodeGeom)? in
                guard let geom = layout.nodes[child.id] else { return nil }
                return (child.text, geom)
            }
            // Root children fan out both ways, so group by the side they took.
            for side in [Side.left, Side.right] {
                let group = placed.filter { $0.1.side == side }
                guard group.count > 1 else { continue }
                let edges = group.map { side == .right ? $0.1.rect.minX : $0.1.rect.maxX }
                let spread = edges.max()! - edges.min()!
                XCTAssertEqual(spread, 0, accuracy: 0.01,
                               "children of \"\(node.text)\" on the \(side) do not share a column: "
                               + group.map { "\($0.0)=\($0.1.rect)" }.joined(separator: ", "),
                               file: file, line: line)
            }
            node.openChildren.forEach(walk)
        }
        walk(root)
    }

    /// The shape from the screenshot: one sibling carrying a deep subtree, the
    /// other a leaf with a due date, both hanging off the same parent.
    func testALeafSiblingStaysInColumnBesideADeepOne() {
        var deep = MindNode(text: "2026 Project Milestones")
        var meetings = MindNode(text: "Feedback Meetings")
        meetings.dueDate = Date(timeIntervalSince1970: 1_786_000_000)
        meetings.children = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].map {
            var n = MindNode(text: "2026 Q1 \($0)")
            n.dueDate = Date(timeIntervalSince1970: 1_786_000_000)
            return n
        }
        deep.children = [meetings]

        var training = MindNode(text: "Onboarding Workshop")
        training.dueDate = Date(timeIntervalSince1970: 1_786_600_000)
        training.tags = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]

        var team = MindNode(text: "Team")
        team.side = .left
        team.children = [deep, training]

        var root = MindNode(text: "Workspace")
        root.children = [team]
        assertSiblingsShareTheirNearEdge(root)

        // And the specific claim: the two children of Team line up.
        let layout = MapLayout(root: root)
        let a = layout.nodes[deep.id]!.rect
        let b = layout.nodes[training.id]!.rect
        XCTAssertEqual(a.maxX, b.maxX, accuracy: 0.01,
                       "left-side siblings must share their right edge")
    }

    func testDeepMixedTreeKeepsEverySiblingGroupInColumn() {
        func make(_ level: Int, _ label: String) -> MindNode {
            var n = MindNode(text: "Topic \(label)")
            if level < 3 { n.children = (0..<3).map { make(level + 1, "\(label).\($0)") } }
            if level == 2 { n.dueDate = Date(timeIntervalSince1970: 1_786_000_000) }
            return n
        }
        var root = MindNode(text: "Root")
        root.children = (0..<6).map { make(1, "\($0)") }
        assertSiblingsShareTheirNearEdge(root)
    }
}
