import Foundation

/// Plain-text form of a subtree, in both directions.
///
/// This is the app's import/export lingua franca: it backs ⌘C/⌘V, the Markdown
/// export, and pasting an outline from anywhere else. Deliberately pure and
/// free of AppKit so it can be tested directly.
enum OutlineText {

    // MARK: - Serialize

    /// Nested Markdown bullets, two spaces per level.
    ///
    /// - Parameters:
    ///   - includeClosed: closed topics are written as `- [x]` checkboxes;
    ///     when false they are omitted along with their subtrees.
    ///   - includeNotes: notes are written as an indented block under the topic.
    static func serialize(_ node: MindNode,
                          includeClosed: Bool = false,
                          includeNotes: Bool = false) -> String {
        var lines: [String] = []
        func walk(_ n: MindNode, depth: Int) {
            if n.isClosed && !includeClosed { return }
            let pad = String(repeating: "  ", count: depth)
            var line = pad + "- "
            if n.isClosed { line += "[x] " }
            line += title(of: n)
            for tag in n.tags { line += " #" + tag }
            lines.append(line)
            if includeNotes, !n.notes.isEmpty {
                // Blockquoted, not merely indented: an indented note line sits
                // at exactly the depth a child bullet would, so re-importing
                // the export would turn every note into a topic.
                let notePad = pad + "  > "
                for noteLine in n.notes.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append(notePad + noteLine)
                }
            }
            n.children.forEach { walk($0, depth: depth + 1) }
        }
        walk(node, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// Display title with the icon folded in, which is how it round-trips.
    static func title(of node: MindNode) -> String {
        let text = node.text.isEmpty ? "Topic" : node.text
        if let icon = node.icon, !icon.isEmpty { return icon + " " + text }
        return text
    }

    // MARK: - Parse

    /// Turns pasted text into a forest of topics.
    ///
    /// Understands Markdown headings, `-`/`*`/`+`/`•` bullets, `1.`/`1)`
    /// numbered lists, task checkboxes, and plain indented text — in any
    /// mixture, because pasted text is never as tidy as the app that wrote it.
    /// Returns an empty array when there is nothing usable.
    static func parse(_ text: String) -> [MindNode] {
        var entries = scan(text)
        guard !entries.isEmpty else { return [] }
        settleTagSpellings(&entries)
        return assemble(entries)
    }

    /// Pasted text spells a tag however each line felt like spelling it. Tags
    /// are case-insensitive, so settle every line on the first spelling the
    /// paste used rather than importing `#Work`, `#work` and `#WORK` as three.
    private static func settleTagSpellings(_ entries: inout [Entry]) {
        var vocabulary: [String] = []
        for i in entries.indices where !entries[i].node.tags.isEmpty {
            var settled: [String] = []
            for tag in Tags.distinct(entries[i].node.tags) {
                let canonical = Tags.canonical(tag, among: vocabulary)
                if !Tags.contains(vocabulary, canonical) { vocabulary.append(canonical) }
                settled.append(canonical)
            }
            entries[i].node.tags = settled
        }
    }

    /// One parsed line, before the tree is built.
    private struct Entry {
        var depth: Int
        var node: MindNode
    }

    private static func scan(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        // Columns of the enclosing bullet levels, innermost last. Reset by a
        // heading, which re-baselines everything under it.
        var columns: [Int] = []
        var bulletBase = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let column = indentColumn(of: line)
            var content = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            // Blockquotes are prose about a topic, not a topic — that is how
            // notes leave in the Markdown export, and they must not come back
            // in as bullets.
            guard !content.hasPrefix(">") else { continue }

            if let level = headingLevel(&content) {
                // A heading sets the depth outright and starts a fresh indent
                // scale for the bullets that follow it.
                let depth = level - 1
                bulletBase = depth + 1
                columns = []
                entries.append(Entry(depth: depth, node: makeNode(from: content)))
                continue
            }

            _ = stripBullet(&content)
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            while let last = columns.last, last > column { columns.removeLast() }
            if columns.last != column { columns.append(column) }
            let depth = bulletBase + columns.count - 1
            entries.append(Entry(depth: depth, node: makeNode(from: content)))
        }
        return entries
    }

    /// Builds the forest, clamping any depth jump greater than one so a ragged
    /// paste can never produce an orphan.
    private static func assemble(_ entries: [Entry]) -> [MindNode] {
        var roots: [MindNode] = []
        // Path from a root down to the last node placed, as index chains.
        var stack: [(depth: Int, path: [Int])] = []

        func insert(_ node: MindNode, at path: [Int]) {
            guard !path.isEmpty else { roots.append(node); return }
            func descend(_ parent: inout MindNode, _ rest: ArraySlice<Int>) {
                guard let index = rest.first else { parent.children.append(node); return }
                descend(&parent.children[index], rest.dropFirst())
            }
            descend(&roots[path[0]], path.dropFirst())
        }

        for entry in entries {
            while let last = stack.last, last.depth >= entry.depth { stack.removeLast() }
            let parentPath = stack.last?.path ?? []
            let childIndex = count(at: parentPath, in: roots)
            insert(entry.node, at: parentPath)
            stack.append((depth: entry.depth, path: parentPath + [childIndex]))
        }
        return roots
    }

    /// Number of children already sitting at `path` (or roots, for an empty
    /// path) — the index the next insertion will land on.
    private static func count(at path: [Int], in roots: [MindNode]) -> Int {
        guard let first = path.first else { return roots.count }
        var node = roots[first]
        for index in path.dropFirst() { node = node.children[index] }
        return node.children.count
    }

    // MARK: Line pieces

    /// Indent width in columns, with a tab advancing to the next multiple of 4
    /// — the same rule editors use, so tab- and space-indented text mix.
    static func indentColumn(of line: String) -> Int {
        var column = 0
        for ch in line {
            if ch == " " { column += 1 }
            else if ch == "\t" { column += 4 - (column % 4) }
            else { break }
        }
        return column
    }

    /// Strips a leading `#`-run and returns its length, or nil if there isn't
    /// one. `#tag` is not a heading — a heading needs whitespace after the run.
    private static func headingLevel(_ content: inout String) -> Int? {
        var hashes = 0
        var index = content.startIndex
        while index < content.endIndex, content[index] == "#", hashes < 6 {
            hashes += 1
            index = content.index(after: index)
        }
        guard hashes > 0, index < content.endIndex, content[index] == " " || content[index] == "\t"
        else { return nil }
        content = String(content[index...]).trimmingCharacters(in: .whitespaces)
        return hashes
    }

    /// Removes a leading bullet or list number. Returns whether one was found.
    @discardableResult
    private static func stripBullet(_ content: inout String) -> Bool {
        guard let first = content.first else { return false }
        if "-*+•\u{2022}\u{25E6}\u{2023}".contains(first) {
            let rest = content.dropFirst()
            // "-word" is prose (or a negative number), "- word" is a bullet.
            guard rest.first == " " || rest.first == "\t" else { return false }
            content = String(rest).trimmingCharacters(in: .whitespaces)
            return true
        }
        if first.isNumber {
            let digits = content.prefix(while: \.isNumber)
            let after = content.dropFirst(digits.count)
            guard let marker = after.first, marker == "." || marker == ")" else { return false }
            let rest = after.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return false }
            content = String(rest).trimmingCharacters(in: .whitespaces)
            return true
        }
        return false
    }

    /// Pulls the checkbox, leading emoji, and trailing hashtags out of a title
    /// line and builds the topic.
    private static func makeNode(from raw: String) -> MindNode {
        var content = raw
        var closed = false
        for marker in ["[x] ", "[X] ", "[ ] "] where content.hasPrefix(marker) {
            closed = marker.lowercased() == "[x] "
            content = String(content.dropFirst(marker.count))
            break
        }
        let tags = trailingTags(&content)
        let icon = leadingEmoji(&content)
        return MindNode(
            text: content.trimmingCharacters(in: .whitespaces),
            tags: tags,
            icon: icon,
            closedAt: closed ? Date() : nil
        )
    }

    /// Trailing `#tag` tokens, removed from `content`. Only a run at the very
    /// end counts, so a `#` mid-sentence stays part of the text.
    private static func trailingTags(_ content: inout String) -> [String] {
        var words = content.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var tags: [String] = []
        while let last = words.last, last.hasPrefix("#"), last.count > 1 {
            tags.insert(String(last.dropFirst()), at: 0)
            words.removeLast()
        }
        // All-tags line: keep it as text rather than producing a nameless topic.
        guard !words.isEmpty else { return [] }
        if !tags.isEmpty { content = words.joined(separator: " ") }
        return tags
    }

    /// A leading emoji, removed from `content` and returned as the icon.
    private static func leadingEmoji(_ content: inout String) -> String? {
        guard let first = content.first, isEmoji(first) else { return nil }
        let rest = content.dropFirst().drop(while: { $0 == " " })
        // "🚀" alone is the whole title — keep it as text, not a nameless icon.
        guard !rest.isEmpty else { return nil }
        content = String(rest)
        return String(first)
    }

    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
            return true
        }
        // Single-scalar symbols that default to text presentation (✓, ★, ⚠)
        // still read as icons here; plain ASCII never does.
        return first.properties.isEmoji && first.value > 0x238C
    }
}
