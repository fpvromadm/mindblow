import XCTest
import AppKit
@testable import MindBlow

@MainActor
final class NotesEditorTests: XCTestCase {
    private func editor(_ text: String, cursorAtEnd: Bool = true) -> MarkdownTextView {
        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.string = text
        if cursorAtEnd {
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        return tv
    }

    func testBulletContinues() {
        let tv = editor("- one")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- one\n- ")
    }

    func testTaskContinues() {
        let tv = editor("- [ ] one")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- [ ] one\n- [ ] ")
    }

    func testCheckedTaskContinuesUnchecked() {
        let tv = editor("- [x] done")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- [x] done\n- [ ] ")
    }

    func testNumberedIncrements() {
        let tv = editor("1. first")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "1. first\n2. ")
    }

    func testEmptyBulletEndsList() {
        let tv = editor("- one\n- ")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- one\n")
    }

    func testIndentedBulletContinuesWithIndent() {
        let tv = editor("  - nested")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "  - nested\n  - ")
    }

    func testTabIndentsListLine() {
        let tv = editor("- one")
        tv.insertTab(nil)
        XCTAssertEqual(tv.string, "  - one")
    }

    func testTabIndentsTaskLine() {
        let tv = editor("- [ ] one")
        tv.insertTab(nil)
        XCTAssertEqual(tv.string, "  - [ ] one")
    }

    func testCheckedTaskGetsStrikethrough() {
        let storage = NSTextStorage(string: "- [x] done task")
        MarkdownStyler.style(storage, selection: nil)
        let attrs = storage.attributes(at: 8, effectiveRange: nil)
        XCTAssertNotNil(attrs[.strikethroughStyle], "checked task text should be struck through")
    }

    func testUncheckedTaskNoStrikethrough() {
        let storage = NSTextStorage(string: "- [ ] open task")
        MarkdownStyler.style(storage, selection: nil)
        let attrs = storage.attributes(at: 8, effectiveRange: nil)
        XCTAssertNil(attrs[.strikethroughStyle])
    }

    func testBulletInsideTaskListStyled() {
        let storage = NSTextStorage(string: "- [ ] task\n  - sub bullet")
        MarkdownStyler.style(storage, selection: nil)
        // The nested bullet marker should get the accent tint.
        let attrs = storage.attributes(at: 13, effectiveRange: nil)
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, NSColor.controlAccentColor)
    }

    func testHeadingMarkerConcealedWhenCursorElsewhere() {
        let storage = NSTextStorage(string: "# Title\nbody")
        MarkdownStyler.style(storage, selection: NSRange(location: 10, length: 0))
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual((attrs[.font] as? NSFont)?.pointSize ?? 0, 0.1, accuracy: 0.01,
                       "hash marker should be hidden when cursor is on another line")
    }

    func testHeadingMarkerRevealedOnCursorLine() {
        let storage = NSTextStorage(string: "# Title\nbody")
        MarkdownStyler.style(storage, selection: NSRange(location: 3, length: 0))
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertGreaterThan((attrs[.font] as? NSFont)?.pointSize ?? 0, 10)
    }
}

@MainActor
final class GlyphRenderingTests: XCTestCase {
    func testBulletDashGetsGlyphReplacementWhenCursorElsewhere() {
        let storage = NSTextStorage(string: "- item\nother")
        MarkdownStyler.style(storage, selection: NSRange(location: 10, length: 0))
        XCTAssertEqual(storage.attribute(.markdownReplacement, at: 0, effectiveRange: nil) as? String, "•")
    }

    func testBulletDashRawOnCursorLine() {
        let storage = NSTextStorage(string: "- item\nother")
        MarkdownStyler.style(storage, selection: NSRange(location: 2, length: 0))
        XCTAssertNil(storage.attribute(.markdownReplacement, at: 0, effectiveRange: nil))
    }

    func testTaskRendersCheckbox() {
        let storage = NSTextStorage(string: "- [ ] todo\nother")
        MarkdownStyler.style(storage, selection: NSRange(location: 14, length: 0))
        XCTAssertEqual(storage.attribute(.markdownReplacement, at: 0, effectiveRange: nil) as? String, "",
                       "dash should be hidden on task lines")
        XCTAssertEqual(storage.attribute(.markdownReplacement, at: 2, effectiveRange: nil) as? String, "□")
    }

    func testCheckedTaskRendersCheckedBox() {
        let storage = NSTextStorage(string: "- [x] done\nother")
        MarkdownStyler.style(storage, selection: NSRange(location: 14, length: 0))
        XCTAssertEqual(storage.attribute(.markdownReplacement, at: 2, effectiveRange: nil) as? String, "☑")
    }

    func testNestedBulletUnderTaskGetsGlyph() {
        let storage = NSTextStorage(string: "- [ ] task\n  - sub\nend")
        MarkdownStyler.style(storage, selection: NSRange(location: 21, length: 0))
        XCTAssertEqual(storage.attribute(.markdownReplacement, at: 13, effectiveRange: nil) as? String, "•")
    }

    func testCheckboxGlyphExistsInSystemFont() {
        let ct = CTFontCreateWithName(NSFont.systemFont(ofSize: 13).fontName as CFString, 13, nil)
        for symbol in ["•", "□", "☑"] {
            let chars = Array(symbol.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(ct, chars, &glyphs, chars.count),
                          "system font should have a glyph for \(symbol)")
        }
    }
}
