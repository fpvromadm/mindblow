import XCTest
@testable import MindBlow

final class ModelTests: XCTestCase {
    private func sampleTree() -> MindNode {
        var root = MindNode(text: "Root")
        var a = MindNode(text: "A")
        a.children = [MindNode(text: "A1"), MindNode(text: "A2")]
        let b = MindNode(text: "B")
        root.children = [a, b]
        return root
    }

    func testFind() {
        let root = sampleTree()
        let a1 = root.children[0].children[0]
        XCTAssertEqual(root.node(with: a1.id)?.text, "A1")
        XCTAssertNil(root.node(with: UUID()))
    }

    func testParentID() {
        let root = sampleTree()
        let a = root.children[0]
        let a2 = a.children[1]
        XCTAssertEqual(root.parentID(of: a2.id), a.id)
        XCTAssertEqual(root.parentID(of: a.id), root.id)
        XCTAssertNil(root.parentID(of: root.id))
    }

    func testUpdate() {
        var root = sampleTree()
        let a1 = root.children[0].children[0]
        XCTAssertTrue(root.update(a1.id) { $0.text = "renamed" })
        XCTAssertEqual(root.node(with: a1.id)?.text, "renamed")
        XCTAssertFalse(root.update(UUID()) { $0.text = "nope" })
    }

    func testUpdateCommitsToCorrectNodeOnly() {
        // Regression guard for the "Enter wipes the previous node" bug:
        // committing text to one node must never alter any other node.
        var root = sampleTree()
        let a = root.children[0]
        let b = root.children[1]
        root.update(b.id) { $0.text = "" }
        XCTAssertEqual(root.node(with: a.id)?.text, "A")
        XCTAssertEqual(root.node(with: a.children[0].id)?.text, "A1")
    }

    func testRemoveSubtree() {
        var root = sampleTree()
        let a = root.children[0]
        root.remove(a.id)
        XCTAssertNil(root.node(with: a.id))
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children[0].text, "B")
    }

    func testJSONRoundTrip() throws {
        let root = sampleTree()
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(MindNode.self, from: data)
        XCTAssertEqual(decoded, root)
    }

    func testClosedRoundTripAndDefaults() throws {
        var root = sampleTree()
        let a = root.children[0]
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        root.update(a.id) { $0.closedAt = stamp }
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(MindNode.self, from: data)
        XCTAssertEqual(decoded, root)
        XCTAssertEqual(decoded.node(with: a.id)?.closedAt, stamp)

        // Old documents (no closedAt key) decode as open, and an open node
        // encodes without the key so untouched files stay byte-identical.
        let openData = try JSONEncoder().encode(sampleTree())
        XCTAssertFalse(String(data: openData, encoding: .utf8)!.contains("closedAt"))
    }

    func testOpenAndClosedChildren() {
        var root = sampleTree()
        let a = root.children[0]
        XCTAssertEqual(root.openChildren.count, 2)
        XCTAssertTrue(root.closedChildren.isEmpty)
        root.update(a.id) { $0.closedAt = Date() }
        XCTAssertEqual(root.openChildren.map(\.text), ["B"])
        XCTAssertEqual(root.closedChildren.map(\.text), ["A"])
        // Descendants of a closed node are never stamped.
        XCTAssertNil(root.node(with: a.children[0].id)?.closedAt)
    }
}
