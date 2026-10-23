import AppKit
import XCTest
@testable import MindBlow

final class MapCommandsTests: XCTestCase {

    private func tree() -> (root: MindNode, a: MindNode, a1: MindNode, b: MindNode) {
        var a = MindNode(text: "A")
        let a1 = MindNode(text: "A1")
        a.children = [a1]
        let b = MindNode(text: "B")
        var root = MindNode(text: "Root")
        root.children = [a, b]
        return (root, a, a1, b)
    }

    // MARK: Selection

    func testTopmostDropsMembersNestedInsideOtherMembers() {
        let t = tree()
        // Selecting both a branch and its own child must act on the branch
        // only — otherwise the child is moved (or deleted) twice.
        let ids: Set<UUID> = [t.a.id, t.a1.id, t.b.id]
        XCTAssertEqual(MapSelection.topmost(ids, in: t.root), [t.a.id, t.b.id])
    }

    func testTopmostReturnsDocumentOrder() {
        let t = tree()
        XCTAssertEqual(MapSelection.topmost([t.b.id, t.a.id], in: t.root), [t.a.id, t.b.id])
    }

    func testTopmostOfAnEmptyOrUnknownSelection() {
        let t = tree()
        XCTAssertTrue(MapSelection.topmost([], in: t.root).isEmpty)
        XCTAssertTrue(MapSelection.topmost([UUID()], in: t.root).isEmpty)
    }

    func testMarqueeSelectsIntersectingNodes() {
        let t = tree()
        let layout = MapLayout(root: t.root)
        let everything = layout.bounds.insetBy(dx: -10, dy: -10)
        XCTAssertEqual(MapSelection.inside(everything, of: layout), Set(layout.order))
        XCTAssertTrue(MapSelection.inside(
            CGRect(x: 100_000, y: 100_000, width: 10, height: 10), of: layout).isEmpty)
    }

    func testMarqueeCatchesOnlyWhatItOverlaps() throws {
        let t = tree()
        let layout = MapLayout(root: t.root)
        let target = try XCTUnwrap(layout.nodes[t.b.id])
        let hits = MapSelection.inside(target.rect.insetBy(dx: 2, dy: 2), of: layout)
        XCTAssertTrue(hits.contains(t.b.id))
        XCTAssertFalse(hits.contains(t.a1.id))
    }

    // MARK: Clipboard

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "mindblow.tests." + UUID().uuidString))
    }

    func testCopyPasteRoundTripsLosslesslyWithFreshIdentity() {
        let t = tree()
        let pb = scratchPasteboard()
        MapClipboard.write([t.a], to: pb)

        let pasted = MapClipboard.read(from: pb)
        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(pasted[0].text, "A")
        XCTAssertEqual(pasted[0].children.map(\.text), ["A1"])
        // Fresh ids, or the copy would collide with what it was copied from.
        XCTAssertNotEqual(pasted[0].id, t.a.id)
        XCTAssertTrue(pasted[0].subtreeIDs.isDisjoint(with: t.a.subtreeIDs))
    }

    func testCopyPreservesEverythingTheJSONCarries() {
        let node = MindNode(text: "Rich", notes: "body", dueDate: Date(timeIntervalSince1970: 100),
                            link: "https://example.com", tags: ["x", "y"], icon: "🚀")
        let pb = scratchPasteboard()
        MapClipboard.write([node], to: pb)
        let back = MapClipboard.read(from: pb)[0]
        XCTAssertEqual(back.notes, "body")
        XCTAssertEqual(back.link, "https://example.com")
        XCTAssertEqual(back.tags, ["x", "y"])
        XCTAssertEqual(back.icon, "🚀")
        XCTAssertEqual(back.dueDate, Date(timeIntervalSince1970: 100))
    }

    func testCopyAlsoWritesAReadableOutline() {
        let t = tree()
        let pb = scratchPasteboard()
        MapClipboard.write([t.a], to: pb)
        XCTAssertEqual(pb.string(forType: .string), "- A\n  - A1")
    }

    func testPastingForeignPlainTextParsesItAsAnOutline() {
        let pb = scratchPasteboard()
        pb.clearContents()
        pb.setString("# Notes\n- one\n  - deeper\n- two", forType: .string)
        let nodes = MapClipboard.read(from: pb)
        XCTAssertEqual(nodes.map(\.text), ["Notes"])
        XCTAssertEqual(nodes[0].children.map(\.text), ["one", "two"])
        XCTAssertEqual(nodes[0].children[0].children.map(\.text), ["deeper"])
    }

    func testPastingNothingUsefulYieldsNothing() {
        let pb = scratchPasteboard()
        pb.clearContents()
        XCTAssertTrue(MapClipboard.read(from: pb).isEmpty)
        pb.clearContents()
        pb.setString("   \n  ", forType: .string)
        XCTAssertTrue(MapClipboard.read(from: pb).isEmpty)
    }

    func testWritingNothingLeavesThePasteboardAlone() {
        let pb = scratchPasteboard()
        pb.clearContents()
        pb.setString("keep me", forType: .string)
        MapClipboard.write([], to: pb)
        XCTAssertEqual(pb.string(forType: .string), "keep me")
    }

    func testCopyingSeveralTopicsKeepsThemSeparate() {
        let t = tree()
        let pb = scratchPasteboard()
        MapClipboard.write([t.a, t.b], to: pb)
        let back = MapClipboard.read(from: pb)
        XCTAssertEqual(back.map(\.text), ["A", "B"])
        XCTAssertEqual(back[0].children.count, 1)
    }

    // MARK: Focus

    func testFocusingAlaysLaysTheSubtreeOutAsItsOwnMap() {
        let t = tree()
        let subtree = try? XCTUnwrap(t.root.node(with: t.a.id))
        let focused = MapLayout(root: try! XCTUnwrap(subtree))
        // Only the branch is placed, and it sits at the center as level 0.
        XCTAssertEqual(Set(focused.order), t.a.subtreeIDs)
        XCTAssertEqual(focused.nodes[t.a.id]?.level, 0)
        XCTAssertEqual(focused.rootID, t.a.id)
        XCTAssertNil(focused.nodes[t.b.id])
    }

    func testLinkCurveAnchorsOnTheEdgeFacingTheOtherEnd() {
        let rect = CGRect(x: -50, y: -20, width: 100, height: 40)
        let right = LinkCurve.anchor(on: rect, toward: CGPoint(x: 500, y: 0))
        XCTAssertEqual(right.x, 50, accuracy: 0.001)
        XCTAssertEqual(right.y, 0, accuracy: 0.001)
        let up = LinkCurve.anchor(on: rect, toward: CGPoint(x: 0, y: -500))
        XCTAssertEqual(up.y, -20, accuracy: 0.001)
        // Degenerate case: a target on the center returns the center.
        XCTAssertEqual(LinkCurve.anchor(on: rect, toward: CGPoint(x: 0, y: 0)), .zero)
    }

    func testLinkCurveBowsOffTheStraightLine() {
        let from = CGPoint(x: 0, y: 0), to = CGPoint(x: 200, y: 0)
        let control = LinkCurve.control(from: from, to: to)
        XCTAssertEqual(control.x, 100, accuracy: 0.001)
        XCTAssertNotEqual(control.y, 0, "a connector that traces the straight line is invisible")
        // The midpoint follows the bow rather than the chord.
        let mid = LinkCurve.midpoint(from: from, to: to, control: control)
        XCTAssertEqual(mid.x, 100, accuracy: 0.001)
        XCTAssertGreaterThan(abs(mid.y), 0)
    }
}
