import SwiftUI

/// Workflowy-style outline presentation of the mind map: indented text rows
/// with bullets, disclosure triangles, inline editing, and the node's
/// metadata (due date, tags, notes marker) at the end of each row.
struct OutlineView: View {
    @Binding var document: MindMapDocument
    @Binding var selection: UUID?
    /// Active find query (empty when not searching). While searching the list
    /// filters to matches + their ancestors, highlights hits, and shows a
    /// notes snippet for body matches.
    var searchQuery: String = ""
    /// Active tag filter; composes with the search (a row must satisfy both).
    var activeTags: Set<String> = []
    /// Whether closed topics are listed at all. A binding so the zero-result
    /// rescue ("N closed topics match — Show closed") can flip it in place.
    @Binding var showClosed: Bool
    var applyChange: ((inout MindMapDocument) -> Void) -> Void
    /// Close/reopen a topic — owned by EditorView so selection handling and
    /// ancestor-reopening stay in one place.
    var toggleClosed: (UUID) -> Void

    /// Closed rows a chevron has expanded this session. Display-only: a
    /// closed subtree always starts folded, and its stored `isCollapsed` is
    /// never touched, so reopening restores the expansion the user had.
    @State private var expandedClosed: Set<UUID> = []
    @State private var hoveredRowID: UUID?

    private struct Row: Identifiable {
        let id: UUID
        let level: Int
        let node: MindNode
        let color: Color
        /// Closed itself or living under a closed ancestor.
        let closed: Bool
    }

    private var foldedQuery: String {
        NodeSearch.fold(searchQuery.trimmingCharacters(in: .whitespaces))
    }

    /// Active filter chips as case-folded keys — tags are case-insensitive.
    private var activeTagKeys: Set<String> { Tags.keys(activeTags) }

    /// True when either a search or a tag filter is narrowing the tree.
    private var isFiltering: Bool { !foldedQuery.isEmpty || !activeTags.isEmpty }

    private func isHit(_ node: MindNode) -> Bool {
        let tagOK = activeTags.isEmpty || Tags.matches(node.tags, anyOf: activeTagKeys)
        let searchOK = foldedQuery.isEmpty || NodeSearch.match(node, foldedQuery: foldedQuery) != nil
        return tagOK && searchOK
    }

    /// Children in display order: open ones keep document order, closed ones
    /// sink to the bottom, most recently closed first (Logbook-style). Purely
    /// a display sort — `children` is never rearranged, so reopening drops a
    /// topic back into its original slot for free.
    private func ordered(_ children: [MindNode]) -> [MindNode] {
        guard showClosed else { return children.filter { !$0.isClosed } }
        guard children.contains(where: \.isClosed) else { return children }
        let open = children.filter { !$0.isClosed }
        let closed = children.filter(\.isClosed)
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        return open + closed
    }

    private var rows: [Row] {
        var result: [Row] = []
        if !isFiltering {
            func walk(_ node: MindNode, level: Int, closedAncestor: Bool) {
                let closed = closedAncestor || node.isClosed
                result.append(Row(id: node.id, level: level, node: node,
                                  color: MapLayout.color(for: node, level: level),
                                  closed: closed))
                guard !effectiveCollapsed(node) else { return }
                ordered(node.children).forEach { walk($0, level: level + 1, closedAncestor: closed) }
            }
            walk(document.root, level: 0, closedAncestor: false)
            return result
        }
        // Filtering: keep every hit plus the ancestors that lead to it (so a
        // match keeps its breadcrumb), ignoring collapse so matches show.
        // Closed subtrees only participate when they are shown.
        var keep = Set<UUID>()
        @discardableResult
        func mark(_ node: MindNode) -> Bool {
            var keepThis = isHit(node)
            for child in node.children where showClosed || !child.isClosed {
                if mark(child) { keepThis = true }
            }
            if keepThis { keep.insert(node.id) }
            return keepThis
        }
        _ = mark(document.root)
        func walk(_ node: MindNode, level: Int, closedAncestor: Bool) {
            guard keep.contains(node.id) else { return }
            let closed = closedAncestor || node.isClosed
            result.append(Row(id: node.id, level: level, node: node,
                              color: MapLayout.color(for: node, level: level),
                              closed: closed))
            ordered(node.children).forEach { walk($0, level: level + 1, closedAncestor: closed) }
        }
        walk(document.root, level: 0, closedAncestor: false)
        return result
    }

    /// A closed topic always starts folded regardless of its stored collapse
    /// state; the chevron expands it via `expandedClosed` only.
    private func effectiveCollapsed(_ node: MindNode) -> Bool {
        node.isClosed ? !expandedClosed.contains(node.id) : node.isCollapsed
    }

    /// Hits that exist only inside hidden closed subtrees — computed when the
    /// open result set is empty, to rescue a fruitless search.
    private var closedMatchCount: Int {
        var count = 0
        func walk(_ node: MindNode) {
            if isHit(node) { count += 1 }
            node.children.forEach(walk)
        }
        walk(document.root)
        return count
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isFiltering && rows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(showClosed ? "No matching topics" : "No open topics match")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            // A fruitless search may be hitting only closed
                            // topics — offer them instead of a dead end.
                            if !showClosed, closedMatchCount > 0 {
                                HStack(spacing: 8) {
                                    Text("\(closedMatchCount) closed topic\(closedMatchCount == 1 ? "" : "s") match\(closedMatchCount == 1 ? "es" : "").")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Button("Show closed") { showClosed = true }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Palette.selection)
                                }
                            }
                        }
                        .padding(.vertical, 24)
                    }
                    ForEach(rows) { row in
                        rowView(row).id(row.id)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 28)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let isSelected = selection == row.id
        let searching = !foldedQuery.isEmpty
        // Notes snippet only when the match is *in* the notes (not the title).
        let notesSnippet: String? = searching
            && NodeSearch.match(row.node, foldedQuery: foldedQuery) == .notes
            ? NodeSearch.snippet(row.node.notes, foldedQuery: foldedQuery) : nil
        let collapsed = effectiveCollapsed(row.node)
        let isHovered = hoveredRowID == row.id
        let titleFont: Font = .system(size: row.level == 0 ? 17 : 13.5,
                                      weight: row.level == 0 ? .bold : (row.level == 1 ? .semibold : .regular))
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Disclosure triangle (only when there are children). Hidden while
            // filtering — the list is fully expanded to show matches, so it
            // would have nothing to fold. A closed row folds via display-only
            // state so its stored collapse survives a reopen untouched.
            PressActionButton(
                help: collapsed ? "Expand" : "Collapse",
                accessibilityLabel: collapsed ? "Expand" : "Collapse",
                action: {
                    if row.node.isClosed {
                        if expandedClosed.contains(row.id) { expandedClosed.remove(row.id) }
                        else { expandedClosed.insert(row.id) }
                    } else {
                        applyChange { $0.root.update(row.id) { $0.isCollapsed.toggle() } }
                    }
                }
            ) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 14, height: 14)
            }
            .opacity(row.node.children.isEmpty || isFiltering ? 0 : 1)
            .allowsHitTesting(!row.node.children.isEmpty && !isFiltering)

            // Bullet that becomes a checkbox on hover (Things-style); on a
            // closed row it is permanently the filled check.
            Button {
                toggleClosed(row.id)
            } label: {
                ZStack {
                    Circle()
                        .fill(row.color)
                        .frame(width: 7, height: 7)
                        .opacity(row.closed || isHovered ? 0 : 1)
                    Image(systemName: row.closed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(row.closed ? Chrome.inactiveText : Color.secondary)
                        .opacity(row.closed || isHovered ? 1 : 0)
                }
                .frame(width: 13, height: 13)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .contentShape(Circle())
            }
            .buttonStyle(.panel)
            .disabled(row.level == 0)
            .opacity(row.level == 0 && isHovered ? 0.4 : 1)
            .help(row.level == 0 ? "" : (row.closed ? "Reopen topic (⌘↩)" : "Close topic (⌘↩)"))
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }

            if let icon = row.node.icon, !icon.isEmpty {
                Text(icon)
                    .font(.system(size: row.level == 0 ? 15 : 12))
                    .opacity(row.closed ? 0.55 : 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                // While searching, show a (non-editable) highlighted title so
                // hits are visible; the plain editable field returns when the
                // query clears. Closed rows are always static — closing means
                // done being written; reopen to edit.
                if row.closed {
                    Text(row.node.text.isEmpty ? "Topic" : row.node.text)
                        .font(titleFont)
                        .strikethrough(true, color: .secondary)
                        .foregroundStyle(.secondary)
                        .accessibilityValue("Closed")
                } else if searching {
                    HighlightedText(
                        text: row.node.text.isEmpty ? "Topic" : row.node.text,
                        query: searchQuery,
                        font: titleFont,
                        color: row.node.text.isEmpty ? .secondary : .primary
                    )
                } else {
                    TextField("Topic", text: textBinding(for: row.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(titleFont)
                }
                if let notesSnippet {
                    HighlightedText(text: notesSnippet, query: searchQuery,
                                    font: .system(size: 11), color: .secondary)
                        .lineLimit(1)
                }
            }

            if let due = row.node.dueDate {
                // A closed overdue topic must not shout — its chip is always
                // the quiet neutral one.
                let overdue = !row.closed && due < Calendar.current.startOfDay(for: Date())
                HStack(spacing: 3) {
                    Image(systemName: "calendar").font(.system(size: 8, weight: .bold))
                    Text(Metrics.dueString(due)).font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(overdue ? Color.white : .secondary)
                .background(Capsule().fill(overdue ? Color.red : Color.primary.opacity(0.07)))
            }

            ForEach(row.node.tags, id: \.self) { tag in
                let hitTag = searching && NodeSearch.fold(tag).contains(foldedQuery)
                Text("#" + tag)
                    .font(.system(size: 10, weight: hitTag ? .bold : .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, hitTag ? 4 : 0)
                    .padding(.vertical, hitTag ? 1 : 0)
                    .background(
                        Capsule().fill(hitTag ? Palette.selection.opacity(0.16) : Color.clear)
                    )
                    .opacity(row.closed ? 0.55 : 1)
            }

            if !row.node.notes.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .opacity(row.closed ? 0.55 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(row.level) * 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = row.id }
        .onHover { hovering in hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID) }
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { document.root.node(with: id)?.text ?? "" },
            set: { new in document.root.update(id) { $0.text = new } }
        )
    }
}
