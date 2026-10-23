import SwiftUI

enum DropMode { case child, before, after }

/// A topic's part in an in-progress ⌥-drag connection.
enum LinkDragRole { case none, source, target }

struct DropIndicator: Equatable {
    var id: UUID
    var mode: DropMode
}

/// One topic bubble with its badges, buttons, and inline editor.
///
/// Deliberately `Equatable` over plain value inputs: the canvas re-renders on
/// every selection, hover, and drag tick, and the equality check lets SwiftUI
/// skip the body of every node whose inputs did not change. Closures live in
/// `Actions` and are excluded from the comparison — they only read state at
/// call time, so a stale closure still behaves correctly.
struct NodeView: View, Equatable {
    /// One closed direct child, as the review popover shows it.
    struct ClosedChildInfo: Identifiable {
        let id: UUID
        let text: String
        let closedAt: Date?
        let subtopicCount: Int
    }

    struct Actions {
        var toggleCollapse: () -> Void
        /// Pointer landed on the collapse badge — a click is probably coming.
        var prepareCollapseToggle: () -> Void
        var addChild: () -> Void
        var expandCollapsedDue: (CollapsedDueInfo) -> Void
        var openLink: (String) -> Void
        var showNotes: () -> Void
        var setDatePickerShown: (Bool) -> Void
        var setDueDate: (Date) -> Void
        var removeDueDate: () -> Void
        /// Pointer entered/left one of the node's floating buttons — keeps the
        /// node "hovered" while the pointer travels off the bubble onto them.
        var affordanceHoverChanged: (Bool) -> Void
        var commit: (String) -> Void
        var commitAndAddChild: (String) -> Void
        var cancelEditing: () -> Void
        /// Closed direct children, most recently closed first — read at call
        /// time so the popover always shows the live document.
        var closedChildren: () -> [ClosedChildInfo]
        var reopenClosedChild: (UUID) -> Void
        var reopenAllClosed: () -> Void
        /// Switches to the outline with closed topics shown; non-nil selects
        /// that topic there.
        var revealClosedInOutline: (UUID?) -> Void
        var setClosedPopoverShown: (Bool) -> Void
    }

    var geom: NodeGeom
    var zoom: CGFloat
    var isSelected: Bool
    /// Part of a multi-selection but not the primary — a quieter ring, so it is
    /// always obvious which topic the inspector and the arrow keys follow.
    var isSecondarySelected: Bool = false
    /// This topic is the anchor or the live target of an ⌥-drag connection.
    var linkRole: LinkDragRole = .none
    var isHovered: Bool
    var anyDragActive: Bool
    var dropMode: DropMode?
    /// Non-nil while this node is being edited; carries the live draft text.
    var editingDraft: String?
    /// Whether entering the editor should highlight the existing text
    /// (deliberate edit) rather than just park the caret (typing to replace).
    var selectDraftOnFocus: Bool = true
    var datePickerShown: Bool
    var closedPopoverShown: Bool = false
    /// Find-bar highlight role for this node.
    var searchMatch: SearchMatchState = .none
    @Binding var draft: String
    var actions: Actions

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: NodeView, rhs: NodeView) -> Bool {
        lhs.geom.matchesRendering(of: rhs.geom)
            && lhs.zoom == rhs.zoom
            && lhs.isSelected == rhs.isSelected
            && lhs.isSecondarySelected == rhs.isSecondarySelected
            && lhs.linkRole == rhs.linkRole
            && lhs.isHovered == rhs.isHovered
            && lhs.anyDragActive == rhs.anyDragActive
            && lhs.dropMode == rhs.dropMode
            && lhs.editingDraft == rhs.editingDraft
            && lhs.datePickerShown == rhs.datePickerShown
            && lhs.closedPopoverShown == rhs.closedPopoverShown
            && lhs.searchMatch == rhs.searchMatch
    }

    /// Counts how many node bodies SwiftUI actually builds. Read by
    /// `CollapseBenchmark` to separate "the map recomputed" from "the map
    /// re-rendered", which are very different costs.
    static var bodyEvaluations = 0

    /// A function, not a bare statement: `body` is a ViewBuilder, which only
    /// accepts expressions that are themselves views.
    private static func recordBodyEvaluation() -> EmptyView {
        bodyEvaluations += 1
        return EmptyView()
    }

    private var isEditing: Bool { editingDraft != nil }
    private var displayText: String { geom.text.isEmpty ? "Topic" : geom.text }

    var body: some View {
        let _ = Self.recordBodyEvaluation()
        let pad = Metrics.padding(for: geom.level)
        let renderedText = editingDraft ?? displayText
        // Scaled from the scale-1 measurement the layout sized this node with,
        // never re-measured at `scale: zoom` — see `Metrics.displayTextWidth`.
        let textWidth = Metrics.displayTextWidth(for: renderedText, level: geom.level, zoom: zoom)

        VStack(spacing: 4 * zoom) {
            Group {
                if let stored = geom.image, let image = ImageStore.image(for: stored) {
                    let size = stored.displaySize(maxWidth: Metrics.maxImageWidth)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width * zoom, height: size.height * zoom)
                        .clipShape(RoundedRectangle(cornerRadius: 6 * zoom))
                        .padding(.bottom, (Metrics.imageGap - 4) * zoom)
                }
                if isEditing {
                    // The field editor (NSTextView) eats ~5pt of line-fragment
                    // padding per side, wrapping earlier than the measured text
                    // and clipping lines. Widen the field by that amount — it
                    // extends into the node's padding, so the box looks the same.
                    let editorWidth = max(textWidth, 50) + 12
                    let onDarkFill = geom.level <= 1
                    InlineTextEditor(
                        text: $draft,
                        font: Metrics.nsFont(for: geom.level, scale: zoom),
                        textColor: onDarkFill ? .white : .labelColor,
                        // A black caret vanishes on the navy/colored fills, and
                        // a 1pt hairline is easy to miss on a light one — pick
                        // whichever reads against this node.
                        caretColor: onDarkFill ? .white : NSColor(Palette.selection),
                        selectionColor: onDarkFill
                            ? NSColor(Color.white.opacity(0.85))
                            : NSColor(Palette.selection),
                        selectedTextColor: onDarkFill ? NSColor(Palette.selection) : .white,
                        width: editorWidth,
                        initialSelection: selectDraftOnFocus ? .all : .end,
                        onCommit: actions.commit,
                        onCancel: actions.cancelEditing,
                        onTab: actions.commitAndAddChild
                    )
                    .frame(width: editorWidth)
                    .background(editingWell)
                } else {
                    HStack(spacing: Metrics.iconGap * zoom) {
                        if let icon = geom.icon, !icon.isEmpty {
                            Text(icon)
                                .font(.system(size: Metrics.fontSize(for: geom.level) * 1.15 * zoom))
                                .frame(width: Metrics.iconWidth(for: geom.level) * zoom,
                                       alignment: .center)
                        }
                        Text(displayText)
                            .font(Metrics.font(for: geom.level, scale: zoom))
                            .foregroundStyle(textColor)
                            .multilineTextAlignment(.center)
                            .lineLimit(Metrics.lineCount(for: renderedText, level: geom.level))
                            .allowsTightening(true)
                            .minimumScaleFactor(0.7)
                            .frame(width: textWidth)
                    }
                    // No gesture of its own: label and fill are one target,
                    // so a click cannot mean two different things depending
                    // on which part of the card it lands in. The bubble's
                    // gestures in EditorView handle select and rename.
                }
                if !geom.tags.isEmpty {
                    HStack(spacing: 4 * zoom) {
                        ForEach(Array(geom.tags.prefix(Metrics.maxVisibleTags)), id: \.self) { tag in
                            metaChip(Metrics.chipLabel(tag, level: geom.level))
                        }
                        if geom.tags.count > Metrics.maxVisibleTags {
                            metaChip("+\(geom.tags.count - Metrics.maxVisibleTags)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, pad.h * zoom)
        .padding(.vertical, pad.v * zoom)
        .background(nodeShape)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius * zoom)
                    .stroke(Palette.selection, lineWidth: 2.5)
                    .padding(-3)
                    .shadow(color: Palette.selection.opacity(0.35), radius: 6, y: 2)
            } else if isSecondarySelected {
                RoundedRectangle(cornerRadius: cornerRadius * zoom)
                    .stroke(Palette.selection.opacity(0.7), lineWidth: 1.8)
                    .padding(-2)
            }
        }
        .overlay {
            // ⌥-drag feedback: the anchor keeps a steady ring, a candidate
            // target lights up so dropping is never a guess.
            switch linkRole {
            case .source:
                RoundedRectangle(cornerRadius: cornerRadius * zoom)
                    .stroke(Palette.crossLink.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .padding(-4)
            case .target:
                RoundedRectangle(cornerRadius: cornerRadius * zoom)
                    .stroke(Palette.crossLink, lineWidth: 3)
                    .padding(-4)
                    .shadow(color: Palette.crossLink.opacity(0.5), radius: 6)
            case .none:
                EmptyView()
            }
        }
        .overlay {
            // Find highlight. The current match gets a glow; other matches a
            // quiet ring. Skipped when the node is already wearing the (same
            // color, heavier) selection ring so they don't stack.
            switch searchMatch {
            case .current where !isSelected:
                RoundedRectangle(cornerRadius: cornerRadius * zoom)
                    .stroke(Palette.selection, lineWidth: 3)
                    .padding(-3)
                    .shadow(color: Palette.selection.opacity(0.6), radius: 8)
            case .match:
                RoundedRectangle(cornerRadius: cornerRadius * zoom)
                    .stroke(Palette.selection.opacity(0.55), lineWidth: 2)
                    .padding(-2)
            default:
                EmptyView()
            }
        }
        .overlay {
            if dropMode == .child {
                RoundedRectangle(cornerRadius: cornerRadius * zoom)
                    .stroke(Color.green, lineWidth: 3)
                    .padding(-4)
            }
        }
        .overlay(alignment: .top) {
            if dropMode == .before {
                Capsule().fill(Color.green)
                    .frame(width: max(geom.rect.width * zoom * 0.9, 40), height: 3)
                    .offset(y: -8)
            }
        }
        .overlay(alignment: .bottom) {
            if dropMode == .after {
                Capsule().fill(Color.green)
                    .frame(width: max(geom.rect.width * zoom * 0.9, 40), height: 3)
                    .offset(y: 8)
            }
        }
        .overlay(alignment: geom.side == .right ? .trailing : .leading) {
            collapseButton
        }
        .overlay(alignment: .topLeading) {
            if let due = geom.dueDate, !isEditing, zoom >= 0.5 {
                let badgeScale = min(zoom, 1)
                Button {
                    actions.setDatePickerShown(true)
                } label: {
                    dueChip(due, identity: geom.color)
                }
                .buttonStyle(.nodeBadge)
                .scaleEffect(badgeScale, anchor: .topLeading)
                .offset(x: 4 * badgeScale, y: -9 * badgeScale)
                .help("Change due date")
                .popover(
                    isPresented: Binding(
                        get: { datePickerShown },
                        set: { actions.setDatePickerShown($0) }
                    ),
                    arrowEdge: .bottom
                ) {
                    DueDateCalendar(
                        selection: geom.dueDate,
                        onSelect: { actions.setDueDate($0) },
                        onRemove: { actions.removeDueDate() }
                    )
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let link = geom.link, !link.isEmpty, !isEditing {
                Button {
                    actions.openLink(link)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Palette.selection).shadow(radius: 1))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
                .buttonStyle(.nodeBadge)
                .scaleEffect(min(zoom, 1), anchor: .topTrailing)
                .offset(x: 5 * min(zoom, 1), y: -7 * min(zoom, 1))
                .help(link)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let info = geom.collapsedDue, !isEditing, zoom >= 0.5 {
                let badgeScale = min(zoom, 1)
                let hasLinkBadge = !(geom.link ?? "").isEmpty
                Button {
                    actions.expandCollapsedDue(info)
                } label: {
                    dueChip(info.date, identity: info.color)
                }
                .buttonStyle(.nodeBadge)
                .opacity(0.8)
                .scaleEffect(badgeScale, anchor: .topTrailing)
                .offset(x: (hasLinkBadge ? -14 : 6) * badgeScale, y: -9 * badgeScale)
                .help("Earliest due date in this branch — click to expand")
            }
        }
        .overlay(alignment: geom.side == .right ? .trailing : .leading) {
            // A collapsed branch offers expanding and nothing else: adding a
            // child there would drop it in among topics still hidden from
            // view. A childless topic has nothing to expand, so it offers only
            // "add". The two affordances are never both on offer without the
            // branch being open in front of you.
            if isSelected || isHovered, !isEditing, !anyDragActive, !geom.isCollapsed {
                let distance: CGFloat = geom.childCount > 0 ? 42 : 17
                Button {
                    actions.addChild()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(geom.color).shadow(color: .black.opacity(0.25), radius: 3, y: 1))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                }
                .buttonStyle(.nodeBadge)
                .offset(x: geom.side == .right ? distance : -distance)
                .onHover { hovering in
                    actions.affordanceHoverChanged(hovering)
                }
                .help("Add child topic (Tab)")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Marks topics that carry notes, and opens the panel on them. It
            // is the only on-card way in: clicking a bubble now only selects,
            // so everything else routes through ⌘I, the toolbar button, or
            // the context menu.
            if geom.hasNotes, !isEditing {
                Button {
                    actions.showNotes()
                } label: {
                    Image(systemName: "note.text")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(geom.color).shadow(radius: 1))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                }
                .buttonStyle(.nodeBadge)
                .scaleEffect(min(zoom, 1), anchor: .bottomTrailing)
                .offset(x: 5 * min(zoom, 1), y: 7 * min(zoom, 1))
                .onHover { hovering in
                    actions.affordanceHoverChanged(hovering)
                }
                .help("Show details and notes (⌘I)")
            }
        }
        .overlay(alignment: geom.side == .right ? .bottomLeading : .bottomTrailing) {
            // ✓N badge: the map's only trace of closed children. Deliberately
            // achromatic so finished work never competes with the branch
            // palette. Mirrors the due chip's construction so it reads as the
            // same badge family.
            if geom.progress.done > 0, !isEditing, zoom >= 0.5 {
                let badgeScale = min(zoom, 1)
                let anchor: UnitPoint = geom.side == .right ? .bottomLeading : .bottomTrailing
                // The notes badge owns the bottom-trailing corner; step inward
                // when both are present (same trick as the collapsed-due chip).
                let inward: CGFloat = geom.side == .left && geom.hasNotes ? -18 : 0
                Button {
                    actions.setClosedPopoverShown(true)
                } label: {
                    progressBadge
                }
                .buttonStyle(.nodeBadge)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: geom.progress)
                .scaleEffect(badgeScale, anchor: anchor)
                .offset(x: (geom.side == .right ? -5 : 5 + inward) * badgeScale, y: 7 * badgeScale)
                .onHover { hovering in
                    actions.affordanceHoverChanged(hovering)
                }
                .help("\(geom.progress.done) of \(geom.progress.total) topics in this branch are closed — click to review")
                .accessibilityLabel("\(geom.progress.done) of \(geom.progress.total) topics closed")
                .accessibilityHint("Shows closed topics under this one")
                .popover(
                    isPresented: Binding(
                        get: { closedPopoverShown },
                        set: { actions.setClosedPopoverShown($0) }
                    ),
                    arrowEdge: .bottom
                ) {
                    closedPopover
                }
            }
        }
    }

    /// Branch completion: a ring around the done/total count.
    ///
    /// This is the old ✓N badge grown up. It sits in the same corner and means
    /// the same thing — finished work below here — but counts the whole subtree
    /// rather than only direct children, and shows how much of the branch that
    /// is. Deliberately achromatic until it is full, so progress never competes
    /// with the branch palette; a completed branch earns its color.
    private var progressBadge: some View {
        let done = geom.progress.done
        let total = geom.progress.total
        let complete = done >= total && total > 0
        let ring = complete ? Palette.done : Chrome.inactiveText
        return ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, geom.progress.fraction))
                .stroke(ring, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if complete {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ring)
            } else {
                Text("\(done)")
                    .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Chrome.text)
            }
        }
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1))
        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2).padding(-1))
    }

    /// Review popover behind the ✓N badge: every closed direct child with
    /// when it closed, plus reopen-in-place and jump-to-outline actions.
    private var closedPopover: some View {
        let items = actions.closedChildren()
        return VStack(alignment: .leading, spacing: 0) {
            Text("CLOSED")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            if items.isEmpty {
                // The ring counts the whole subtree, so it can be lit while
                // every closed topic sits further down. Say so rather than
                // showing an empty list.
                Text("The closed topics in this branch are deeper down.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            ClosedChildRow(
                                info: item, color: geom.color,
                                reopen: { actions.reopenClosedChild(item.id) },
                                reveal: { actions.revealClosedInOutline(item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 240)
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if items.count > 1 {
                    closedPopoverAction("Reopen All", systemImage: "arrow.uturn.backward") {
                        actions.reopenAllClosed()
                    }
                }
                closedPopoverAction("Show in Outline", systemImage: "list.bullet.indent") {
                    actions.revealClosedInOutline(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 260)
    }

    private func closedPopoverAction(_ title: String, systemImage: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.panel)
    }

    /// One row of the closed-children popover; the reopen button reveals on
    /// hover, the row body jumps to the topic in the outline.
    private struct ClosedChildRow: View {
        let info: ClosedChildInfo
        let color: Color
        let reopen: () -> Void
        let reveal: () -> Void
        @State private var hovered = false

        var body: some View {
            HStack(spacing: 8) {
                Button(action: reveal) {
                    HStack(spacing: 8) {
                        Circle().fill(color.opacity(0.5)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.text)
                                .font(.system(size: 12.5, weight: .medium))
                                .strikethrough(true, color: .secondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if info.subtopicCount > 0 {
                                    Text("\(info.subtopicCount) subtopic\(info.subtopicCount == 1 ? "" : "s") ·")
                                }
                                if let closedAt = info.closedAt {
                                    Text(closedAt, format: .relative(presentation: .named))
                                }
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.panel)
                if hovered {
                    Button(action: reopen) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.selection)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Palette.selection.opacity(0.12)))
                    }
                    .buttonStyle(.nodeBadge)
                    .help("Reopen topic")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .onHover { hovered = $0 }
        }
    }

    // MARK: Pieces

    private var cornerRadius: CGFloat {
        switch geom.level {
        case 0: return 15
        case 1: return 12
        default: return 10
        }
    }

    private var textColor: Color {
        geom.level <= 1 ? .white : .primary
    }

    /// Text-field affordance drawn behind the inline editor: without it an
    /// active editor looks exactly like a static label. Negative padding lets
    /// the well bleed into the node's own padding, so entering edit mode does
    /// not resize the bubble.
    private var editingWell: some View {
        let shape = RoundedRectangle(cornerRadius: 6 * zoom)
        return shape
            .fill(geom.level <= 1 ? Color.black.opacity(0.22) : Color.primary.opacity(0.05))
            .overlay(shape.stroke(Palette.selection.opacity(0.9), lineWidth: 1.5))
            .padding(EdgeInsets(top: -3 * zoom, leading: -5 * zoom,
                                bottom: -3 * zoom, trailing: -5 * zoom))
    }

    @ViewBuilder
    private var nodeShape: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius * zoom)
        switch geom.level {
        case 0:
            // Deep navy gradient for the default root; a color override
            // gets the same gradient treatment in its own hue.
            let isDefault = geom.color == Palette.root
            shape.fill(LinearGradient(
                colors: isDefault
                    ? [Palette.rootGradientTop, Palette.rootGradientBottom]
                    : [geom.color.lightened(0.12), geom.color.darkened(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: Color(red: 0.12, green: 0.16, blue: 0.26).opacity(0.5), radius: 8, y: 4)
        case 1:
            shape.fill(LinearGradient(
                colors: [geom.color.lightened(0.12), geom.color.darkened(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .shadow(color: geom.color.opacity(0.5), radius: 6, y: 3)
        default:
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.stroke(geom.color.opacity(0.5), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
    }

    @ViewBuilder
    private var collapseButton: some View {
        if geom.childCount > 0 {
            PressActionButton(
                help: geom.isCollapsed ? "Expand this branch" : "Collapse this branch",
                accessibilityLabel: geom.isCollapsed
                    ? "Expand \(geom.childCount) hidden topics" : "Collapse branch",
                prepare: actions.prepareCollapseToggle,
                action: actions.toggleCollapse
            ) {
                // Count (collapsed) and minus (expanded) crossfade rather than
                // hard-swap, so the badge sells the state change on the same
                // beat as the fold. Opacity only — no counting digits, no spin.
                ZStack {
                    Text("\(geom.childCount)")
                        .font(.system(size: 10, weight: .bold))
                        .opacity(geom.isCollapsed ? 1 : 0)
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(geom.isCollapsed ? 0 : 1)
                }
                .foregroundStyle(.white)
                .animation(.easeOut(duration: 0.10), value: geom.isCollapsed)
                .frame(width: 18, height: 18)
                .background(Circle().fill(geom.level == 0 ? Palette.root : geom.color)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5))
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
            .offset(x: geom.side == .right ? 13 : -13)
        }
    }

    /// Corner due-date chip (spec: identity color when future, amber today,
    /// red overdue; background-colored ring lifts it off the node fill).
    private func dueChip(_ date: Date, identity: Color) -> some View {
        let overdue = DayClock.isOverdue(date)
        let today = DayClock.isToday(date)
        let dark = colorScheme == .dark

        let fill: Color
        let textColor: Color
        if overdue {
            fill = dark ? Color(red: 1.0, green: 0.39, blue: 0.41) : Color(red: 0.90, green: 0.28, blue: 0.30)
            textColor = .white
        } else if today {
            fill = dark ? Color(red: 0.96, green: 0.65, blue: 0.14) : Color(red: 0.95, green: 0.63, blue: 0.05)
            textColor = Color(red: 0.11, green: 0.11, blue: 0.12)
        } else {
            // Same hue as the node, deepened 15% so it reads on its own fill.
            fill = Color(nsColor: NSColor(identity).blended(withFraction: 0.15, of: .black) ?? .black)
            textColor = .white
        }

        return HStack(spacing: 3) {
            Image(systemName: "calendar")
                .font(.system(size: 8.5, weight: .semibold))
            Text(Metrics.dueString(date))
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(textColor)
        .padding(EdgeInsets(top: 2.5, leading: 6, bottom: 2.5, trailing: 7))
        .background(Capsule().fill(fill).shadow(color: .black.opacity(0.2), radius: 2, y: 1))
        .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        .fixedSize()
    }

    /// Design "soft dot pill": neutral fill with a branch-colored dot on
    /// white nodes; translucent white on filled (root/level-1) nodes.
    @ViewBuilder
    private func metaChip(_ text: String) -> some View {
        HStack(spacing: 4 * zoom) {
            if geom.level >= 2 {
                Circle()
                    .fill(geom.color)
                    .frame(width: 6 * zoom, height: 6 * zoom)
            }
            Text(text).font(.system(size: Metrics.metaFontSize * zoom, weight: .semibold))
        }
        .padding(.horizontal, 6 * zoom)
        .padding(.vertical, 2 * zoom)
        .foregroundStyle(geom.level <= 1 ? Color.white : Color.primary.opacity(0.75))
        .background(
            Capsule().fill(geom.level <= 1 ? Color.white.opacity(0.22)
                           : Color.primary.opacity(0.06))
        )
        .lineLimit(1)
    }
}
