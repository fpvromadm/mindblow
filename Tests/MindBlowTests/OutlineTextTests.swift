import XCTest
@testable import MindBlow

final class OutlineTextTests: XCTestCase {

    // MARK: Serialize

    func testSerializeNestsWithTwoSpacesPerLevel() {
        var root = MindNode(text: "Root")
        var a = MindNode(text: "A")
        a.children = [MindNode(text: "A1")]
        root.children = [a, MindNode(text: "B")]
        XCTAssertEqual(OutlineText.serialize(root), """
        - Root
          - A
            - A1
          - B
        """)
    }

    func testSerializeCarriesIconAndTags() {
        let node = MindNode(text: "Launch", tags: ["q3", "team"], icon: "🚀")
        XCTAssertEqual(OutlineText.serialize(node), "- 🚀 Launch #q3 #team")
    }

    func testSerializeSkipsClosedUnlessAsked() {
        var root = MindNode(text: "Root")
        root.children = [MindNode(text: "Done", closedAt: Date()), MindNode(text: "Open")]
        XCTAssertEqual(OutlineText.serialize(root), "- Root\n  - Open")
        XCTAssertEqual(OutlineText.serialize(root, includeClosed: true),
                       "- Root\n  - [x] Done\n  - Open")
    }

    func testSerializeQuotesNotesWhenAsked() {
        var root = MindNode(text: "Root", notes: "line one\nline two")
        root.children = []
        XCTAssertEqual(OutlineText.serialize(root, includeNotes: true),
                       "- Root\n  > line one\n  > line two")
    }

    func testNotesDoNotComeBackAsTopics() {
        // A note indented like a bullet would sit at exactly a child's depth,
        // so the export quotes it and the parser skips quotes.
        var root = MindNode(text: "Root", notes: "some prose")
        root.children = [MindNode(text: "Real child")]
        let parsed = OutlineText.parse(OutlineText.serialize(root, includeNotes: true))
        XCTAssertEqual(parsed.map(\.text), ["Root"])
        XCTAssertEqual(parsed[0].children.map(\.text), ["Real child"])
    }

    // MARK: Parse

    func testParsesIndentedBullets() {
        let forest = OutlineText.parse("""
        - A
          - A1
          - A2
        - B
        """)
        XCTAssertEqual(forest.map(\.text), ["A", "B"])
        XCTAssertEqual(forest[0].children.map(\.text), ["A1", "A2"])
    }

    func testParsesTabsAndSpacesInterchangeably() {
        // A tab advances to the next multiple of four, so these two children
        // sit at the same depth even though one is tabbed and one is spaced.
        let forest = OutlineText.parse("- A\n\t- tabbed\n    - spaced")
        XCTAssertEqual(forest.count, 1)
        XCTAssertEqual(forest[0].children.map(\.text), ["tabbed", "spaced"])
    }

    func testParsesHeadingsAndBulletsTogether() {
        let forest = OutlineText.parse("""
        # Project
        ## Phase one
        - task a
        - task b
        ## Phase two
        - task c
        """)
        XCTAssertEqual(forest.map(\.text), ["Project"])
        let phases = forest[0].children
        XCTAssertEqual(phases.map(\.text), ["Phase one", "Phase two"])
        XCTAssertEqual(phases[0].children.map(\.text), ["task a", "task b"])
        XCTAssertEqual(phases[1].children.map(\.text), ["task c"])
    }

    func testParsesNumberedListsAndPlainIndentedText() {
        let forest = OutlineText.parse("""
        1. First
           deeper
        2) Second
        """)
        XCTAssertEqual(forest.map(\.text), ["First", "Second"])
        XCTAssertEqual(forest[0].children.map(\.text), ["deeper"])
    }

    func testBlankLinesAreIgnored() {
        let forest = OutlineText.parse("- A\n\n\n  - B\n\n")
        XCTAssertEqual(forest.count, 1)
        XCTAssertEqual(forest[0].children.map(\.text), ["B"])
    }

    func testParsesCheckboxesAsClosedTopics() {
        let forest = OutlineText.parse("- [x] shipped\n- [ ] pending")
        XCTAssertTrue(forest[0].isClosed)
        XCTAssertEqual(forest[0].text, "shipped")
        XCTAssertFalse(forest[1].isClosed)
        XCTAssertEqual(forest[1].text, "pending")
    }

    func testParsesTrailingTagsAndLeadingEmoji() {
        let forest = OutlineText.parse("- 🚀 Launch day #q3 #team")
        XCTAssertEqual(forest[0].text, "Launch day")
        XCTAssertEqual(forest[0].icon, "🚀")
        XCTAssertEqual(forest[0].tags, ["q3", "team"])
    }

    func testHashMidSentenceIsNotATag() {
        let forest = OutlineText.parse("- issue #42 was fixed")
        XCTAssertEqual(forest[0].text, "issue #42 was fixed")
        XCTAssertTrue(forest[0].tags.isEmpty)
    }

    func testAllTagLineKeepsItsText() {
        // Nothing but tags would leave a nameless topic — keep the text.
        let forest = OutlineText.parse("- #alpha #beta")
        XCTAssertEqual(forest[0].text, "#alpha #beta")
        XCTAssertTrue(forest[0].tags.isEmpty)
    }

    func testLoneEmojiStaysAsText() {
        let forest = OutlineText.parse("- 🚀")
        XCTAssertEqual(forest[0].text, "🚀")
        XCTAssertNil(forest[0].icon)
    }

    func testHyphenatedProseIsNotABullet() {
        let forest = OutlineText.parse("-notabullet")
        XCTAssertEqual(forest.map(\.text), ["-notabullet"])
    }

    func testEmptyInputParsesToNothing() {
        XCTAssertTrue(OutlineText.parse("").isEmpty)
        XCTAssertTrue(OutlineText.parse("   \n\n\t\n").isEmpty)
    }

    func testDepthJumpIsClamped() {
        // A four-space jump from the root shouldn't create phantom levels.
        let forest = OutlineText.parse("- A\n        - deep")
        XCTAssertEqual(forest.count, 1)
        XCTAssertEqual(forest[0].children.map(\.text), ["deep"])
    }

    // MARK: Round trip

    func testRoundTripPreservesShapeIconsAndTags() {
        var root = MindNode(text: "Root", tags: ["top"], icon: "🧠")
        var a = MindNode(text: "A")
        a.children = [MindNode(text: "A1"), MindNode(text: "A2", tags: ["x"])]
        root.children = [a, MindNode(text: "B", icon: "✅")]

        let parsed = OutlineText.parse(OutlineText.serialize(root))
        XCTAssertEqual(parsed.count, 1)
        let back = parsed[0]
        XCTAssertEqual(back.text, "Root")
        XCTAssertEqual(back.icon, "🧠")
        XCTAssertEqual(back.tags, ["top"])
        XCTAssertEqual(back.children.map(\.text), ["A", "B"])
        XCTAssertEqual(back.children[0].children.map(\.text), ["A1", "A2"])
        XCTAssertEqual(back.children[0].children[1].tags, ["x"])
        XCTAssertEqual(back.children[1].icon, "✅")
    }

    func testRoundTripOfADeepTree() {
        var root = MindNode(text: "L0")
        var current = MindNode(text: "L5")
        for level in stride(from: 4, through: 1, by: -1) {
            var parent = MindNode(text: "L\(level)")
            parent.children = [current]
            current = parent
        }
        root.children = [current]

        let back = OutlineText.parse(OutlineText.serialize(root))[0]
        var texts: [String] = []
        var node: MindNode? = back
        while let n = node {
            texts.append(n.text)
            node = n.children.first
        }
        XCTAssertEqual(texts, ["L0", "L1", "L2", "L3", "L4", "L5"])
    }
}
