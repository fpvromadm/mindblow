import AppKit
import SwiftUI

/// The editor's document-level commands, published to the scene so the real
/// menu bar can drive them.
///
/// These cannot live as hidden `Button`s inside the view: macOS gives the main
/// menu first refusal on every key equivalent, so a hidden ⌘C would lose to
/// Edit ▸ Copy and never fire. Publishing the actions and *replacing* the menu
/// items is the way to own those keys — and it puts the commands somewhere
/// discoverable at the same time.
struct MapCommandActions {
    var copy: () -> Void
    var cut: () -> Void
    var paste: () -> Void
    var delete: () -> Void
    var selectAll: () -> Void
    var focusIn: () -> Void
    var focusOut: () -> Void
    var export: (MapExport.Format) -> Void
    var canFocusIn: Bool
    var canFocusOut: Bool

    /// Compared on state only. The closures read live view state when called,
    /// so a menu holding an older copy still does the right thing — the same
    /// contract `NodeView.Actions` uses.
    static func == (lhs: MapCommandActions, rhs: MapCommandActions) -> Bool {
        lhs.canFocusIn == rhs.canFocusIn && lhs.canFocusOut == rhs.canFocusOut
    }
}

extension MapCommandActions: Equatable {}

private struct MapCommandActionsKey: FocusedValueKey {
    typealias Value = MapCommandActions
}

extension FocusedValues {
    var mapCommands: MapCommandActions? {
        get { self[MapCommandActionsKey.self] }
        set { self[MapCommandActionsKey.self] = newValue }
    }
}

/// Menu bar entries for the focused map.
struct MapMenuCommands: Commands {
    @FocusedValue(\.mapCommands) private var actions

    var body: some Commands {
        // Replaces the stock Cut/Copy/Paste/Delete/Select All. Each action
        // hands the keystroke back to whatever text field has the keyboard,
        // so editing a topic title or a note behaves normally.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { actions?.cut() }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { actions?.copy() }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { actions?.paste() }
                .keyboardShortcut("v", modifiers: .command)
            Button("Delete") { actions?.delete() }
            Divider()
            Button("Select All") { actions?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }
        CommandGroup(replacing: .importExport) {
            Menu("Export") {
                ForEach(MapExport.Format.allCases) { format in
                    Button(format.title) { actions?.export(format) }
                }
            }
            .disabled(actions == nil)
        }
        CommandMenu("Topic") {
            Button("Focus on Topic") { actions?.focusIn() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(actions?.canFocusIn != true)
            Button("Exit Focus") { actions?.focusOut() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(actions?.canFocusOut != true)
        }
    }
}

/// Copy and paste of whole subtrees.
///
/// Writes two flavors of the same thing: a private JSON payload that survives a
/// round trip exactly, and the plain-text outline, so pasting into a mail draft
/// or a README gives something readable. Reading prefers the private flavor and
/// falls back to parsing whatever text is on the pasteboard — which is what
/// makes "copy an outline from anywhere, paste a map" work.
enum MapClipboard {
    static let subtreeType = NSPasteboard.PasteboardType("io.github.fpvromadm.mindblow.subtree")

    static func write(_ nodes: [MindNode], to pasteboard: NSPasteboard = .general) {
        guard !nodes.isEmpty else { return }
        pasteboard.clearContents()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(nodes) {
            pasteboard.setData(data, forType: subtreeType)
        }
        let text = nodes.map { OutlineText.serialize($0, includeClosed: true) }
            .joined(separator: "\n")
        pasteboard.setString(text, forType: .string)
    }

    /// Topics on the pasteboard, always with fresh ids so a paste can sit
    /// alongside what it was copied from.
    static func read(from pasteboard: NSPasteboard = .general) -> [MindNode] {
        if let data = pasteboard.data(forType: subtreeType) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let nodes = try? decoder.decode([MindNode].self, from: data) {
                return nodes.map { $0.rekeyed() }
            }
        }
        guard let text = pasteboard.string(forType: .string) else { return [] }
        return OutlineText.parse(text)
    }
}

/// Selection arithmetic that has nothing to do with SwiftUI.
enum MapSelection {
    /// The selected topics that aren't already inside another selected topic,
    /// in document order.
    ///
    /// Every bulk action needs this. Moving a selection that contains both a
    /// branch and one of its own children would otherwise move that child
    /// twice — once with its parent and once on its own — and deleting one
    /// would leave the other pointing at a node that no longer exists.
    static func topmost(_ ids: Set<UUID>, in root: MindNode) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        var result: [UUID] = []
        func walk(_ node: MindNode) {
            if ids.contains(node.id) {
                result.append(node.id)
                return
            }
            node.children.forEach(walk)
        }
        walk(root)
        return result
    }

    /// Ids whose node rectangles intersect `rect` (world coordinates).
    static func inside(_ rect: CGRect, of layout: MapLayout) -> Set<UUID> {
        var hits = Set<UUID>()
        for id in layout.order {
            guard let geom = layout.nodes[id] else { continue }
            if rect.intersects(geom.rect) { hits.insert(id) }
        }
        return hits
    }
}

/// A common set of emoji for the icon picker. Ordered by what people actually
/// reach for on a plan: status, then work types, then objects.
enum IconPalette {
    static let emoji = [
        "⭐️", "✅", "❗️", "❓", "🔥", "💡", "🎯", "🚀",
        "📌", "📝", "📊", "📅", "💰", "🧠", "🔧", "🐛",
        "🧪", "📦", "🌍", "👥", "💬", "🏁", "⚠️", "🔒",
    ]
}
