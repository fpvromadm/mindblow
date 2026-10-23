import XCTest
import SwiftUI
@testable import MindBlow

/// The inspector reserved 45% of its height (never less than 200pt) for notes
/// whether or not the topic had any, which pushed the Tags and Close/Reopen
/// cards below the fold on an ordinary window.
final class InspectorLayoutTests: XCTestCase {
    /// A typical panel: a 750pt window less the title header.
    private let panel: CGFloat = 650

    func testEmptyUnfocusedNotesCollapse() {
        let height = InspectorLayout.notesHeight(panelHeight: panel, hasText: false, isFocused: false)
        XCTAssertLessThanOrEqual(height, 80, "an empty notes box must not hold a card's worth of space")
    }

    func testCollapsedNotesLeaveTheCardsMostOfThePanel() {
        let height = InspectorLayout.notesHeight(panelHeight: panel, hasText: false, isFocused: false)
        XCTAssertGreaterThan(panel - height, panel * 0.85,
                             "the cards should get the panel back when there are no notes")
    }

    func testNotesWithTextKeepTheirShare() {
        let height = InspectorLayout.notesHeight(panelHeight: panel, hasText: true, isFocused: false)
        XCTAssertEqual(height, min(max(200, panel * 0.45), max(140, panel - 170)), accuracy: 0.5)
    }

    /// Clicking into an empty notes box has to give you room to type.
    func testFocusingEmptyNotesExpandsThem() {
        let collapsed = InspectorLayout.notesHeight(panelHeight: panel, hasText: false, isFocused: false)
        let focused = InspectorLayout.notesHeight(panelHeight: panel, hasText: false, isFocused: true)
        XCTAssertGreaterThan(focused, collapsed * 2)
        XCTAssertEqual(focused,
                       InspectorLayout.notesHeight(panelHeight: panel, hasText: true, isFocused: false),
                       accuracy: 0.5)
    }

    /// A short panel must still leave the cards something to scroll in.
    func testNotesNeverSwallowAShortPanel() {
        for panelHeight in stride(from: CGFloat(200), through: 1400, by: 50) {
            let height = InspectorLayout.notesHeight(panelHeight: panelHeight, hasText: true, isFocused: true)
            XCTAssertLessThan(height, panelHeight,
                              "notes must leave room for the cards at \(panelHeight)pt")
            XCTAssertGreaterThan(height, 0)
        }
    }
}

/// The cards people act on should come before the ones that decorate.
final class InspectorCardOrderTests: XCTestCase {
    func testActionCardsComeFirst() {
        let order = InspectorLayout.cardOrder
        XCTAssertEqual(order, [.closed, .dueDate, .tags, .link, .connections, .color, .iconImage])
    }

    func testClosedAndTagsAreReachableWithoutScrollingPastDecoration() {
        let order = InspectorLayout.cardOrder
        let closed = order.firstIndex(of: .closed)!
        let tags = order.firstIndex(of: .tags)!
        let color = order.firstIndex(of: .color)!
        let iconImage = order.firstIndex(of: .iconImage)!
        XCTAssertLessThan(closed, color)
        XCTAssertLessThan(closed, iconImage)
        XCTAssertLessThan(tags, color)
        XCTAssertLessThan(tags, iconImage)
    }
}
