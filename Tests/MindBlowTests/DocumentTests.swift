import AppKit
import XCTest
@testable import MindBlow

final class DocumentTests: XCTestCase {

    // MARK: File format

    func testAMapWithoutLinksStillWritesTheBareRootNode() throws {
        // Backward compatibility runs both ways: older builds must be able to
        // open anything this one saves as long as no cross-link is involved.
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "A")]
        let data = try MindMapDocument(root: root).encoded()
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "Root")
        XCTAssertNil(json["root"])
    }

    func testAMapWithLinksWritesTheWrapper() throws {
        var root = MindNode(text: "Root")
        let a = MindNode(text: "A")
        let b = MindNode(text: "B")
        root.children = [a, b]
        var doc = MindMapDocument(root: root)
        doc.links = [MindLink(from: a.id, to: b.id, label: "relates")]

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try doc.encoded()) as? [String: Any])
        XCTAssertNotNil(json["root"])
        XCTAssertEqual((json["links"] as? [Any])?.count, 1)
    }

    func testReadsBothTheBareAndWrappedForms() throws {
        var root = MindNode(text: "Root")
        let a = MindNode(text: "A")
        let b = MindNode(text: "B")
        root.children = [a, b]

        let bare = try MindMapDocument(root: root).encoded()
        XCTAssertEqual(try MindMapDocument.decode(bare).root.text, "Root")
        XCTAssertTrue(try MindMapDocument.decode(bare).links.isEmpty)

        var linked = MindMapDocument(root: root)
        linked.links = [MindLink(from: a.id, to: b.id)]
        let round = try MindMapDocument.decode(try linked.encoded())
        XCTAssertEqual(round.root, root)
        XCTAssertEqual(round.links.count, 1)
        XCTAssertEqual(round.links[0].from, a.id)
    }

    func testLoadingDropsLinksWhoseEndpointsAreGone() throws {
        var root = MindNode(text: "Root")
        let a = MindNode(text: "A")
        root.children = [a]
        var doc = MindMapDocument(root: root)
        doc.links = [MindLink(from: a.id, to: UUID())]
        XCTAssertTrue(try MindMapDocument.decode(try doc.encoded()).links.isEmpty)
    }

    // MARK: Link pruning

    func testPruneDropsSelfLinksAndDuplicates() {
        var root = MindNode(text: "Root")
        let a = MindNode(text: "A")
        let b = MindNode(text: "B")
        root.children = [a, b]
        var doc = MindMapDocument(root: root)
        doc.links = [
            MindLink(from: a.id, to: b.id),
            MindLink(from: b.id, to: a.id),   // same relation, other direction
            MindLink(from: a.id, to: a.id),   // a topic can't relate to itself
        ]
        doc.pruneDanglingLinks()
        XCTAssertEqual(doc.links.count, 1)
        XCTAssertEqual(doc.links[0].from, a.id)
    }

    func testPruneFollowsADeletedSubtree() {
        var root = MindNode(text: "Root")
        var a = MindNode(text: "A")
        let a1 = MindNode(text: "A1")
        a.children = [a1]
        let b = MindNode(text: "B")
        root.children = [a, b]
        var doc = MindMapDocument(root: root)
        doc.links = [MindLink(from: a1.id, to: b.id)]

        doc.root.remove(a.id)
        doc.pruneDanglingLinks()
        XCTAssertTrue(doc.links.isEmpty, "a link into a deleted subtree must not survive")
    }

    func testLinksTouchingFindsBothDirections() {
        let a = MindNode(text: "A"), b = MindNode(text: "B"), c = MindNode(text: "C")
        var root = MindNode(text: "Root")
        root.children = [a, b, c]
        var doc = MindMapDocument(root: root)
        doc.links = [MindLink(from: a.id, to: b.id), MindLink(from: c.id, to: a.id)]
        XCTAssertEqual(doc.links(touching: a.id).count, 2)
        XCTAssertEqual(doc.links(touching: b.id).count, 1)
    }

    // MARK: Subtree helpers

    func testRekeyedGivesEverythingFreshIdentity() {
        var node = MindNode(text: "A", image: NodeImage(data: Data([1, 2]), pixelWidth: 2, pixelHeight: 2))
        node.children = [MindNode(text: "A1"), MindNode(text: "A2")]
        let copy = node.rekeyed()

        XCTAssertNotEqual(copy.id, node.id)
        XCTAssertTrue(copy.subtreeIDs.isDisjoint(with: node.subtreeIDs))
        XCTAssertEqual(copy.text, "A")
        XCTAssertEqual(copy.children.map(\.text), ["A1", "A2"])
        XCTAssertNotEqual(copy.image?.id, node.image?.id)
        XCTAssertEqual(copy.image?.data, node.image?.data)
    }

    func testSubtreeCount() {
        var root = MindNode(text: "Root")
        var a = MindNode(text: "A")
        a.children = [MindNode(text: "A1"), MindNode(text: "A2")]
        root.children = [a, MindNode(text: "B")]
        XCTAssertEqual(root.subtreeCount, 5)
        XCTAssertEqual(a.subtreeCount, 3)
    }

    // MARK: Progress

    func testProgressCountsOnlyDescendants() {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "A"), MindNode(text: "B")]
        XCTAssertEqual(root.progress, SubtreeProgress(done: 0, total: 2))
        XCTAssertEqual(root.children[0].progress, SubtreeProgress(done: 0, total: 0))
    }

    func testClosingATopicCountsItsWholeSubtreeAsDone() {
        // Descendants of a closed node are closed implicitly and never stamped,
        // so they have to be counted through the ancestor.
        var branch = MindNode(text: "Branch", closedAt: Date())
        branch.children = [MindNode(text: "B1"), MindNode(text: "B2")]
        var root = MindNode(text: "Root")
        root.children = [branch, MindNode(text: "Open")]
        XCTAssertEqual(root.progress, SubtreeProgress(done: 3, total: 4))
    }

    func testProgressFractionAndEmptiness() {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "A", closedAt: Date()), MindNode(text: "B")]
        XCTAssertEqual(root.progress.fraction, 0.5, accuracy: 0.0001)
        XCTAssertTrue(MindNode(text: "leaf").progress.isEmpty)
    }

    func testLayoutPublishesTheSameProgressAsTheModel() {
        var deep = MindNode(text: "Deep")
        deep.children = [MindNode(text: "D1", closedAt: Date()), MindNode(text: "D2")]
        var a = MindNode(text: "A")
        a.children = [deep, MindNode(text: "A2", closedAt: Date())]
        var root = MindNode(text: "Root")
        root.children = [a]

        let layout = MapLayout(root: root)
        XCTAssertEqual(layout.nodes[root.id]?.progress, root.progress)
        XCTAssertEqual(layout.nodes[a.id]?.progress, a.progress)
        XCTAssertEqual(layout.nodes[a.id]?.progress, SubtreeProgress(done: 2, total: 4))
    }

    // MARK: Images

    func testImageEqualityIgnoresBytes() {
        // Identity, not content: the document equality check runs on every body
        // evaluation and must not memcmp megabytes.
        let id = UUID()
        let a = NodeImage(id: id, data: Data([1, 2, 3]), pixelWidth: 4, pixelHeight: 2)
        let b = NodeImage(id: id, data: Data(repeating: 9, count: 5000), pixelWidth: 4, pixelHeight: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, NodeImage(data: Data([1, 2, 3]), pixelWidth: 4, pixelHeight: 2))
    }

    func testImageDisplaySizePreservesAspectAndNeverUpscales() {
        let wide = NodeImage(data: Data(), pixelWidth: 400, pixelHeight: 200)
        XCTAssertEqual(wide.displaySize(maxWidth: 200), CGSize(width: 200, height: 100))
        let small = NodeImage(data: Data(), pixelWidth: 60, pixelHeight: 30)
        XCTAssertEqual(small.displaySize(maxWidth: 200), CGSize(width: 60, height: 30))
        XCTAssertEqual(NodeImage(data: Data(), pixelWidth: 0, pixelHeight: 0)
            .displaySize(maxWidth: 200), .zero)
    }

    func testImportDownscalesLargeImages() throws {
        let big = NSImage(size: NSSize(width: 2000, height: 1000))
        big.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 2000, height: 1000).fill()
        big.unlockFocus()

        let stored = try XCTUnwrap(ImageStore.prepare(big))
        XCTAssertEqual(max(stored.pixelWidth, stored.pixelHeight),
                       Int(ImageStore.maxPixelEdge))
        XCTAssertEqual(Double(stored.pixelWidth) / Double(stored.pixelHeight), 2, accuracy: 0.02)
        XCTAssertFalse(stored.data.isEmpty)
        XCTAssertNotNil(ImageStore.image(for: stored))
    }

    func testImportLeavesSmallImagesAtTheirOwnSize() throws {
        let small = NSImage(size: NSSize(width: 120, height: 80))
        small.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 80).fill()
        small.unlockFocus()

        let stored = try XCTUnwrap(ImageStore.prepare(small))
        XCTAssertEqual(stored.pixelWidth, 120)
        XCTAssertEqual(stored.pixelHeight, 80)
    }

    func testAnImageWidensTheNodeAndMakesItTaller() {
        let plain = MindNode(text: "Topic")
        let withImage = MindNode(text: "Topic",
                                 image: NodeImage(data: Data(), pixelWidth: 400, pixelHeight: 300))
        let a = Metrics.nodeSize(for: plain, level: 2)
        let b = Metrics.nodeSize(for: withImage, level: 2)
        XCTAssertGreaterThan(b.height, a.height)
        XCTAssertGreaterThan(b.width, a.width)
    }

    func testAnIconWidensTheNodeWithoutChangingItsHeight() {
        let plain = MindNode(text: "Topic")
        let withIcon = MindNode(text: "Topic", icon: "🚀")
        let a = Metrics.nodeSize(for: plain, level: 2)
        let b = Metrics.nodeSize(for: withIcon, level: 2)
        XCTAssertEqual(b.height, a.height)
        XCTAssertEqual(b.width, a.width + Metrics.iconWidth(for: 2) + Metrics.iconGap)
    }

    func testDocumentCarriesImagesAndIconsThroughASaveCycle() throws {
        var root = MindNode(text: "Root", icon: "🧠")
        root.children = [MindNode(
            text: "Pic",
            image: NodeImage(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), pixelWidth: 8, pixelHeight: 4)
        )]
        let round = try MindMapDocument.decode(try MindMapDocument(root: root).encoded())
        XCTAssertEqual(round.root.icon, "🧠")
        XCTAssertEqual(round.root.children[0].image?.data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(round.root.children[0].image?.pixelWidth, 8)
    }
}
