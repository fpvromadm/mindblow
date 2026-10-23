import SwiftUI

/// How a node participates in the active find: not a match, a match, or the
/// one match currently stepped to.
enum SearchMatchState { case none, match, current }

/// Case- and diacritic-insensitive incremental search over the tree.
///
/// The query is folded once by the caller (`fold`) and passed down already
/// normalized so a keystroke doesn't re-fold it for every node.
enum NodeSearch {
    /// Which field matched, in display-priority order (title first).
    enum Field { case title, notes, tags, link }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The first field of `node` matched by `foldedQuery` (already folded and
    /// non-empty), or nil if the node doesn't match.
    static func match(_ node: MindNode, foldedQuery q: String) -> Field? {
        if fold(node.text).contains(q) { return .title }
        if fold(node.notes).contains(q) { return .notes }
        if node.tags.contains(where: { fold($0).contains(q) }) { return .tags }
        if let link = node.link, fold(link).contains(q) { return .link }
        return nil
    }

    /// A one-line snippet of `notes` around the first hit, for the outline —
    /// otherwise a row that matched only in its body gives no clue why.
    static func snippet(_ notes: String, foldedQuery q: String, context: Int = 26) -> String? {
        let folded = fold(notes)
        // Folding is 1:1 for the scripts we handle (diacritics collapse to a
        // single character), so folded offsets map straight onto the original.
        guard folded.count == notes.count,
              let r = folded.range(of: q) else { return nil }
        let chars = Array(notes)
        let lower = folded.distance(from: folded.startIndex, to: r.lowerBound)
        let upper = folded.distance(from: folded.startIndex, to: r.upperBound)
        let start = max(0, lower - context)
        let end = min(chars.count, upper + context)
        var s = String(chars[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start > 0 { s = "\u{2026}" + s }
        if end < chars.count { s += "\u{2026}" }
        return s
    }
}

/// Renders `text` with every occurrence of `query` on an accent wash. Shared
/// by outline rows (title + notes snippet). Falls back to a plain string when
/// the fold would misalign, so it can never crash on odd input.
struct HighlightedText: View {
    var text: String
    var query: String
    var font: Font
    var color: Color = .primary

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var base = AttributedString(text)
        base.font = font
        base.foregroundColor = color

        let q = NodeSearch.fold(query.trimmingCharacters(in: .whitespaces))
        let folded = NodeSearch.fold(text)
        guard !q.isEmpty, folded.count == text.count else { return base }

        let foldedArr = Array(folded)
        let qArr = Array(q)
        let chars = Array(text)
        guard qArr.count <= foldedArr.count else { return base }

        var ranges: [Range<Int>] = []
        var i = 0
        while i <= foldedArr.count - qArr.count {
            if Array(foldedArr[i..<(i + qArr.count)]) == qArr {
                ranges.append(i..<(i + qArr.count))
                i += qArr.count
            } else {
                i += 1
            }
        }
        guard !ranges.isEmpty else { return base }

        var result = AttributedString()
        var cursor = 0
        func segment(_ slice: ArraySlice<Character>, highlight: Bool) {
            var seg = AttributedString(String(slice))
            seg.font = font
            seg.foregroundColor = color
            if highlight { seg.backgroundColor = Palette.selection.opacity(0.22) }
            result += seg
        }
        for r in ranges {
            if cursor < r.lowerBound { segment(chars[cursor..<r.lowerBound], highlight: false) }
            segment(chars[r], highlight: true)
            cursor = r.upperBound
        }
        if cursor < chars.count { segment(chars[cursor...], highlight: false) }
        return result
    }
}
