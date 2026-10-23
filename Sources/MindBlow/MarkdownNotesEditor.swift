import SwiftUI
import AppKit

extension NSAttributedString.Key {
    /// Marks a syntax range to be drawn as a substitute glyph ("•", "☐", "☑")
    /// or hidden entirely (empty string) while the cursor is elsewhere.
    static let markdownReplacement = NSAttributedString.Key("markdownReplacement")
}

/// Obsidian-style live markdown editor: a single NSTextView restyled in place
/// on every edit and selection change. Syntax markers (###, **, `, link URLs)
/// are concealed except on the line holding the cursor; lists auto-continue
/// on Enter and indent with Tab.
struct MarkdownNotesEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.drawsBackground = false
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async { coordinator?.parent.isActive = focused }
        }
        textView.string = text
        textView.layoutManager?.delegate = context.coordinator
        context.coordinator.restyle(textView)

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            // External change (switching topics): replace content wholesale.
            textView.string = text
            textView.undoManager?.removeAllActions()
            context.coordinator.restyle(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: MarkdownNotesEditor

        init(_ parent: MarkdownNotesEditor) {
            self.parent = parent
        }

        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            MarkdownStyler.style(storage, selection: textView.selectedRange())
            textView.typingAttributes = MarkdownStyler.baseAttributes
            // Replacement attributes changed → glyph substitution must rerun.
            if let lm = textView.layoutManager {
                let full = NSRange(location: 0, length: storage.length)
                lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
                lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            }
        }

        // MARK: Glyph substitution (bullets • and checkboxes ☐/☑)

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
            var newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
            var changed = false

            for i in 0..<glyphRange.length {
                let charIndex = charIndexes[i]
                guard charIndex < storage.length else { continue }
                var effective = NSRange()
                guard let replacement = storage.attribute(
                    .markdownReplacement, at: charIndex, effectiveRange: &effective
                ) as? String else { continue }

                changed = true
                if charIndex == effective.location, !replacement.isEmpty,
                   let glyph = Self.glyph(for: replacement, font: font) {
                    newGlyphs[i] = glyph
                } else {
                    newProps[i] = .null
                }
            }

            guard changed else { return 0 }
            newGlyphs.withUnsafeBufferPointer { g in
                newProps.withUnsafeBufferPointer { p in
                    layoutManager.setGlyphs(g.baseAddress!, properties: p.baseAddress!,
                                            characterIndexes: charIndexes, font: font,
                                            forGlyphRange: glyphRange)
                }
            }
            return glyphRange.length
        }

        private static var glyphCache: [String: CGGlyph] = [:]

        private static func glyph(for symbol: String, font: NSFont) -> CGGlyph? {
            let key = "\(symbol)-\(font.fontName)-\(font.pointSize)"
            if let cached = glyphCache[key] { return cached == 0 ? nil : cached }
            let ct = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
            let chars = Array(symbol.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let ok = CTFontGetGlyphsForCharacters(ct, chars, &glyphs, chars.count)
            glyphCache[key] = ok ? glyphs[0] : 0
            return ok ? glyphs[0] : nil
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            restyle(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Moving the cursor reveals/conceals markers line by line.
            guard let textView = notification.object as? NSTextView else { return }
            restyle(textView)
        }
    }
}

// MARK: - Text view with list editing behaviors

final class MarkdownTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    private static let listPrefixPattern = #"^\s*(?:[-*] \[[ xX]\] |[-*] |\d+\. |> )"#

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    private func currentLine() -> (range: NSRange, text: String)? {
        let ns = string as NSString
        guard selectedRange().location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = ns.substring(with: lineRange)
        return (lineRange, line.hasSuffix("\n") ? String(line.dropLast()) : line)
    }

    override func insertNewline(_ sender: Any?) {
        guard let (lineRange, line) = currentLine(),
              let markerRange = line.range(of: Self.listPrefixPattern, options: .regularExpression)
        else {
            super.insertNewline(sender)
            return
        }

        var marker = String(line[markerRange])
        let content = String(line[markerRange.upperBound...])

        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Enter on an empty list item ends the list: remove the marker.
            let docMarkerRange = NSRange(location: lineRange.location, length: (marker as NSString).length)
            if shouldChangeText(in: docMarkerRange, replacementString: "") {
                insertText("", replacementRange: docMarkerRange)
            }
            return
        }

        // Continue the list; numbered items increment, done tasks reset.
        if let numRange = marker.range(of: #"\d+"#, options: .regularExpression),
           let n = Int(marker[numRange]) {
            marker = marker.replacingCharacters(in: numRange, with: String(n + 1))
        }
        marker = marker.replacingOccurrences(of: "[x] ", with: "[ ] ")
            .replacingOccurrences(of: "[X] ", with: "[ ] ")

        super.insertNewline(sender)
        insertText(marker, replacementRange: selectedRange())
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking a rendered checkbox toggles it.
        let point = convert(event.locationInWindow, from: nil)
        if let lm = layoutManager, let container = textContainer, let storage = textStorage {
            let adjusted = NSPoint(x: point.x - textContainerInset.width,
                                   y: point.y - textContainerInset.height)
            var fraction: CGFloat = 0
            let idx = lm.characterIndex(for: adjusted, in: container,
                                        fractionOfDistanceBetweenInsertionPoints: &fraction)
            if idx < storage.length {
                var effective = NSRange()
                if let repl = storage.attribute(.markdownReplacement, at: idx,
                                                effectiveRange: &effective) as? String,
                   repl == "□" || repl == "☑" {
                    let toggled = repl == "□" ? "[x]" : "[ ]"
                    if shouldChangeText(in: effective, replacementString: toggled) {
                        insertText(toggled, replacementRange: effective)
                    }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        guard let (lineRange, line) = currentLine(),
              line.range(of: Self.listPrefixPattern, options: .regularExpression) != nil
        else {
            super.insertTab(sender)
            return
        }
        insertText("  ", replacementRange: NSRange(location: lineRange.location, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        guard let (lineRange, line) = currentLine() else { return }
        let spaces = line.prefix(while: { $0 == " " }).count
        let remove = min(spaces, 2)
        guard remove > 0 else { return }
        let range = NSRange(location: lineRange.location, length: remove)
        if shouldChangeText(in: range, replacementString: "") {
            insertText("", replacementRange: range)
        }
    }
}

// MARK: - Live styling with marker concealment

enum MarkdownStyler {
    static let baseSize: CGFloat = 13
    private static let headingSizes: [CGFloat] = [19, 17, 15.5, 14.5, 13.5, 13]

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 3
        return [
            .font: NSFont.systemFont(ofSize: baseSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// Attributes that make a marker take (virtually) no space.
    private static var hiddenAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.1)]
    }

    private static let dim = NSColor.tertiaryLabelColor

    private static let boldItalicRegex = try! NSRegularExpression(pattern: #"\*\*\*([^*\n]+)\*\*\*"#)
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<![\*\w])\*([^*\n]+)\*(?![\*\w])"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"(\[)([^\]]+)(\]\()([^)\n]+)(\))"#)

    static func style(_ storage: NSTextStorage, selection: NSRange?) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        let ns = storage.string as NSString
        var inCodeBlock = false
        ns.enumerateSubstrings(in: full, options: .byLines) { substring, lineRange, enclosingRange, _ in
            guard let line = substring else { return }
            let reveal = lineRevealed(enclosingRange, selection: selection)

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                    .foregroundColor: dim,
                ], range: lineRange)
                inCodeBlock.toggle()
                return
            }
            if inCodeBlock {
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: baseSize - 0.5, weight: .regular),
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05),
                ], range: lineRange)
                return
            }
            styleLine(line, at: lineRange, in: storage, reveal: reveal)
        }
        storage.endEditing()
    }

    private static func lineRevealed(_ lineRange: NSRange, selection: NSRange?) -> Bool {
        guard let sel = selection else { return true }
        if sel.length == 0 {
            return sel.location >= lineRange.location && sel.location <= NSMaxRange(lineRange)
        }
        return NSIntersectionRange(lineRange, sel).length > 0
    }

    private static func conceal(_ storage: NSTextStorage, _ range: NSRange, reveal: Bool) {
        if reveal {
            storage.addAttribute(.foregroundColor, value: dim, range: range)
        } else {
            storage.addAttributes(hiddenAttributes, range: range)
        }
    }

    private static func styleLine(_ line: String, at range: NSRange, in storage: NSTextStorage, reveal: Bool) {
        let lineNS = line as NSString
        let lineFull = NSRange(location: 0, length: lineNS.length)
        func global(_ r: NSRange) -> NSRange {
            NSRange(location: range.location + r.location, length: r.length)
        }

        // Horizontal rule: a dim divider-ish line.
        if line.range(of: #"^\s*(-{3,}|\*{3,}|_{3,})\s*$"#, options: .regularExpression) != nil {
            storage.addAttribute(.foregroundColor, value: dim, range: range)
            return
        }

        // Headings: whole line bold at the level's size, hashes concealed.
        if let match = line.range(of: #"^(#{1,6})\s"#, options: .regularExpression) {
            let markerLen = line.distance(from: line.startIndex, to: match.upperBound)
            let size = headingSizes[markerLen - 2]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
            conceal(storage, global(NSRange(location: 0, length: markerLen)), reveal: reveal)
            return
        }

        // Quote: content secondary, markers dimmed.
        if let match = line.range(of: #"^(?:> ?)+"#, options: .regularExpression) {
            let len = line.distance(from: line.startIndex, to: match.upperBound)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            storage.addAttribute(.foregroundColor, value: dim, range: global(NSRange(location: 0, length: len)))
        }

        // Task items: rendered as ☐/☑ (clickable); completed tasks struck through.
        if let match = line.range(of: #"^\s*[-*] \[[ xX]\] "#, options: .regularExpression) {
            let len = line.distance(from: line.startIndex, to: match.upperBound)
            let ws = line.prefix(while: { $0 == " " }).count
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                 range: global(NSRange(location: 0, length: len)))
            let checked = line.range(of: #"^\s*[-*] \[[xX]\] "#, options: .regularExpression) != nil
            if !reveal {
                // Hide "- " and draw the brackets as a checkbox glyph.
                storage.addAttribute(.markdownReplacement, value: "",
                                     range: global(NSRange(location: ws, length: 2)))
                storage.addAttribute(.markdownReplacement, value: checked ? "☑" : "□",
                                     range: global(NSRange(location: ws + 2, length: 3)))
            }
            if checked {
                let rest = NSRange(location: len, length: lineNS.length - len)
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: global(rest))
            }
        } else if let match = line.range(of: #"^\s*(?:[-*]|\d+\.) "#, options: .regularExpression) {
            // Bullet / numbered list marker tinted; dash rendered as •.
            let len = line.distance(from: line.startIndex, to: match.upperBound)
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                 range: global(NSRange(location: 0, length: len)))
            if !reveal, line.range(of: #"^\s*[-*] "#, options: .regularExpression) != nil {
                let ws = line.prefix(while: { $0 == " " }).count
                storage.addAttribute(.markdownReplacement, value: "•",
                                     range: global(NSRange(location: ws, length: 1)))
            }
        }

        // Inline styles. Earlier passes claim their ranges so later ones skip them.
        var consumed: [NSRange] = []
        func claimed(_ r: NSRange) -> Bool {
            consumed.contains { NSIntersectionRange($0, r).length > 0 }
        }

        for m in codeRegex.matches(in: line, range: lineFull) {
            consumed.append(m.range)
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: baseSize - 0.5, weight: .regular),
                .foregroundColor: NSColor.systemPink,
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
            ], range: global(m.range))
            conceal(storage, global(NSRange(location: m.range.location, length: 1)), reveal: reveal)
            conceal(storage, global(NSRange(location: NSMaxRange(m.range) - 1, length: 1)), reveal: reveal)
        }

        for m in linkRegex.matches(in: line, range: lineFull) where !claimed(m.range) {
            consumed.append(m.range)
            storage.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: global(m.range(at: 2)))
            for group in [1, 3, 4, 5] {
                conceal(storage, global(m.range(at: group)), reveal: reveal)
            }
        }

        func emphasis(_ regex: NSRegularExpression, markerLen: Int, font: NSFont?, strike: Bool = false) {
            for m in regex.matches(in: line, range: lineFull) where !claimed(m.range) {
                consumed.append(m.range)
                if let font {
                    storage.addAttribute(.font, value: font, range: global(m.range))
                }
                if strike {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                         range: global(m.range(at: 1)))
                }
                conceal(storage, global(NSRange(location: m.range.location, length: markerLen)), reveal: reveal)
                conceal(storage, global(NSRange(location: NSMaxRange(m.range) - markerLen, length: markerLen)), reveal: reveal)
            }
        }

        let boldItalicFont = NSFontManager.shared.convert(
            .systemFont(ofSize: baseSize, weight: .bold), toHaveTrait: .italicFontMask)
        emphasis(boldItalicRegex, markerLen: 3, font: boldItalicFont)
        emphasis(boldRegex, markerLen: 2, font: .systemFont(ofSize: baseSize, weight: .bold))
        emphasis(italicRegex, markerLen: 1,
                 font: NSFontManager.shared.convert(.systemFont(ofSize: baseSize), toHaveTrait: .italicFontMask))
        emphasis(strikeRegex, markerLen: 2, font: nil, strike: true)
    }
}
