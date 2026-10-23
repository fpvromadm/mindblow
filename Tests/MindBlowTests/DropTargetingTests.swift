import XCTest
import SwiftUI
@testable import MindBlow

/// The pointer-only drop test could only reach a node's own rect (± a few
/// points), but siblings are spaced by `vGap` between their *subtree spans*.
/// Once branches have children the rect-to-rect gap dwarfs that margin, so
/// most of the sibling column was dead and a drop there fell through to the
/// "swap sides" fallback instead of reordering.
final class DropTargetingTests: XCTestCase {

    /// Root with four right-side branches, each carrying `childrenPerBranch`
    /// children so the sibling gaps are span-sized rather than tight.
    private func tree(childrenPerBranch: Int) -> MindNode {
        var root = MindNode(text: "Root")
        root.children = ["Alpha", "Beta", "Gamma", "Delta"].map { text in
            var n = MindNode(text: text)
            n.side = .right
            n.children = (0..<childrenPerBranch).map { MindNode(text: "\(text).\($0)") }
            return n
        }
        return root
    }

    private struct Fixture {
        let root: MindNode
        let layout: MapLayout
        /// Screen rects, identity transform (zoom 1, no pan, origin at 0).
        let rect: (UUID) -> CGRect?

        func id(_ name: String) -> UUID {
            root.children.first { $0.text == name }!.id
        }
        func box(_ name: String) -> CGRect { rect(id(name))! }
    }

    private func fixture(childrenPerBranch: Int = 3) -> Fixture {
        let root = tree(childrenPerBranch: childrenPerBranch)
        let layout = MapLayout(root: root)
        return Fixture(root: root, layout: layout, rect: { layout.nodes[$0]?.rect })
    }

    private func indicator(_ f: Fixture, at point: CGPoint,
                           dragging dragged: Set<UUID> = []) -> DropIndicator? {
        DropTargeting.indicator(at: point, order: f.layout.order,
                                rootID: f.root.id, excluding: dragged, rect: f.rect)
    }

    // MARK: The regression

    func testGapBetweenSiblingsResolvesToAnInsertion() {
        let f = fixture()
        let alpha = f.box("Alpha")
        let beta = f.box("Beta")
        XCTAssertGreaterThan(beta.minY - alpha.maxY, 60,
                             "fixture must have a span-sized gap to be meaningful")
        // Dead centre of the gap — the point that used to return nil.
        let point = CGPoint(x: alpha.midX, y: (alpha.maxY + beta.minY) / 2)
        let result = indicator(f, at: point, dragging: [f.id("Delta")])
        XCTAssertNotNil(result, "a drop in the sibling gap must resolve to an insertion")
        XCTAssertTrue(result?.mode == .after || result?.mode == .before)
    }

    func testEveryPointInTheSiblingColumnIsLive() {
        let f = fixture(childrenPerBranch: 5)
        let alpha = f.box("Alpha")
        let gamma = f.box("Gamma")
        var dead: [CGFloat] = []
        var y = alpha.minY
        while y <= gamma.maxY {
            if indicator(f, at: CGPoint(x: alpha.midX, y: y),
                         dragging: [f.id("Delta")]) == nil {
                dead.append(y)
            }
            y += 1
        }
        XCTAssertTrue(dead.isEmpty, "\(dead.count)pt of the column is unreachable")
    }

    // MARK: Behaviour that must survive the change

    func testInsideANodeReParents() {
        let f = fixture()
        let beta = f.box("Beta")
        let result = indicator(f, at: CGPoint(x: beta.midX, y: beta.midY),
                               dragging: [f.id("Delta")])
        XCTAssertEqual(result?.mode, .child)
        XCTAssertEqual(result?.id, f.id("Beta"))
    }

    func testTopEdgeOfANodeInsertsBeforeIt() {
        let f = fixture()
        let beta = f.box("Beta")
        let result = indicator(f, at: CGPoint(x: beta.midX, y: beta.minY + 2),
                               dragging: [f.id("Delta")])
        XCTAssertEqual(result?.mode, .before)
        XCTAssertEqual(result?.id, f.id("Beta"))
    }

    func testBottomEdgeOfANodeInsertsAfterIt() {
        let f = fixture()
        let beta = f.box("Beta")
        let result = indicator(f, at: CGPoint(x: beta.midX, y: beta.maxY - 2),
                               dragging: [f.id("Delta")])
        XCTAssertEqual(result?.mode, .after)
        XCTAssertEqual(result?.id, f.id("Beta"))
    }

    /// "Drop past the root" still has to mean "move the branch to that side",
    /// which needs a nil here so EditorView reaches its fallback.
    func testPointOutsideEveryColumnIsNotADropTarget() {
        let f = fixture()
        let alpha = f.box("Alpha")
        let point = CGPoint(x: alpha.minX - 400, y: alpha.midY)
        XCTAssertNil(indicator(f, at: point, dragging: [f.id("Delta")]))
    }

    func testTheDraggedSubtreeIsNeverADropTarget() {
        let f = fixture()
        let beta = f.box("Beta")
        let betaSubtree = f.root.children.first { $0.text == "Beta" }!.subtreeIDs
        let result = indicator(f, at: CGPoint(x: beta.midX, y: beta.midY),
                               dragging: betaSubtree)
        XCTAssertNotEqual(result?.id, f.id("Beta"))
    }

    /// The root has no siblings to sit beside, so it can only ever be a parent.
    func testRootNeverTakesABeforeOrAfter() {
        let f = fixture()
        let rootRect = f.rect(f.root.id)!
        for y in [rootRect.minY + 1, rootRect.midY, rootRect.maxY - 1] {
            let result = indicator(f, at: CGPoint(x: rootRect.midX, y: y),
                                   dragging: [f.id("Delta")])
            if result?.id == f.root.id {
                XCTAssertEqual(result?.mode, .child)
            }
        }
    }
}
