import XCTest
@testable import MindBlow

final class SearchTests: XCTestCase {
    func testMatchesTitleCaseInsensitively() {
        let node = MindNode(text: "Mitochondria")
        XCTAssertEqual(NodeSearch.match(node, foldedQuery: NodeSearch.fold("mito")), .title)
        XCTAssertEqual(NodeSearch.match(node, foldedQuery: NodeSearch.fold("CHOND")), .title)
    }

    func testMatchesAreDiacriticInsensitive() {
        let node = MindNode(text: "Café René")
        XCTAssertEqual(NodeSearch.match(node, foldedQuery: NodeSearch.fold("cafe")), .title)
        XCTAssertEqual(NodeSearch.match(node, foldedQuery: NodeSearch.fold("rene")), .title)
    }

    func testFieldPriorityTitleBeatsNotes() {
        // "plan" appears in both the title and the notes — title wins.
        let node = MindNode(text: "Plan", notes: "the plan body")
        XCTAssertEqual(NodeSearch.match(node, foldedQuery: NodeSearch.fold("plan")), .title)
    }

    func testMatchesNotesTagsAndLink() {
        let notesOnly = MindNode(text: "X", notes: "hidden treasure here")
        XCTAssertEqual(NodeSearch.match(notesOnly, foldedQuery: NodeSearch.fold("treasure")), .notes)

        let tagged = MindNode(text: "X", tags: ["urgent"])
        XCTAssertEqual(NodeSearch.match(tagged, foldedQuery: NodeSearch.fold("urg")), .tags)

        let linked = MindNode(text: "X", link: "https://example.com/report")
        XCTAssertEqual(NodeSearch.match(linked, foldedQuery: NodeSearch.fold("report")), .link)
    }

    func testNonMatchReturnsNil() {
        let node = MindNode(text: "Alpha", notes: "beta", tags: ["gamma"])
        XCTAssertNil(NodeSearch.match(node, foldedQuery: NodeSearch.fold("omega")))
    }

    func testSnippetSurroundsHitWithEllipses() {
        // Enough text on both sides of the hit that the window trims each end.
        let notes = String(repeating: "left padding words ", count: 3)
            + "mitochondria"
            + String(repeating: " right padding words", count: 3)
        let snippet = NodeSearch.snippet(notes, foldedQuery: NodeSearch.fold("mitochondria"))
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.localizedCaseInsensitiveContains("mitochondria"))
        // Trimmed on both sides, so ellipses top and tail it.
        XCTAssertTrue(snippet!.hasPrefix("\u{2026}"))
        XCTAssertTrue(snippet!.hasSuffix("\u{2026}"))
    }

    func testSnippetNoTrailingEllipsisWhenHitNearEnd() {
        let notes = String(repeating: "padding words here ", count: 3) + "mitochondria"
        let snippet = NodeSearch.snippet(notes, foldedQuery: NodeSearch.fold("mitochondria"))
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.hasPrefix("\u{2026}"))          // front trimmed
        XCTAssertFalse(snippet!.hasSuffix("\u{2026}"))         // hit is at the end
        XCTAssertTrue(snippet!.hasSuffix("mitochondria"))
    }

    func testSnippetNilWhenNoMatch() {
        XCTAssertNil(NodeSearch.snippet("nothing here", foldedQuery: NodeSearch.fold("xyz")))
    }
}
