import XCTest
@testable import MindBlow

/// Tags are identified by their case-folded key, and the first spelling seen in
/// the map is the one everything displays. `Work`, `work` and `WORK` are one
/// tag: one chip in the filter bar, one entry on a node, one thing to filter by.
final class TagTests: XCTestCase {
    func testKeyIgnoresCase() {
        XCTAssertEqual(Tags.key("Work"), Tags.key("work"))
        XCTAssertEqual(Tags.key("WORK"), Tags.key("work"))
    }

    /// Case is the only thing folded — accents still distinguish tags, unlike
    /// find, where folding them is a convenience.
    func testKeyKeepsDiacriticsDistinct() {
        XCTAssertNotEqual(Tags.key("résumé"), Tags.key("resume"))
    }

    func testDistinctKeepsTheFirstSpellingAndDropsVariants() {
        XCTAssertEqual(Tags.distinct(["Work", "work", "q3", "WORK", "Q3"]), ["Work", "q3"])
    }

    func testContainsIgnoresCase() {
        XCTAssertTrue(Tags.contains(["Work", "q3"], "WORK"))
        XCTAssertFalse(Tags.contains(["Work", "q3"], "q4"))
    }

    /// Typing a variant of a tag the map already has adopts the map's spelling
    /// rather than minting a twin.
    func testAddingAdoptsTheKnownSpelling() {
        XCTAssertEqual(Tags.adding("WORK", to: ["q3"], known: ["Work"]), ["q3", "Work"])
    }

    func testAddingAnUnknownTagKeepsWhatWasTyped() {
        XCTAssertEqual(Tags.adding("OKR", to: ["q3"], known: ["Work"]), ["q3", "OKR"])
    }

    func testAddingATagTheNodeAlreadyHasInAnotherCaseIsANoOp() {
        XCTAssertEqual(Tags.adding("WORK", to: ["Work", "q3"], known: ["Work"]), ["Work", "q3"])
    }

    func testRemovingIgnoresCase() {
        XCTAssertEqual(Tags.removing("work", from: ["Work", "q3"]), ["q3"])
    }

    /// The filter bar holds keys; a node tagged in any casing must match.
    func testFilterMatchesAcrossCasings() {
        XCTAssertTrue(Tags.matches(["WORK"], anyOf: Tags.keys(["Work"])))
        XCTAssertTrue(Tags.matches(["q3", "Work"], anyOf: Tags.keys(["work", "okr"])))
        XCTAssertFalse(Tags.matches(["q3"], anyOf: Tags.keys(["Work"])))
        XCTAssertFalse(Tags.matches([], anyOf: Tags.keys(["Work"])))
    }

    // MARK: Suggestions

    private let known = ["framework", "q3", "work", "workshop"]

    func testNoSuggestionsUntilSomethingIsTyped() {
        XCTAssertEqual(Tags.suggestions(for: "", from: known, excluding: []), [])
        XCTAssertEqual(Tags.suggestions(for: "   ", from: known, excluding: []), [])
    }

    /// Tags that start with what you typed come before ones that merely
    /// contain it — those are the ones Tab can complete.
    func testPrefixMatchesRankBeforeSubstringMatches() {
        XCTAssertEqual(Tags.suggestions(for: "wo", from: known, excluding: []),
                       ["work", "workshop", "framework"])
    }

    func testSuggestionsIgnoreCase() {
        XCTAssertEqual(Tags.suggestions(for: "WO", from: known, excluding: []),
                       ["work", "workshop", "framework"])
    }

    /// A tag the topic already carries is not worth suggesting.
    func testSuggestionsExcludeTagsTheTopicAlreadyHas() {
        XCTAssertEqual(Tags.suggestions(for: "wo", from: known, excluding: ["WORK"]),
                       ["workshop", "framework"])
    }

    /// Typing the hash people are used to writing must not break matching.
    func testSuggestionsIgnoreALeadingHash() {
        XCTAssertEqual(Tags.suggestions(for: "#wo", from: known, excluding: []),
                       ["work", "workshop", "framework"])
    }

    func testSuggestionsAreCapped() {
        let many = (1...20).map { "tag\($0)" }
        XCTAssertEqual(Tags.suggestions(for: "tag", from: many, excluding: [], limit: 6).count, 6)
    }

    func testNoMatchesGivesNoSuggestions() {
        XCTAssertEqual(Tags.suggestions(for: "zz", from: known, excluding: []), [])
    }

    /// Pasting an outline that spells a tag several ways settles on the first.
    func testOutlineParsingSettlesOnTheFirstSpelling() {
        let outline = """
        Root
        \tAlpha #Work
        \tBeta #work
        \tGamma #WORK
        """
        let roots = OutlineText.parse(outline)
        XCTAssertEqual(roots.first?.children.map(\.tags), [["Work"], ["Work"], ["Work"]])
    }
}
