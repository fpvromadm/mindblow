import SwiftUI
import AppKit

struct EditorView: View {
    @Binding var document: MindMapDocument
    @Environment(\.undoManager) private var undoManager

    @State private var selection: UUID?
    @State private var editingID: UUID?
    @State private var editingSelectsAll = true
    @State private var draft = ""

    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
    /// Keeps the node you just folded where it was. See `anchorSide(on:)`.
    @State private var sideOffsets = SideOffsets()
    @GestureState private var dragPan: CGSize = .zero
    @State private var zoomAtGestureStart: CGFloat?
    @State private var canvasSize: CGSize = .zero

    @FocusState private var focus: FocusTarget?
    enum FocusTarget: Hashable { case canvas, editor }

    @State private var showNotes = false
    /// The panel's title field is draft-backed rather than bound straight to
    /// the node: a live binding would register an undo step and re-lay out the
    /// whole map on every keystroke. Commits on Enter or on losing focus.
    @State private var titleDraft = ""
    /// True while the notes editor holds first responder — canvas shortcuts
    /// are suppressed so typing notes can't mutate the map.
    @State private var notesFocused = false
    @FocusState private var inspectorField: InspectorField?
    enum InspectorField: Hashable { case link, tag, title }
    /// Click bookkeeping for the bubble's own double-click detection.
    @State private var lastClickID: UUID?
    @State private var lastClickAt = Date.distantPast
    @State private var hoveredID: UUID?
    @State private var affordanceHovered = false
    @State private var newTagText = ""
    /// Which suggestion the keyboard is on, if any. Nil means ↩ adds exactly
    /// what was typed — typing "work" where "workshop" exists must not be
    /// quietly turned into the longer tag.
    @State private var tagHighlight: Int?
    /// Esc hides the suggestions without giving up the field.
    @State private var tagSuggestionsHidden = false
    @State private var activeTags: Set<String> = []
    /// Slide-down tag chip bar under the toolbar.
    @State private var showFilterBar = false
    /// Type-to-narrow the chip list itself (not the map); only surfaces once
    /// there are enough tags for the row to be worth searching.
    @State private var tagChipQuery = ""
    /// ⌘F find bar state.
    @State private var showFindBar = false
    @State private var searchQuery = ""
    /// Node ids matching the query (∩ the tag filter), in document order.
    /// Closed topics never match here — the map cannot lay them out.
    @State private var searchMatches: [UUID] = []
    /// Hits living only inside closed subtrees; offered as an outline jump
    /// when the open result set is empty.
    @State private var closedSearchMatches = 0
    @State private var currentMatchIndex = 0
    @FocusState private var findFocused: Bool
    @State private var showAgenda = false
    /// Whether closed topics are listed in the outline. A view preference,
    /// not document state; the map never shows closed topics regardless.
    @State private var showClosed = false
    /// Node whose ✓N closed-children popover is open.
    @State private var closedPopoverNodeID: UUID?
    @State private var datePickerNodeID: UUID?
    @State private var inspectorDatePickerShown = false
    @State private var showHelp = false
    @State private var pendingDelete: UUID?
    /// Topics a confirmed bulk delete would remove.
    @State private var pendingBulkDelete: [UUID]?
    @State private var dragNodeID: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var dropIndicator: DropIndicator?
    enum ViewMode { case map, outline }
    @State private var viewMode: ViewMode = .map
    @State private var dragDescendants: Set<UUID> = []

    /// Topic the canvas is drilled into, drawn as if it were the whole map.
    /// nil is the ordinary whole-document view.
    @State private var focusedRootID: UUID?

    /// Secondary selection. Empty for an ordinary single selection; otherwise
    /// it always contains `selection`, which stays the primary — the topic the
    /// inspector follows and the one arrow keys move from.
    @State private var selectedIDs: Set<UUID> = []
    /// Live marquee rectangle in canvas (screen) coordinates.
    @State private var marquee: CGRect?
    /// Selection the marquee started from, so a shift-drag adds to it rather
    /// than replacing it.
    @State private var marqueeBase: Set<UUID> = []

    /// ⌥-drag in progress: the topic it started on, where the pointer is, and
    /// the topic it would connect to.
    @State private var linkDragFrom: UUID?
    @State private var linkDragPoint: CGPoint?
    @State private var linkDragTarget: UUID?
    /// Connection whose label is being edited in the inspector.
    @State private var editingLinkID: UUID?
    @State private var linkLabelDraft = ""

    @State private var exportError: String?
    @State private var iconPickerShown = false
    @State private var iconDraft = ""

    // MARK: Layout

    /// Memoization for values derived from the document tree. A reference
    /// type held in @State on purpose: filling it during body evaluation
    /// must not invalidate the view, and the layout must not be rebuilt on
    /// every access (it used to be — every hover, scroll tick, and click
    /// re-ran the whole layout engine).
    private final class DerivedCache {
        var layoutRoot: MindNode?
        var layout: MapLayout?
        var derivedRoot: MindNode?
        var allTags: [String] = []
        var dueItems: [DueItem] = []
        /// Topics hidden by closing — explicit closes plus their subtrees.
        var closedCount = 0
        /// A layout for a tree we expect to be asked for shortly — built
        /// while the pointer sits on a collapse badge. Promoted to `layout`
        /// if the click actually produces this tree, discarded otherwise.
        var speculativeRoot: MindNode?
        var speculativeLayout: MapLayout?
        /// `layout` with the side anchor folded in, keyed on what produced it.
        var anchored: MapLayout?
        var anchoredGeneration: Int?
        var anchoredOffsets: SideOffsets?
    }
    @State private var cache = DerivedCache()

    /// The topic the canvas treats as its center. Focus mode's whole
    /// implementation: every mutation still addresses nodes by id against
    /// `document.root`, so only the *view* of the tree moves.
    private var focusedNode: MindNode? {
        focusedRootID.flatMap { document.root.node(with: $0) }
    }

    /// Id of whatever is currently drawn at the center. Guards that mean "you
    /// can't do this to the thing everything hangs off" use this rather than
    /// the document root, since in focus mode they are not the same node.
    private var layoutRootID: UUID { focusedNode?.id ?? document.root.id }

    /// Layout uses the live draft for the node being edited so the map
    /// reflows as you type.
    private var layoutRoot: MindNode {
        var root = focusedNode ?? document.root
        if let editingID {
            root.update(editingID) { $0.text = draft }
        }
        return root
    }

    /// Layout in its natural, centered form — the pure function of the tree.
    /// The anchor correction is applied on top, in `layout`.
    private var baseLayout: MapLayout {
        let root = layoutRoot
        if let cached = cache.layout, cache.layoutRoot == root { return cached }
        // The toggle we predicted on hover is the one that happened — take it
        // instead of laying the whole map out again.
        if let speculative = cache.speculativeLayout, cache.speculativeRoot == root {
            cache.layoutRoot = root
            cache.layout = speculative
            cache.speculativeRoot = nil
            cache.speculativeLayout = nil
            return speculative
        }
        let fresh = MapLayout(root: root)
        cache.layoutRoot = root
        cache.layout = fresh
        return fresh
    }

    private var layout: MapLayout {
        let base = baseLayout
        guard !sideOffsets.isZero else { return base }
        if let anchored = cache.anchored, cache.anchoredGeneration == base.generation,
           cache.anchoredOffsets == sideOffsets {
            return anchored
        }
        let anchored = base.applying(sideOffsets)
        cache.anchored = anchored
        cache.anchoredGeneration = base.generation
        cache.anchoredOffsets = sideOffsets
        return anchored
    }

    /// Pins `id` in place across a fold: whatever the fresh layout does to its
    /// vertical position, shift that one side back by the same amount.
    ///
    /// Everything above it on that side is left pixel-stable, everything below
    /// closes the gap (the point of folding), and the opposite side is not
    /// touched at all. The offset is recomputed absolutely each time rather
    /// than accumulated, so it can't drift.
    private func anchorSide(on id: UUID, after change: (inout MindNode) -> Void) {
        var newRoot = layoutRoot
        newRoot.update(id, change)
        // The hover pass has usually built this already.
        let fresh = cache.speculativeRoot == newRoot
            ? cache.speculativeLayout ?? MapLayout(root: newRoot)
            : MapLayout(root: newRoot)
        sideOffsets.anchor(id, shown: layout, base: fresh)
    }

    /// Warms everything a collapse/expand of `id` will need, while the pointer
    /// is still on the badge.
    ///
    /// Two costs get moved off the click. The layout pass, which re-measures
    /// every visible node; and the per-node text measurement at the current
    /// zoom, which the layout engine only ever caches at scale 1 — so newly
    /// revealed nodes would each pay a fresh TextKit pass at render time.
    ///
    /// If the document changes between the hover and the click, the predicted
    /// tree simply will not match and the layout is rebuilt as before.
    private func prepareCollapseToggle(for id: UUID) {
        var root = focusedNode ?? document.root
        if let editingID { root.update(editingID) { $0.text = draft } }
        root.update(id) { $0.isCollapsed.toggle() }
        guard cache.speculativeRoot != root, cache.layoutRoot != root else { return }

        let speculative = MapLayout(root: root)
        cache.speculativeRoot = root
        cache.speculativeLayout = speculative
        // Only the nodes that will actually be on screen — the render pass
        // never asks for the rest.
        guard zoom != 1, canvasSize.width > 0 else { return }
        for visible in visibleIDs(speculative, viewSize: canvasSize) {
            guard let geom = speculative.nodes[visible] else { continue }
            _ = Metrics.textSize(for: geom.text, level: geom.level, scale: zoom)
        }
    }

    /// Ids of the nodes worth building right now: the ones on screen, plus any
    /// that must stay alive wherever they are.
    ///
    /// The canvas is clipped, so every off-screen node used to be fully built
    /// — gradients, shadows, badges, context menu — and then thrown away by
    /// the clip. Expanding a branch on a large map therefore paid to render
    /// the entire map, which is where the delay after clicking a collapse
    /// badge came from. Culling makes that cost track what you can see rather
    /// than how big the document is.
    private func visibleIDs(_ layout: MapLayout, viewSize: CGSize) -> [UUID] {
        guard viewSize.width > 0, viewSize.height > 0 else { return layout.order }
        // Generous margin: badges overhang their node's rect, and nodes should
        // be ready slightly before they scroll into view.
        let viewport = CGRect(origin: .zero, size: viewSize).insetBy(dx: -160, dy: -160)
        return layout.order.filter { id in
            // The node being edited owns the AppKit field editor and the one
            // being dragged owns the gesture — culling either mid-interaction
            // would tear it out from under the user.
            if id == editingID || id == dragNodeID { return true }
            guard let geom = layout.nodes[id] else { return false }
            let origin = screen(CGPoint(x: geom.rect.minX, y: geom.rect.minY), in: viewSize)
            return viewport.intersects(CGRect(
                x: origin.x, y: origin.y,
                width: geom.rect.width * zoom, height: geom.rect.height * zoom
            ))
        }
    }

    /// Drives `CollapseBenchmark` when `MINDBLOW_BENCH` is set; otherwise does
    /// nothing and costs one environment lookup at launch.
    private func startBenchmarkIfRequested() {
        guard let count = CollapseBenchmark.requestedNodeCount else { return }
        let tree = CollapseBenchmark.makeTree(nodeCount: count)
        document.root = tree
        selection = tree.id
        guard let target = tree.children.first?.id else { return }
        CollapseBenchmark.run { _ in
            apply { $0.root.update(target) { $0.isCollapsed.toggle() } }
        }
    }

    private func screen(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: point.x * zoom + pan.width + dragPan.width + size.width / 2,
            y: point.y * zoom + pan.height + dragPan.height + size.height / 2
        )
    }

    // MARK: Body

    private var canvasView: some View {
        let layout = self.layout
        return GeometryReader { geo in
            ZStack {
                background
                edgesCanvas(layout, viewSize: geo.size)
                ForEach(visibleIDs(layout, viewSize: geo.size), id: \.self) { id in
                    if let geom = layout.nodes[id] {
                        nodeView(id: id, geom: geom, viewSize: geo.size)
                    }
                }
                marqueeOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .coordinateSpace(name: "canvas")
            .background(ScrollWheelMonitor(onScroll: handleScroll))
            .overlay(alignment: .bottom) {
                if selectedIDs.count > 1 {
                    multiSelectBar
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: selectedIDs.count > 1)
            .overlay(alignment: .bottomTrailing) {
                minimap(layout, viewSize: geo.size)
                    .padding(12)
                    // The floating panel owns the right edge while it is open;
                    // step aside instead of hiding underneath it.
                    .padding(.trailing, showNotes ? 300 : 0)
                    .animation(.snappy(duration: 0.22), value: showNotes)
            }
            .onChange(of: geo.size, initial: true) { _, newSize in canvasSize = newSize }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .canvas)
        .onKeyPress(.tab) {
            guard !notesFocused, inspectorField == nil else { return .ignored }
            addChildToSelection()
            return .handled
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
            // Plain Return only — ⌘Return belongs to Close Topic (the hidden
            // shortcut button), and matching it here would add a sibling.
            guard press.modifiers.isEmpty, !notesFocused, inspectorField == nil else { return .ignored }
            if editingID != nil {
                // First Enter just finishes editing; the next one adds a sibling.
                commitEditing()
            } else {
                addSiblingToSelection()
            }
            return .handled
        }
        // While editing, these keys belong to the text field — pass them through.
        .onKeyPress(.space) {
            guard editingID == nil, !notesFocused, inspectorField == nil else { return .ignored }
            startEditingSelection()
            return .handled
        }
        .onKeyPress(.delete) {
            guard editingID == nil, !notesFocused, inspectorField == nil else { return .ignored }
            deleteTargets()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            guard editingID == nil, !notesFocused, inspectorField == nil else { return .ignored }
            deleteTargets()
            return .handled
        }
        .onKeyPress(.escape) {
            guard !notesFocused, inspectorField == nil else { return .ignored }
            if showFindBar {
                closeFind()
            } else if editingID != nil {
                cancelEditing()
            } else {
                selection = nil
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard editingID == nil, !notesFocused, inspectorField == nil else { return .ignored }
            navigate(.right)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard editingID == nil, !notesFocused, inspectorField == nil else { return .ignored }
            navigate(.left)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard editingID == nil, !notesFocused, inspectorField == nil else { return .ignored }
            navigate(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard editingID == nil, !notesFocused, inspectorField == nil else { return .ignored }
            navigate(.down)
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // Typing on a selected node starts editing and replaces its text.
            guard editingID == nil, !notesFocused, inspectorField == nil, selection != nil,
                  press.modifiers.subtracting(.shift).isEmpty,
                  let first = press.characters.first,
                  first.isLetter || first.isNumber || first.isSymbol || first.isPunctuation
            else { return .ignored }
            startEditing(selection!, initialDraft: press.characters)
            return .handled
        }
        .simultaneousGesture(magnifyGesture)
        .onDeleteCommand { deleteTargets() }
        .onAppear {
            selection = document.root.id
            focus = .canvas
            startBenchmarkIfRequested()
        }
        .overlay(alignment: .bottomLeading) { canvasControls.padding(12) }
    }

    /// Viewport controls that belong to the canvas, not the document header:
    /// zoom, fit-to-window, and the shortcuts help. Grouped bottom-left,
    /// opposite the minimap, so the toolbar carries only document actions.
    private var canvasControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                zoomButton("minus", help: "Zoom out") { setZoom(zoom / 1.2) }
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Chrome.toolIcon)
                    .frame(minWidth: 40)
                    .contentShape(Rectangle())
                    .onTapGesture { fitToWindow() }
                    .help("Reset to 100% and center")
                zoomButton("plus", help: "Zoom in") { setZoom(zoom * 1.2) }
                Divider().frame(height: 16)
                zoomButton("scope", help: "Fit map to window") { fitToWindow() }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))

            helpButton
        }
        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
    }

    private var contentStack: some View {
        HStack(spacing: 0) {
            if showAgenda {
                agendaSidebar
                    .frame(width: 300)
                    .transition(.move(edge: .leading))
                Divider()
            }
            if viewMode == .map {
                canvasView
            } else {
                OutlineView(
                    document: $document,
                    selection: $selection,
                    searchQuery: searchActive ? searchQuery : "",
                    activeTags: activeTags,
                    showClosed: $showClosed,
                    applyChange: { apply($0) },
                    toggleClosed: { toggleClosed($0) }
                )
            }
        }
        .animation(.snappy(duration: 0.22), value: showAgenda)
    }

    var body: some View {
        // Split from the alerts and toolbar below: as one expression the whole
        // thing outgrows the type checker.
        documentBody
            .alert(
                deleteAlertTitle,
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let id = pendingDelete { performDelete(id) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(deleteAlertMessage)
            }
            .alert(
                bulkDeleteTitle,
                isPresented: Binding(
                    get: { pendingBulkDelete != nil },
                    set: { if !$0 { pendingBulkDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let targets = pendingBulkDelete { performBulkDelete(targets) }
                    pendingBulkDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingBulkDelete = nil }
            } message: {
                Text(bulkDeleteMessage)
            }
            .alert(
                "Export failed",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .toolbar { toolbarContent }
    }

    private var bulkDeleteTitle: String {
        let count = pendingBulkDelete?.count ?? 0
        return "Delete \(count) topics?"
    }

    private var documentBody: some View {
        VStack(spacing: 0) {
            if showFilterBar {
                filterBar
                Divider()
            }
            if focusedRootID != nil, viewMode == .map {
                focusBar
                Divider()
            }
            contentStack
                // Floats over the canvas rather than taking a column of its
                // own: an `.inspector` narrows the canvas, which re-lays out
                // and visibly shifts the whole map just to read one topic.
                .overlay(alignment: .trailing) {
                    if showNotes, selection != nil {
                        floatingInspector
                    }
                }
                .animation(.snappy(duration: 0.22), value: showNotes)
                .overlay(alignment: .topTrailing) {
                    if showFindBar {
                        findBar
                            .padding(.top, 12)
                            // Stays over the canvas rather than on top of the
                            // panel that now owns the right edge.
                            .padding(.trailing, showNotes ? 316 : 16)
                    }
                }
        }
        .animation(.snappy(duration: 0.2), value: showFilterBar)
        .animation(.snappy(duration: 0.2), value: focusedRootID)
        .background { findShortcuts }
        .focusedSceneValue(\.mapCommands, menuCommands)
        .onChange(of: searchQuery) { _, _ in currentMatchIndex = 0; refreshSearch() }
        .onChange(of: activeTags) { _, _ in refreshSearch() }
        .onChange(of: document) { _, _ in
            if showFindBar { refreshSearch() }
            // Closing can retire a tag's last open topic; a chip that can
            // only match hidden things must leave the filter.
            // Re-adopt the spelling too: closing the topic that first
            // spelled a tag can hand the canonical form to a variant, and a
            // chip that still has matches must not vanish over letter case.
            let live = allTags
            let surviving = Set(activeTags.compactMap {
                Tags.contains(live, $0) ? Tags.canonical($0, among: live) : nil
            })
            if surviving != activeTags { activeTags = surviving }
            // An undo (or a delete from the outline) can take the focused topic
            // or a selected one out from under us; never keep pointing at a
            // node the document no longer has.
            if let focusedRootID,
               document.root.node(with: focusedRootID) == nil || effectivelyClosed(focusedRootID) {
                setFocus(nil)
            }
            if !selectedIDs.isEmpty {
                let live = document.root.subtreeIDs
                let surviving = selectedIDs.intersection(live)
                if surviving != selectedIDs { selectedIDs = surviving.count > 1 ? surviving : [] }
            }
        }
        .onChange(of: viewMode) { _, _ in if showFindBar { refreshSearch() } }
        .onChange(of: showNotes) { _, open in
            if !open {
                notesFocused = false
                focus = .canvas
            }
        }
        // The inspector belongs to a topic: deselecting closes it rather than
        // leaving an empty panel taking up a third of the window.
        .onChange(of: selection) { _, id in
            if id == nil { showNotes = false }
            titleDraft = id.flatMap { document.root.node(with: $0)?.text } ?? ""
        }
        // A rename on the canvas, or an undo, must show up in the panel — but
        // not while the field is being typed in, or it would fight the typist.
        .onChange(of: selectedNodeText) { _, text in
            if inspectorField != .title { titleDraft = text }
        }
        // Clicking away from the field is a commit, same as Enter.
        .onChange(of: inspectorField) { old, new in
            if old == .title, new != .title { commitTitleDraft() }
        }
        .onChange(of: showHelp) { _, open in if !open { focus = .canvas } }
        .onChange(of: datePickerNodeID) { _, value in if value == nil { focus = .canvas } }
    }

    // MARK: Background & edges

    private var background: some View {
        DotGridBackground()
            .contentShape(Rectangle())
            .onTapGesture {
                commitEditing()
                selection = nil
                selectedIDs = []
                focus = .canvas
            }
            .gesture(
                // Distance matches the default a plain DragGesture uses: the
                // background also carries the click-to-deselect tap, and a
                // twitchy threshold turns those clicks into one-pixel pans.
                DragGesture(minimumDistance: 10, coordinateSpace: .named("canvas"))
                    .updating($dragPan) { value, state, _ in
                        // Shift turns the empty-canvas drag into a marquee, so
                        // the pan has to stand down for the duration.
                        guard !marqueeing else { state = .zero; return }
                        // Clamp live so dragging stops at the boundary
                        // instead of overshooting and snapping back.
                        let target = CGSize(width: pan.width + value.translation.width,
                                            height: pan.height + value.translation.height)
                        let clamped = clampPan(target, viewSize: canvasSize)
                        state = CGSize(width: clamped.width - pan.width,
                                       height: clamped.height - pan.height)
                    }
                    .onChanged { value in
                        guard marqueeing else { return }
                        if marquee == nil { marqueeBase = selectedIDs }
                        marquee = CGRect(corner: value.startLocation, opposite: value.location)
                        applyMarquee()
                    }
                    .onEnded { value in
                        if marquee != nil {
                            applyMarquee()
                            marquee = nil
                            marqueeBase = []
                            return
                        }
                        let target = CGSize(width: pan.width + value.translation.width,
                                            height: pan.height + value.translation.height)
                        pan = clampPan(target, viewSize: canvasSize)
                    }
            )
    }

    /// A marquee is in progress, or would be if the drag continued: shift is
    /// held now, or the rubber band is already up.
    private var marqueeing: Bool {
        marquee != nil || NSEvent.modifierFlags.contains(.shift)
    }

    private func applyMarquee() {
        guard let marquee, canvasSize != .zero else { return }
        let topLeft = world(CGPoint(x: marquee.minX, y: marquee.minY), in: canvasSize)
        let bottomRight = world(CGPoint(x: marquee.maxX, y: marquee.maxY), in: canvasSize)
        let worldRect = CGRect(corner: topLeft, opposite: bottomRight)
        var hits = MapSelection.inside(worldRect, of: layout)
        hits.remove(layoutRootID)
        let combined = marqueeBase.union(hits)
        selectedIDs = combined.count > 1 ? combined : []
        if let first = combined.first, selection == nil || !combined.contains(selection!) {
            selection = first
        }
    }

    /// Live marquee rectangle.
    @ViewBuilder
    private var marqueeOverlay: some View {
        if let marquee {
            Rectangle()
                .fill(Palette.selection.opacity(0.10))
                .overlay(Rectangle().stroke(Palette.selection.opacity(0.8), lineWidth: 1))
                .frame(width: marquee.width, height: marquee.height)
                .position(x: marquee.midX, y: marquee.midY)
                .allowsHitTesting(false)
        }
    }

    private func edgesCanvas(_ layout: MapLayout, viewSize: CGSize) -> some View {
        Canvas { ctx, size in
            for edge in layout.edges {
                let childDimmed = layout.nodes[edge.id].map(dimmed) ?? false
                let from = screen(edge.from, in: size)
                let to = screen(edge.to, in: size)
                var path = Path()
                path.move(to: from)
                let dx = (to.x - from.x) * 0.5
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: from.x + dx, y: from.y),
                    control2: CGPoint(x: to.x - dx, y: to.y)
                )
                // Trunk edges (root → level 1) draw heavier than deep ones.
                let baseWidth: CGFloat = edge.level == 1 ? 3 : 2.2
                ctx.stroke(
                    path,
                    with: .color(edge.color.opacity(childDimmed ? 0.2 : 0.85)),
                    style: StrokeStyle(lineWidth: max(1.2, baseWidth * zoom), lineCap: .round)
                )
            }
            drawCrossLinks(layout, in: &ctx, size: size)
        }
        .allowsHitTesting(false)
    }

    /// Cross-links and the ⌥-drag rubber band, drawn over the tree edges so a
    /// relation between two topics on the same branch is not hidden by the
    /// edge that already joins them.
    ///
    /// A link is drawn only when both of its endpoints are laid out — a
    /// connector into a collapsed, closed, or out-of-focus branch has nowhere
    /// to land, and stubbing it out would be worse than leaving it off.
    private func drawCrossLinks(_ layout: MapLayout, in ctx: inout GraphicsContext, size: CGSize) {
        let dash = StrokeStyle(lineWidth: max(1, 1.8 * zoom), lineCap: .round,
                               dash: [6 * zoom, 5 * zoom])
        for link in document.links {
            guard let a = layout.nodes[link.from], let b = layout.nodes[link.to] else { continue }
            let from = screen(LinkCurve.anchor(on: a.rect,
                                               toward: CGPoint(x: b.rect.midX, y: b.rect.midY)),
                              in: size)
            let to = screen(LinkCurve.anchor(on: b.rect,
                                             toward: CGPoint(x: a.rect.midX, y: a.rect.midY)),
                            in: size)
            let control = LinkCurve.control(from: from, to: to)
            var path = Path()
            path.move(to: from)
            path.addCurve(to: to, control1: control, control2: control)
            let selected = editingLinkID == link.id
            let color = Palette.crossLink.opacity(selected ? 1 : 0.75)
            ctx.stroke(path, with: .color(color), style: dash)
            ctx.fill(arrowHead(at: to, from: control), with: .color(color))
            guard !link.label.isEmpty, zoom >= 0.5 else { continue }
            let mid = LinkCurve.midpoint(from: from, to: to, control: control)
            let text = ctx.resolve(Text(link.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.crossLink))
            let textSize = text.measure(in: CGSize(width: 200, height: 40))
            let pill = CGRect(x: mid.x - textSize.width / 2 - 6, y: mid.y - textSize.height / 2 - 3,
                              width: textSize.width + 12, height: textSize.height + 6)
            let capsule = Path(roundedRect: pill, cornerRadius: pill.height / 2)
            ctx.fill(capsule, with: .color(Color(nsColor: .windowBackgroundColor)))
            ctx.stroke(capsule, with: .color(Palette.crossLink.opacity(0.6)), lineWidth: 1)
            ctx.draw(text, at: mid, anchor: .center)
        }
        // Rubber band while ⌥-dragging a new connection.
        if let linkDragFrom, let point = linkDragPoint,
           let a = layout.nodes[linkDragFrom] {
            let target = linkDragTarget.flatMap { layout.nodes[$0] }
            let end = target.map { screen(LinkCurve.anchor(on: $0.rect,
                                                           toward: CGPoint(x: a.rect.midX,
                                                                           y: a.rect.midY)),
                                          in: size) } ?? point
            let start = screen(LinkCurve.anchor(on: a.rect, toward: world(end, in: size)), in: size)
            let control = LinkCurve.control(from: start, to: end)
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: control, control2: control)
            ctx.stroke(path, with: .color(Palette.crossLink.opacity(target == nil ? 0.5 : 0.95)),
                       style: dash)
            ctx.fill(arrowHead(at: end, from: control),
                     with: .color(Palette.crossLink.opacity(target == nil ? 0.5 : 0.95)))
        }
    }

    private func arrowHead(at tip: CGPoint, from origin: CGPoint) -> Path {
        let dx = tip.x - origin.x, dy = tip.y - origin.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let size = 8 * min(max(zoom, 0.6), 1.4)
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * size * 0.45, y: base.y + ux * size * 0.45))
        path.addLine(to: CGPoint(x: base.x + uy * size * 0.45, y: base.y - ux * size * 0.45))
        path.closeSubpath()
        return path
    }

    // MARK: Node view

    private func nodeView(id: UUID, geom: NodeGeom, viewSize: CGSize) -> some View {
        NodeView(
            geom: geom,
            zoom: zoom,
            isSelected: selection == id,
            isSecondarySelected: selection != id && selectedIDs.contains(id),
            linkRole: linkDragFrom == id ? .source : (linkDragTarget == id ? .target : .none),
            isHovered: hoveredID == id,
            anyDragActive: dragNodeID != nil,
            dropMode: dropIndicator.flatMap { $0.id == id ? $0.mode : nil },
            editingDraft: editingID == id ? draft : nil,
            selectDraftOnFocus: editingSelectsAll,
            datePickerShown: datePickerNodeID == id,
            closedPopoverShown: closedPopoverNodeID == id,
            searchMatch: searchState(id),
            draft: $draft,
            actions: nodeActions(for: id)
        )
        .equatable()
        .onHover { hovering in
            guard dragNodeID == nil else { return }
            if hovering {
                hoveredID = id
            } else {
                scheduleHoverClear(for: id)
            }
        }
        .opacity(nodeOpacity(id, geom: geom))
        // Position — and therefore the sibling reflow — stays instant. Clearing
        // the transaction here means the collapse toggle's `withAnimation` never
        // reaches `.position`, so surviving nodes snap to their new slots in the
        // same frame the edge Canvas does. Only the enter/exit bloom (below,
        // outside this transaction) animates. This is what keeps gliding nodes
        // from tearing away from their snapped edges.
        .position(screen(CGPoint(x: geom.rect.midX, y: geom.rect.midY), in: viewSize))
        .transaction { $0.animation = nil }
        .offset(dragNodeID == id ? dragOffset : .zero)
        .zIndex(dragNodeID == id ? 10 : 0)
        // Children bloom out of the parent on expand and fold into it on
        // collapse. Anchored on the parent-facing edge; runs only inside the
        // toggle's `withAnimation`, so pan/zoom culling still pops instantly.
        .transition(collapseBloom(for: geom))
        // Deliberately a single TapGesture that counts its own clicks rather
        // than a `TapGesture(count: 2)` alongside it: SwiftUI holds a single
        // tap back until the double-click window expires, which put a visible
        // delay on every selection. Selecting is the common act and has to be
        // instant, so it fires on the first click and the second click adds
        // the rename on top of it.
        .gesture(TapGesture().onEnded {
            // Read the live modifiers rather than attaching separate
            // `.modifiers(...)` gestures: two tap gestures on the same view
            // race, and losing that race silently drops the plain click —
            // which is the one that has to be instant.
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.shift) || modifiers.contains(.command) {
                lastClickID = nil
                toggleInSelection(id)
                return
            }
            let now = Date()
            let isSecondClick = lastClickID == id
                && now.timeIntervalSince(lastClickAt) < NSEvent.doubleClickInterval
            lastClickID = id
            lastClickAt = now
            if isSecondClick {
                lastClickID = nil
                beginRename(id)
                return
            }
            if editingID != id { commitEditing() }
            selection = id
            selectedIDs = []
            if editingID == nil { focus = .canvas }
            showNotes = true
        })
        .simultaneousGesture(nodeDragGesture(id: id, viewSize: viewSize))
        .contextMenu {
            // Right-click does not select on its own, so every item claims
            // the topic first.
            Button("Show Details & Notes") {
                commitEditing()
                selection = id
                showNotes = true
            }
            Button("Edit Topic") {
                beginRename(id)
            }
            Button("Add Child Topic") {
                commitEditing()
                selection = id
                addChildToSelection()
            }
            Button("Add Sibling Topic") {
                commitEditing()
                selection = id
                addSiblingToSelection()
            }
            .disabled(id == document.root.id)
            Menu("Color") {
                Button {
                    selection = id
                    setNodeColor(nil)
                } label: {
                    Label("Automatic", systemImage: "sparkles")
                }
                ForEach(Array(Self.colorNames.enumerated()), id: \.offset) { index, name in
                    Button(name) {
                        selection = id
                        setNodeColor(index)
                    }
                }
            }
            Divider()
            Button {
                commitEditing()
                selection = id
                selectedIDs = []
                setFocus(id)
            } label: {
                Label("Focus on This Topic", systemImage: "scope")
            }
            .disabled(id == layoutRootID
                      || document.root.node(with: id)?.children.isEmpty != false)
            Button {
                commitEditing()
                selection = id
                copySelection(cut: false)
            } label: {
                Label("Copy Topic", systemImage: "doc.on.doc")
            }
            Button {
                commitEditing()
                selection = id
                pasteIntoSelection()
            } label: {
                Label("Paste Into Topic", systemImage: "doc.on.clipboard")
            }
            Divider()
            Button {
                commitEditing()
                selection = id
                close(id)
            } label: {
                Label("Close Topic", systemImage: "checkmark.circle")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(id == document.root.id)
            Button("Delete Topic", role: .destructive) {
                commitEditing()
                selection = id
                deleteSelection()
            }
            .disabled(id == document.root.id)
        }
    }

    /// Enter/exit transition for a node when its branch folds. Opacity plus a
    /// small scale anchored on the edge that faces the parent (leading for a
    /// right-side branch, trailing for a left-side one), so the subtree reads
    /// as growing out of — or shrinking into — its parent rather than the
    /// node's own center.
    private func collapseBloom(for geom: NodeGeom) -> AnyTransition {
        let anchor: UnitPoint = geom.side == .right ? .leading : .trailing
        return .opacity.combined(with: .scale(scale: 0.86, anchor: anchor))
    }

    /// Closures handed to a NodeView. They read view state at call time, so
    /// NodeView can safely skip re-rendering while holding older copies.
    private func nodeActions(for id: UUID) -> NodeView.Actions {
        NodeView.Actions(
            // Deliberately unanimated: the fold should land in the same frame
            // as the click, not settle into place over the next several.
                toggleCollapse: {
                // A short easeOut so the revealed/removed subtree blooms out of
                // (or folds into) the parent instead of snapping. Reveal runs a
                // hair slower than collapse — you register new content, you
                // don't admire content leaving. Both stay well under 200ms so
                // there is nothing to wait for. Only the entering/exiting nodes
                // animate (see `collapseBloom`); positions stay instant, so the
                // reflow and the edge Canvas never drift apart.
                let expanding = document.root.node(with: id)?.isCollapsed ?? false
                anchorSide(on: id) { $0.isCollapsed.toggle() }
                withAnimation(.easeOut(duration: expanding ? 0.16 : 0.12)) {
                    apply { $0.root.update(id) { $0.isCollapsed.toggle() } }
                }
            },
            prepareCollapseToggle: { prepareCollapseToggle(for: id) },
            addChild: {
                selection = id
                addChildToSelection()
            },
            expandCollapsedDue: { info in
                apply { $0.root.update(id) { $0.isCollapsed = false } }
                selection = info.nodeID
            },
            openLink: { openLink($0) },
            showNotes: {
                // Clicking the badge of the topic the panel already shows
                // closes it; on any other topic it retargets the panel.
                if showNotes, selection == id {
                    showNotes = false
                } else {
                    selection = id
                    showNotes = true
                }
            },
            setDatePickerShown: { datePickerNodeID = $0 ? id : nil },
            // Through apply(), like every other mutation: a direct binding
            // write updated the node badge but left the agenda's derived
            // cache stale, so the sidebar kept showing the old date.
            setDueDate: { new in apply { $0.root.update(id) { $0.dueDate = new } } },
            removeDueDate: {
                apply { $0.root.update(id) { $0.dueDate = nil } }
                datePickerNodeID = nil
            },
            affordanceHoverChanged: { hovering in
                affordanceHovered = hovering
                if hovering {
                    hoveredID = id
                } else {
                    scheduleHoverClear(for: id)
                }
            },
            commit: { commit(text: $0, to: id) },
            commitAndAddChild: { text in
                commit(text: text, to: id)
                addChildToSelection()
            },
            cancelEditing: { if editingID == id { cancelEditing() } },
            closedChildren: {
                guard let node = document.root.node(with: id) else { return [] }
                return node.closedChildren
                    .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
                    .map { child in
                        var subtopics = -1
                        func count(_ n: MindNode) { subtopics += 1; n.children.forEach(count) }
                        count(child)
                        return NodeView.ClosedChildInfo(
                            id: child.id,
                            text: child.text.isEmpty ? "Topic" : child.text,
                            closedAt: child.closedAt,
                            subtopicCount: subtopics
                        )
                    }
            },
            reopenClosedChild: { childID in
                reopen(childID)
                // Popover closes with its last row.
                if document.root.node(with: id)?.closedChildren.count == 1 {
                    closedPopoverNodeID = nil
                }
            },
            reopenAllClosed: {
                closedPopoverNodeID = nil
                guard let node = document.root.node(with: id) else { return }
                let ids = node.closedChildren.map(\.id)
                apply { doc in
                    for childID in ids {
                        doc.root.update(childID) { $0.closedAt = nil }
                    }
                }
            },
            revealClosedInOutline: { childID in
                closedPopoverNodeID = nil
                showClosed = true
                viewMode = .outline
                if let childID { selection = childID }
            },
            setClosedPopoverShown: { closedPopoverNodeID = $0 ? id : nil }
        )
    }

    // MARK: Toolbar & hints

    /// Slimmed header (design review, was 11 chips): one labeled primary
    /// action, everything else a monochrome icon-only control, and the
    /// canvas-view controls (zoom, fit) moved onto the canvas. Actions that
    /// merely duplicate a keystroke or a right-click item are gone from the
    /// bar entirely — the discoverability lives in the context menu and the
    /// shortcuts sheet, not in a wall of buttons.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading: the one persistent "how many things need me" signal.
        ToolbarItem(placement: .navigation) {
            dueDatesButton
        }
        // Center: which view of the document you are in.
        ToolbarItem(placement: .principal) {
            viewModeSwitcher
        }
        // Trailing: the primary create action, then view toggles, then a
        // catch-all overflow, then the inspector.
        ToolbarItemGroup(placement: .primaryAction) {
            addTopicButton
            searchButton
            filterButton
            overflowMenu
            headerIconButton("sidebar.right", label: "",
                             help: "Show details and notes for the selected topic (⌘I)",
                             active: showNotes) { showNotes.toggle() }
                // Nothing to inspect with no selection, so the toggle can't
                // conjure an empty panel.
                .disabled(selection == nil)
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityLabel("Details and notes")
        }
    }

    private func balanceBranches() {
        apply { doc in
            for id in doc.root.children.map(\.id) {
                doc.root.update(id) { $0.side = nil }
            }
        }
    }

    /// The deliberate "put it back the way it was" gesture, and the only thing
    /// that re-centers the map wholesale.
    ///
    /// Folding pins what you touched, which over a long session leaves each
    /// side sitting a little off-center. That drift is cosmetic — it never
    /// breaks the map — so it is never corrected automatically; correcting it
    /// behind the user's back would be the very jump this whole change removes.
    /// One command, animated as a single deliberate motion so the eye can
    /// follow nodes to their new homes, and undoable like any other edit.
    private func tidyMap() {
        withAnimation(.snappy(duration: 0.35)) {
            sideOffsets = .zero
            balanceBranches()
        }
        fitToWindow()
    }

    // MARK: Focus mode

    /// Path from the real root down to the focused topic, for the breadcrumb.
    private var focusPath: [MindNode] {
        guard let focusedRootID else { return [] }
        return document.root.path(to: focusedRootID) ?? []
    }

    /// Drills into a topic: it becomes the center and its subtree becomes the
    /// whole map. A childless topic is not worth focusing — there would be
    /// nothing to see — so the command is a no-op there.
    private func focusOnSelection() {
        guard let selection, selection != layoutRootID,
              document.root.node(with: selection)?.children.isEmpty == false else { return }
        setFocus(selection)
    }

    /// Climbs one level out, and all the way out when the focused topic is a
    /// child of the real root.
    private func popFocus() {
        guard let focusedRootID else { return }
        let parent = document.root.parentID(of: focusedRootID)
        setFocus(parent == document.root.id ? nil : parent)
    }

    private func setFocus(_ id: UUID?) {
        commitEditing()
        focusedRootID = id
        sideOffsets = .zero
        selectedIDs = []
        selection = id ?? document.root.id
        // Fit against a layout built here rather than the view's cached one:
        // the state write above may not be visible to `layout` this cycle.
        let root = id.flatMap { document.root.node(with: $0) } ?? document.root
        fit(to: MapLayout(root: root).bounds)
    }

    /// Breadcrumb strip shown while focused. Every segment is a jump — the
    /// path is the only way back out, so it has to be more than decoration.
    private var focusBar: some View {
        let path = focusPath
        return HStack(spacing: 4) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Chrome.activeIcon)
            Button("All topics") { setFocus(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Chrome.inactiveText)
            ForEach(Array(path.dropFirst().enumerated()), id: \.element.id) { index, node in
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                let last = index == path.count - 2
                Button(node.text.isEmpty ? "Topic" : node.text) {
                    if !last { setFocus(node.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: last ? .bold : .medium))
                .foregroundStyle(last ? Chrome.text : Chrome.inactiveText)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                setFocus(nil)
            } label: {
                HStack(spacing: 4) {
                    Text("Exit focus").font(.system(size: 11.5, weight: .semibold))
                    Text("\u{2318}\u{2191}").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Chrome.activeIcon)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Chrome.activeTint))
            }
            .buttonStyle(.chip)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.toolBg.opacity(0.7))
    }

    /// Frames the whole map. This is what makes pinning safe to be aggressive
    /// about: however far the view has wandered, one key brings everything back
    /// on screen.
    private func fitToWindow() {
        fit(to: layout.bounds)
    }

    private func fit(to bounds: CGRect) {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            withAnimation(.snappy) { pan = .zero; zoom = 1 }
            return
        }
        let padding: CGFloat = 48
        let fitted = min(
            (canvasSize.width - padding * 2) / bounds.width,
            (canvasSize.height - padding * 2) / bounds.height
        )
        // Never zoom past 1:1 — a small map should sit at natural size in the
        // middle of the window, not balloon to fill it.
        let target = min(max(fitted, 0.2), 1)
        withAnimation(.snappy) {
            zoom = target
            pan = CGSize(width: -bounds.midX * target, height: -bounds.midY * target)
        }
    }

    /// Sets `isCollapsed` on every branch. On collapse-all the root is left
    /// open, otherwise the whole map would fold into a single dot; the result
    /// is a tidy overview of just the top-level branches.
    private func setAllCollapsed(_ collapsed: Bool) {
        // No single node was toggled, so there is nothing to pin — this is a
        // wholesale reshape and reads better centered.
        sideOffsets = .zero
        let rootID = layoutRootID
        apply { doc in
            func walk(_ node: inout MindNode) {
                if !node.children.isEmpty, !(collapsed && node.id == rootID) {
                    node.isCollapsed = collapsed
                }
                for i in node.children.indices { walk(&node.children[i]) }
            }
            walk(&doc.root)
        }
    }

    private func nodeMatchesFilter(_ node: MindNode) -> Bool {
        !activeTags.isEmpty && Tags.matches(node.tags, anyOf: activeTagKeys)
    }

    /// Filter-aware expand: opens exactly the branches that lead to a matching
    /// topic and collapses the ones that don't. This is what "expand" should
    /// mean while a filter is on — it brings the matches into view in context
    /// instead of flooding the canvas with dimmed, irrelevant topics.
    private func expandToMatches() {
        apply { doc in
            @discardableResult
            func walk(_ node: inout MindNode) -> Bool {
                var subtreeHasMatch = nodeMatchesFilter(node)
                for i in node.children.indices {
                    if walk(&node.children[i]) { subtreeHasMatch = true }
                }
                if !node.children.isEmpty {
                    node.isCollapsed = !subtreeHasMatch
                }
                return subtreeHasMatch
            }
            walk(&doc.root)
        }
    }

    /// Catch-all for the low-frequency, one-shot canvas actions that do not
    /// earn a permanent button. Icon-only; grows as needed.
    private var overflowMenu: some View {
        Menu {
            Section("Closed") {
                Toggle(isOn: $showClosed) {
                    Label(closedCount > 0 ? "Show closed topics (\(closedCount))" : "Show closed topics",
                          systemImage: "checkmark.circle")
                }
            }
            Section("Branches") {
                if activeTags.isEmpty {
                    Button {
                        setAllCollapsed(false)
                    } label: {
                        Label("Expand all", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                } else {
                    // A filter is active: the primary expand keeps the filter
                    // meaningful (matches in context), with a literal
                    // everything-open escape hatch below it.
                    Button {
                        expandToMatches()
                    } label: {
                        Label("Expand to filter matches", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Button {
                        setAllCollapsed(false)
                    } label: {
                        Label("Expand everything", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Button {
                    setAllCollapsed(true)
                } label: {
                    Label("Collapse all", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
            Section("Focus") {
                Button {
                    focusOnSelection()
                } label: {
                    Label("Focus on topic", systemImage: "scope")
                }
                .disabled(selection == nil || selection == layoutRootID
                          || document.root.node(with: selection ?? UUID())?.children.isEmpty != false)
                Button {
                    popFocus()
                } label: {
                    Label("Exit focus", systemImage: "arrow.up.left")
                }
                .disabled(focusedRootID == nil)
            }
            Section {
                Button {
                    tidyMap()
                } label: {
                    Label("Tidy map", systemImage: "arrow.left.arrow.right")
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                Button {
                    fitToWindow()
                } label: {
                    Label("Fit map to window", systemImage: "scope")
                }
                .keyboardShortcut("9", modifiers: .command)
            }
            Section("Export") {
                ForEach(MapExport.Format.allCases) { format in
                    Button {
                        runExport(format)
                    } label: {
                        Label(format.title, systemImage: format.systemImage)
                    }
                }
            }
        } label: {
            headerChipLabel("ellipsis", label: "", active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    // MARK: Design-spec header controls

    private var viewModeSwitcher: some View {
        HStack(spacing: 0) {
            modeSegment("Map", icon: "map", mode: .map)
            modeSegment("Outline", icon: "list.bullet.indent", mode: .outline)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Chrome.segmentBg))
    }

    private func modeSegment(_ title: String, icon: String, mode: ViewMode) -> some View {
        let active = viewMode == mode
        return Button {
            viewMode = mode
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(active ? Chrome.text : Chrome.inactiveText)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Chrome.segmentActive)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.chip)
        .help(mode == .map ? "Mind map" : "Outline")
    }

    /// The one tinted, labeled action in the header. A split button: the body
    /// adds a child (the common case, = Tab); the chevron holds the sibling
    /// variant so it does not need its own permanent chip.
    private var addTopicButton: some View {
        Menu {
            Button {
                addChildToSelection()
            } label: {
                Label("Add child topic", systemImage: "arrow.turn.down.right")
            }
            Button {
                addSiblingToSelection()
            } label: {
                Label("Add sibling topic", systemImage: "arrow.turn.down.right")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                Text("Add topic").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Palette.selection)
                    .shadow(color: Palette.selection.opacity(0.5), radius: 3, y: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        } primaryAction: {
            addChildToSelection()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a child topic (Tab) — ▾ for sibling")
    }

    /// Toolbar button. `label` is not optional by accident: an icon alone is
    /// not guessable for anything but the most universal glyphs, so every
    /// action in the header carries its name.
    private func headerIconButton(
        _ systemName: String, label: String, help: String, active: Bool = false,
        filled: Bool = false, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            headerChipLabel(systemName, label: label, active: active)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(active ? Chrome.activeTint : (filled ? Chrome.toolBg : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.chip)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }

    /// Shared icon + caption body for header chips (buttons and menus). An
    /// empty `label` yields an icon-only control at a square footprint — the
    /// default now that the header is mostly monochrome glyphs.
    private func headerChipLabel(
        _ systemName: String, label: String, active: Bool, tint: Color? = nil
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName).font(.system(size: 14, weight: .semibold))
            if !label.isEmpty {
                Text(label).font(.system(size: 12.5, weight: .semibold))
            }
        }
        .foregroundStyle(tint ?? (active ? Chrome.activeIcon : Chrome.toolIcon))
        .padding(.horizontal, label.isEmpty ? 0 : 10)
        .frame(width: label.isEmpty ? 30 : nil, height: 30)
    }

    /// Toggles the tag chip bar. Keeps the count badge so "how many filters are
    /// on" reads at a glance even with the bar collapsed.
    private var filterButton: some View {
        let lit = showFilterBar || !activeTags.isEmpty
        return Button {
            withAnimation(.snappy(duration: 0.2)) { showFilterBar.toggle() }
        } label: {
            headerChipLabel("line.3.horizontal.decrease.circle", label: "", active: lit)
                .overlay(alignment: .topTrailing) {
                    if !activeTags.isEmpty {
                        countBadge(activeTags.count, color: Palette.selection)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(lit ? Chrome.activeTint : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.chip)
        .help(activeTags.isEmpty ? "Filter topics by tag"
              : "Filtering by \(activeTags.count) tag\(activeTags.count == 1 ? "" : "s")")
    }

    /// Opens the find bar (also ⌘F).
    private var searchButton: some View {
        Button {
            openFind()
        } label: {
            headerChipLabel("magnifyingglass", label: "", active: showFindBar)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(showFindBar ? Chrome.activeTint : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.chip)
        .keyboardShortcut("f", modifiers: .command)
        .help("Find in map (⌘F)")
    }

    /// Slide-down bar of selectable tag chips, matching the chips shown on
    /// topics. Selected chips pin to the left so an active filter never scrolls
    /// out of sight; a chip-search field appears once the row gets long.
    private var filterBar: some View {
        let tags = allTags
        let ordered = tags.sorted { a, b in
            let sa = activeTags.contains(a), sb = activeTags.contains(b)
            if sa != sb { return sa }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        let narrow = tagChipQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = narrow.isEmpty ? ordered
            : ordered.filter { $0.lowercased().contains(narrow) }
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Chrome.toolIcon)
            if tags.isEmpty {
                Text("No tags yet \u{2014} add tags to topics in the details panel.")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.inactiveText)
                Spacer()
            } else {
                if tags.count > 12 {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        TextField("Filter tags", text: $tagChipQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 84)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    Divider().frame(height: 18)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shown, id: \.self) { tag in
                            TagChip(text: tag, color: .secondary, style: .filter,
                                    isSelected: activeTags.contains(tag),
                                    onTap: {
                                        if activeTags.contains(tag) { activeTags.remove(tag) }
                                        else { activeTags.insert(tag) }
                                    })
                        }
                    }
                    .padding(.vertical, 1)
                }
                if !activeTags.isEmpty {
                    Divider().frame(height: 18)
                    Button("Clear") { activeTags = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.selection)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.toolBg.opacity(0.6))
    }

    // MARK: Find bar

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The find is affecting the views (bar open + a non-empty query).
    private var searchActive: Bool { showFindBar && !trimmedQuery.isEmpty }

    private var searchMatchSet: Set<UUID> { Set(searchMatches) }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Find in map", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 176)
                .focused($findFocused)
                .onSubmit { stepMatch(1) }
            if !trimmedQuery.isEmpty {
                Text(matchCountLabel)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(searchMatches.isEmpty ? Color.secondary : Chrome.toolIcon)
                // Every hit is closed: the map can't show them, the outline can.
                if searchMatches.isEmpty, closedSearchMatches > 0 {
                    Button("\(closedSearchMatches) closed") {
                        showClosed = true
                        viewMode = .outline
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.selection)
                    .help("Show the closed topics that match in the outline")
                }
                HStack(spacing: 1) {
                    findStepButton("chevron.up", help: "Previous match (\u{21E7}\u{2318}G)") { stepMatch(-1) }
                    findStepButton("chevron.down", help: "Next match (\u{2318}G)") { stepMatch(1) }
                }
                .disabled(searchMatches.isEmpty)
                .opacity(searchMatches.isEmpty ? 0.4 : 1)
            }
            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.chip)
            .help("Close find (Esc)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .onExitCommand { closeFind() }
    }

    private func findStepButton(_ systemName: String, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Chrome.toolIcon)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.chip)
        .help(help)
    }

    private var matchCountLabel: String {
        guard !searchMatches.isEmpty else { return "No results" }
        let scope = activeTags.isEmpty ? "" : " in filter"
        return "\(currentMatchIndex + 1)/\(searchMatches.count)\(scope)"
    }

    /// Hidden controls that carry the find/next/previous shortcuts so they fire
    /// even while the find field (or a node editor) holds focus.
    private var findShortcuts: some View {
        ZStack {
            Button("") { showFindBar ? stepMatch(1) : openFind() }
                .keyboardShortcut("g", modifiers: .command)
            Button("") { stepMatch(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("") { toggleClosedSelection() }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The commands the real menu bar drives. See `MapCommandActions`.
    private var menuCommands: MapCommandActions {
        MapCommandActions(
            copy: { copySelection(cut: false) },
            cut: { copySelection(cut: true) },
            paste: { pasteIntoSelection() },
            delete: { deleteTargets() },
            selectAll: { selectAllTopics() },
            focusIn: { focusOnSelection() },
            focusOut: { popFocus() },
            export: { runExport($0) },
            canFocusIn: canFocusIn,
            canFocusOut: focusedRootID != nil
        )
    }

    private var canFocusIn: Bool {
        guard let selection, selection != layoutRootID else { return false }
        return document.root.node(with: selection)?.children.isEmpty == false
    }

    /// ⌘A over the canvas selects every topic the map is currently showing —
    /// not the whole document, which would include things you cannot see.
    private func selectAllTopics() {
        guard canvasOwnsKeyboard else {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            return
        }
        let ids = Set(layout.order).subtracting([layoutRootID])
        guard !ids.isEmpty else { return }
        selectedIDs = ids
        if let current = selection, ids.contains(current) { return }
        selection = ids.first
    }

    private func openFind() {
        showFindBar = true
        refreshSearch()
        findFocused = true
    }

    private func closeFind() {
        showFindBar = false
        findFocused = false
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = 0
        focus = .canvas
    }

    /// Recomputes the ordered match list for the current query ∩ tag filter.
    /// Matches are collected in document order so stepping is spatially sane,
    /// and include nodes inside collapsed branches (stepping reveals them).
    private func refreshSearch() {
        guard showFindBar, !trimmedQuery.isEmpty else {
            searchMatches = []
            closedSearchMatches = 0
            return
        }
        let q = NodeSearch.fold(trimmedQuery)
        let keys = activeTagKeys
        var result: [UUID] = []
        var closedHits = 0
        func walk(_ node: MindNode, closed: Bool) {
            let tagOK = activeTags.isEmpty || Tags.matches(node.tags, anyOf: keys)
            if tagOK, NodeSearch.match(node, foldedQuery: q) != nil {
                if closed { closedHits += 1 } else { result.append(node.id) }
            }
            node.children.forEach { walk($0, closed: closed || $0.isClosed) }
        }
        walk(document.root, closed: false)
        searchMatches = result
        closedSearchMatches = closedHits
        if currentMatchIndex >= result.count { currentMatchIndex = 0 }
    }

    /// Steps to the next/previous match, wrapping, and reveals it in whichever
    /// view is showing.
    private func stepMatch(_ delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let n = searchMatches.count
        currentMatchIndex = ((currentMatchIndex + delta) % n + n) % n
        let id = searchMatches[currentMatchIndex]
        if viewMode == .map {
            revealNode(id, openNotes: false)
        } else {
            selection = id
        }
    }

    /// Little numeric badge used on the icon-only Filter and Dates controls.
    private func countBadge(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 3 : 0)
            .frame(minWidth: 14, minHeight: 14)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .offset(x: 5, y: -5)
    }

    /// Icon-only calendar; a red count badge appears only when something is
    /// overdue, so the control is quiet until it needs attention.
    private var dueDatesButton: some View {
        Button {
            showAgenda.toggle()
        } label: {
            headerChipLabel("calendar", label: "", active: showAgenda,
                            tint: overdueCount > 0 ? Chrome.redText : nil)
            .overlay(alignment: .topTrailing) {
                if overdueCount > 0 {
                    countBadge(overdueCount, color: Chrome.redText)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(overdueCount > 0 ? Chrome.redBg
                          : (showAgenda ? Chrome.activeTint : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.chip)
        .help(overdueCount > 0
              ? "\(overdueCount) topic\(overdueCount == 1 ? "" : "s") overdue"
              : "Topics with due dates")
    }

    private func zoomButton(_ systemName: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Chrome.toolIcon)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.chip)
        .help(help)
    }

    private var helpButton: some View {
        Button {
            showHelp.toggle()
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Chrome.inactiveText)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(.quaternary, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.chip)
        .help("Keyboard shortcuts")
        .popover(isPresented: $showHelp, arrowEdge: .top) {
            shortcutsPanel.padding(16)
        }
    }

    private static let shortcuts: [(key: String, action: String)] = [
        ("Tab", "Add a child topic"),
        ("Return", "Add a sibling · finish editing"),
        ("Space", "Edit the topic text"),
        ("⌘↩", "Close · reopen the topic"),
        ("Click text", "Edit the topic text"),
        ("Click topic", "Show details and notes"),
        ("Any letter", "Replace the topic text"),
        ("⌘I", "Show details and notes"),
        ("Right-click", "Topic actions menu"),
        ("⌫", "Delete the topic"),
        ("Esc", "Cancel editing · deselect"),
        ("Arrow keys", "Move between topics"),
        ("⌘↓ / ⌘↑", "Focus on a branch · step back out"),
        ("⌘C / ⌘X / ⌘V", "Copy · cut · paste topics as an outline"),
        ("⇧ / ⌘ click", "Add a topic to the selection"),
        ("⌘A", "Select every topic on the map"),
        ("⇧ drag canvas", "Marquee-select topics"),
        ("Drag canvas", "Pan the map"),
        ("Scroll wheel", "Zoom in and out"),
        ("Drag a topic", "Re-parent or reorder it"),
        ("⌥ drag a topic", "Connect it to another topic"),
        ("Drop past the root", "Move a branch left / right"),
    ]

    private var shortcutsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                ForEach(Self.shortcuts, id: \.key) { item in
                    GridRow {
                        // Keycap treatment: hairline border, heavier base edge.
                        Text(item.key)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(minWidth: 62)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.055))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.quaternary, lineWidth: 1)
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.14))
                                    .offset(y: 1)
                            )
                            .gridColumnAlignment(.trailing)
                        Text(item.action)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    // MARK: Color & notes

    /// Names for the palette, in `Palette.branches` order — used by the
    /// context-menu color submenu, where swatches can't render in color.
    private static let colorNames = ["Blue", "Coral", "Orange", "Green",
                                     "Purple", "Teal", "Pink", "Brown"]

    private func setNodeColor(_ index: Int?) {
        guard let selection else { return }
        apply { $0.root.update(selection) { $0.colorIndex = index } }
    }

    /// The agenda sidebar's twin on the right: same width, same flush
    /// full-height slab, same leading divider. The only difference is that it
    /// sits *over* the canvas instead of in the layout, so opening it never
    /// resizes the map.
    private var floatingInspector: some View {
        HStack(spacing: 0) {
            Divider()
            notesPanel
                .frame(width: Metrics.sidebarWidth)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .transition(.move(edge: .trailing))
    }

    @ViewBuilder
    private var notesPanel: some View {
        if let selection, let node = document.root.node(with: selection) {
            let nodeColor = layout.nodes[selection]?.color ?? Palette.root
            let parentName = document.root.parentID(of: selection)
                .flatMap { document.root.node(with: $0)?.text }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle().fill(nodeColor).frame(width: 9, height: 9)
                        Text("\((parentName?.isEmpty == false ? parentName! : "Mind Map").uppercased()) · TOPIC")
                            .font(.system(size: 10.5, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // Styled to read as the heading it replaced: plain field,
                    // same type, no box until you are in it.
                    TextField("Topic", text: $titleDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1...3)
                        // Without this the field is the panel's most
                        // compressible child: a squeezed column steals its
                        // second line and the topic name reads as truncated.
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($inspectorField, equals: .title)
                        .onSubmit { commitTitleDraft() }
                        .onExitCommand {
                            titleDraft = node.text
                            inspectorField = nil
                        }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 13)
                Divider()
                // The cards are taller than most windows, and a plain column
                // just clips: the overflow was unreachable and notes — the
                // part people actually write in — got squeezed to nothing.
                // So the cards scroll, and notes keeps a guaranteed share of
                // the panel no matter how many cards a topic has.
                GeometryReader { proxy in
                    // Notes earn their space: an empty, unfocused box collapses
                    // to a one-line invitation so the cards get the panel back.
                    // It used to reserve 45% either way, which pushed Tags and
                    // Close/Reopen off the bottom on an ordinary window.
                    let collapsed = node.notes.isEmpty && !notesFocused
                    let notesHeight = InspectorLayout.notesHeight(
                        panelHeight: proxy.size.height,
                        hasText: !node.notes.isEmpty,
                        isFocused: notesFocused
                    )
                    VStack(spacing: 0) {
                        ScrollView {
                            detailRows(id: selection, node: node)
                        }
                        .frame(maxHeight: .infinity)
                        Divider()
                        VStack(alignment: .leading, spacing: 0) {
                            sectionEyebrow("Notes")
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                            if collapsed {
                                Button {
                                    notesFocused = true
                                } label: {
                                    Text("Add notes…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Spacer(minLength: 0)
                            } else {
                                MarkdownNotesEditor(
                                    text: notesBinding(for: selection),
                                    isActive: $notesFocused
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(height: notesHeight)
                        .animation(.snappy(duration: 0.18), value: collapsed)
                    }
                }
            }
        } else {
            // The panel only exists for a selected topic, so this is reached
            // only for the frames while it slides shut after a deselect. An
            // empty placeholder there beats flashing an "unavailable" state.
            Color.clear
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }

    /// Inspector meta card chrome: white rounded card with hairline border.
    private func metaCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 11, content: content)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            )
    }

    private func iconTile(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.14)))
    }

    /// Delay hiding the hover affordances (the "+" and the details button) so
    /// the pointer can travel from the node to them without them vanishing
    /// mid-way.
    private func scheduleHoverClear(for id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if hoveredID == id, !affordanceHovered {
                hoveredID = nil
            }
        }
    }

    private func dimmed(_ geom: NodeGeom) -> Bool {
        !activeTags.isEmpty && !Tags.matches(geom.tags, anyOf: activeTagKeys)
    }

    /// Refreshes tree-derived values (tags, due items) — one walk per
    /// document change instead of one per body evaluation.
    private func refreshDerivedIfNeeded() {
        guard cache.derivedRoot != document.root else { return }
        var tagsSeen: [String] = []
        var items: [DueItem] = []
        var closedTotal = 0
        // Closed subtrees contribute nothing: their due dates leave the
        // agenda (closing an overdue topic must drop the red badge) and
        // their tags leave the filter bar. They are only counted.
        func walk(_ node: MindNode, level: Int, ancestors: [String]) {
            if node.isClosed {
                func count(_ n: MindNode) { closedTotal += 1; n.children.forEach(count) }
                count(node)
                return
            }
            tagsSeen.append(contentsOf: node.tags)
            let title = node.text.isEmpty ? "Topic" : node.text
            if let due = node.dueDate {
                items.append(DueItem(
                    id: node.id,
                    text: title,
                    due: due,
                    color: MapLayout.color(for: node, level: level),
                    parent: level >= 2 ? ancestors.last : nil,
                    path: (ancestors + [title]).joined(separator: " › ")
                ))
            }
            node.children.forEach { walk($0, level: level + 1, ancestors: ancestors + [title]) }
        }
        walk(document.root, level: 0, ancestors: [])
        cache.derivedRoot = document.root
        // First spelling in the map wins; sorted only for display.
        cache.allTags = Tags.distinct(tagsSeen)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        cache.dueItems = items.sorted { $0.due < $1.due }
        cache.closedCount = closedTotal
    }

    private var closedCount: Int {
        refreshDerivedIfNeeded()
        return cache.closedCount
    }

    /// Active filter chips as case-folded keys — tags are case-insensitive.
    private var activeTagKeys: Set<String> { Tags.keys(activeTags) }

    private var allTags: [String] {
        refreshDerivedIfNeeded()
        return cache.allTags
    }

    private static let dueAmber = Color(red: 0.87, green: 0.54, blue: 0.04)

    /// One inspector color chip. A `nil` color is the "Automatic" swatch: a
    /// hollow ring with a sparkle, matching the old picker's Automatic option.
    private func colorSwatch(_ color: Color?, selected: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let color {
                    Circle().fill(color)
                } else {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .overlay(Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary))
                }
            }
            .frame(width: 22, height: 22)
            .overlay {
                if selected {
                    Circle().stroke(color ?? Palette.selection, lineWidth: 2).padding(-3)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.panel)
        .help(color == nil ? "Automatic (level color)" : "Set color")
    }

    @ViewBuilder
    private func detailRows(id: UUID, node: MindNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(InspectorLayout.cardOrder, id: \.self) { card in
                inspectorCard(card, id: id, node: node)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The panel's cards, in `InspectorLayout.cardOrder` — acts before
    /// decoration, so Close/Reopen is the first thing you reach rather than the
    /// card hiding under the fold.
    @ViewBuilder
    private func inspectorCard(_ card: InspectorLayout.Card, id: UUID, node: MindNode) -> some View {
        switch card {
        case .closed: closedCard(id: id)
        case .dueDate: dueDateCard(id: id, node: node)
        case .tags: tagsCard(id: id, node: node)
        case .link: linkCard(id: id, node: node)
        case .connections: connectionsCard(for: id)
        case .color: colorCard(id: id, node: node)
        case .iconImage: iconImageCard(id: id, node: node)
        }
    }

    /// Color card — moved here from the toolbar in the header cleanup.
    private func colorCard(id: UUID, node: MindNode) -> some View {
        let nodeColor = layout.nodes[id]?.color ?? Palette.root
        return metaCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    iconTile("paintpalette", tint: nodeColor)
                    sectionEyebrow("Color")
                }
                FlowLayout(spacing: 8) {
                    ForEach(Array(Palette.branches.enumerated()), id: \.offset) { index, color in
                        colorSwatch(color, selected: node.colorIndex == index) {
                            setNodeColor(index)
                        }
                    }
                    // Automatic: clears the override, back to the level hue.
                    colorSwatch(nil, selected: node.colorIndex == nil) {
                        setNodeColor(nil)
                    }
                }
            }
        }
    }

    /// Icon + image card. Two facets of the same idea — what this topic looks
    /// like — so they share one card rather than each taking a row.
    private func iconImageCard(id: UUID, node: MindNode) -> some View {
        metaCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    iconTile("face.smiling", tint: Self.dueAmber)
                    sectionEyebrow("Icon & image")
                    Spacer()
                    if node.icon != nil || node.image != nil {
                        Button("Clear") {
                            apply { $0.root.update(id) { $0.icon = nil; $0.image = nil } }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.selection)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        iconPickerShown = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(node.icon ?? "🙂")
                                .font(.system(size: 15))
                                .opacity(node.icon == nil ? 0.35 : 1)
                            Text(node.icon == nil ? "Add icon" : "Change")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Chrome.text)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Chrome.toolBg))
                    }
                    .buttonStyle(.panel)
                    .popover(isPresented: $iconPickerShown, arrowEdge: .bottom) {
                        iconPicker(for: id, current: node.icon)
                    }
                    Button {
                        chooseImage(for: id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(.system(size: 11, weight: .semibold))
                            Text(node.image == nil ? "Add image" : "Replace")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Chrome.text)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Chrome.toolBg))
                    }
                    .buttonStyle(.panel)
                    Spacer(minLength: 0)
                }
                if let stored = node.image, let image = ImageStore.image(for: stored) {
                    HStack(spacing: 8) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(stored.pixelWidth) × \(stored.pixelHeight)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(byteCount(stored.data.count))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            apply { $0.root.update(id) { $0.image = nil } }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.nodeBadge)
                        .help("Remove image")
                    }
                }
            }
        }
    }

    private func dueDateCard(id: UUID, node: MindNode) -> some View {
        metaCard {
            iconTile("calendar", tint: Self.dueAmber)
            VStack(alignment: .leading, spacing: 2) {
                sectionEyebrow("Due date")
                Button {
                    inspectorDatePickerShown = true
                } label: {
                    if let due = node.dueDate {
                        Text(Metrics.dueLongString(due))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Chrome.text)
                    } else {
                        Text("Add due date")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Chrome.inactiveText)
                    }
                }
                .buttonStyle(.panel)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .popover(isPresented: $inspectorDatePickerShown, arrowEdge: .bottom) {
                    DueDateCalendar(
                        selection: node.dueDate,
                        onSelect: { new in apply { $0.root.update(id) { $0.dueDate = new } } },
                        onRemove: {
                            apply { $0.root.update(id) { $0.dueDate = nil } }
                            inspectorDatePickerShown = false
                        }
                    )
                }
            }
            Spacer()
            if node.dueDate != nil {
                Button {
                    apply { $0.root.update(id) { $0.dueDate = nil } }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.nodeBadge)
                .help("Remove due date")
            }
        }
    }

    private func linkCard(id: UUID, node: MindNode) -> some View {
        metaCard {
            iconTile("link", tint: Palette.selection)
            VStack(alignment: .leading, spacing: 2) {
                sectionEyebrow("Link")
                TextField("https://example.com", text: linkBinding(for: id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($inspectorField, equals: .link)
            }
            Button {
                if let link = node.link { openLink(link) }
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle((node.link ?? "").isEmpty ? Color.secondary : Palette.selection)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(
                        (node.link ?? "").isEmpty ? Color.primary.opacity(0.06)
                                                  : Palette.selection.opacity(0.12)))
            }
            .buttonStyle(.panel)
            .disabled((node.link ?? "").isEmpty)
            .onHover { inside in
                if inside, !(node.link ?? "").isEmpty {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help("Open link")
        }
    }

    private func tagsCard(id: UUID, node: MindNode) -> some View {
        let nodeColor = layout.nodes[id]?.color ?? Palette.root
        return metaCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    iconTile("tag", tint: Color(red: 0.16, green: 0.66, blue: 0.41))
                    sectionEyebrow("Tags")
                    Spacer()
                    Menu {
                        let others = allTags.filter { !Tags.contains(node.tags, $0) }
                        if others.isEmpty {
                            Text("No other tags")
                        } else {
                            ForEach(others, id: \.self) { tag in
                                Button("#" + tag) { addTag(tag, to: id) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .help("Add an existing tag")
                }
                if !node.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(node.tags, id: \.self) { tag in
                            TagChip(text: tag, color: nodeColor, style: .inspector,
                                    onRemove: {
                                        apply { $0.root.update(id) { $0.tags = Tags.removing(tag, from: $0.tags) } }
                                    })
                        }
                    }
                }
                let matches = tagSuggestions(excluding: node.tags)
                TextField("Add tag", text: $newTagText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($inspectorField, equals: .tag)
                    .onSubmit {
                        if let i = tagHighlight, matches.indices.contains(i) {
                            addTag(matches[i], to: id)
                        } else {
                            addTag(newTagText, to: id)
                        }
                    }
                    // Tab fills in the rest of the best match, leaving the
                    // caret in the field so it can still be edited.
                    .onKeyPress(.tab) {
                        guard let top = matches.first else { return .ignored }
                        newTagText = top
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !matches.isEmpty else { return .ignored }
                        tagHighlight = min((tagHighlight ?? -1) + 1, matches.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard let current = tagHighlight else { return .ignored }
                        tagHighlight = current == 0 ? nil : current - 1
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !matches.isEmpty else { return .ignored }
                        tagSuggestionsHidden = true
                        tagHighlight = nil
                        return .handled
                    }
                    .onChange(of: newTagText) { _, _ in
                        tagSuggestionsHidden = false
                        tagHighlight = nil
                    }
                if !matches.isEmpty {
                    tagSuggestionList(matches, for: id)
                }
            }
        }
    }

    /// Close / reopen — the labeled affordance, living where people look for
    /// topic actions. Right-click and ⌘↩ do the same; the map bubble itself
    /// stays clean.
    @ViewBuilder
    private func closedCard(id: UUID) -> some View {
        if id != document.root.id {
            let closed = effectivelyClosed(id)
            Button {
                toggleClosed(id)
            } label: {
                HStack(spacing: 11) {
                    iconTile(closed ? "arrow.uturn.backward" : "checkmark.circle",
                             tint: closed ? Palette.selection : Chrome.inactiveText)
                    Text(closed ? "Reopen Topic" : "Close Topic")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Chrome.text)
                    Spacer()
                    Text("\u{2318}\u{21A9}")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
                        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.panel)
            .help(closed ? "Reopen this topic"
                  : "Close this topic — it leaves the map but stays under its parent")
        }
    }

    // MARK: Icon, image, and connection cards

    private func iconPicker(for id: UUID, current: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
        sectionEyebrow("Icon")
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8),
                  spacing: 4) {
            ForEach(IconPalette.emoji, id: \.self) { emoji in
                Button {
                    apply { $0.root.update(id) { $0.icon = emoji } }
                        iconPickerShown = false
                    } label: {
                        Text(emoji)
                            .font(.system(size: 16))
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(current == emoji ? Chrome.activeTint : Color.clear))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.panel)
                }
            }
            Divider()
            HStack(spacing: 8) {
                // Anything at all, including multi-scalar emoji the grid can't
                // reasonably enumerate.
                TextField("Any emoji", text: $iconDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 90)
                    .onSubmit { commitIconDraft(for: id) }
                Button("Set") { commitIconDraft(for: id) }
                    .font(.system(size: 12, weight: .semibold))
                    .disabled(iconDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if current != nil {
                    Button("Remove") {
                        apply { $0.root.update(id) { $0.icon = nil } }
                        iconPickerShown = false
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.redText)
                }
            }
            Button("Emoji & Symbols…") {
                NSApp.orderFrontCharacterPalette(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.selection)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func commitIconDraft(for id: UUID) {
        let trimmed = iconDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // One grapheme: an icon is a single glyph, and pasted text would
        // otherwise silently become a second title.
        let icon = String(trimmed.prefix(1))
        apply { $0.root.update(id) { $0.icon = icon } }
        iconDraft = ""
        iconPickerShown = false
    }

    private func chooseImage(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let stored = ImageStore.prepare(contentsOf: url) else {
            exportError = "MindBlow could not read that image."
            return
        }
        apply { $0.root.update(id) { $0.image = stored } }
    }

    private func byteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Cross-links on this topic. Always shown, even when empty, because the
    /// gesture that makes one is not otherwise discoverable.
    @ViewBuilder
    private func connectionsCard(for id: UUID) -> some View {
        let connections = document.links(touching: id)
        metaCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    iconTile("arrow.triangle.branch", tint: Palette.crossLink)
                    sectionEyebrow("Connections")
                    Spacer()
                    if !connections.isEmpty {
                        Text("\(connections.count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if connections.isEmpty {
                    Text("Hold \u{2325} and drag from one topic to another to connect them.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Chrome.inactiveText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(connections) { link in
                        connectionRow(link, from: id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectionRow(_ link: MindLink, from id: UUID) -> some View {
        let otherID = link.from == id ? link.to : link.from
        let other = document.root.node(with: otherID)
        let outgoing = link.from == id
        HStack(spacing: 7) {
            Image(systemName: outgoing ? "arrow.right" : "arrow.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.crossLink)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    // Jump to the other end — the point of a relation is
                    // getting to the thing it points at.
                    if let otherID = other?.id { revealNode(otherID, openNotes: true) }
                } label: {
                    Text(other.map { OutlineText.title(of: $0) } ?? "Missing topic")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Chrome.text)
                        .lineLimit(1)
                }
                .buttonStyle(.panel)
                .disabled(other == nil)
                if editingLinkID == link.id {
                    TextField("Label", text: $linkLabelDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit { commitLinkLabel() }
                        .onExitCommand { editingLinkID = nil }
                } else {
                    Button {
                        editingLinkID = link.id
                        linkLabelDraft = link.label
                    } label: {
                        Text(link.label.isEmpty ? "Add label" : link.label)
                            .font(.system(size: 11))
                            .foregroundStyle(link.label.isEmpty ? Chrome.inactiveText : .secondary)
                    }
                    .buttonStyle(.panel)
                }
            }
            Spacer(minLength: 0)
            Button {
                removeLink(link.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.nodeBadge)
            .help("Remove connection")
        }
        .padding(.vertical, 2)
    }

    /// Existing tags that match what is being typed — the ones worth
    /// offering, minus any the topic already carries.
    private func tagSuggestions(excluding taken: [String]) -> [String] {
        guard !tagSuggestionsHidden else { return [] }
        return Tags.suggestions(for: newTagText, from: allTags, excluding: taken)
    }

    /// Clickable completions under the "Add tag" field.
    private func tagSuggestionList(_ matches: [String], for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element) { index, tag in
                Button { addTag(tag, to: id) } label: {
                    Text("#" + tag)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Chrome.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background {
                            if index == tagHighlight {
                                RoundedRectangle(cornerRadius: 6).fill(Chrome.activeTint)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.panel)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Chrome.toolBg)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 1))
        )
    }

    private func addTag(_ raw: String, to id: UUID) {
        let tag = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        guard !tag.isEmpty else { return }
        let known = allTags
        apply { $0.root.update(id) { $0.tags = Tags.adding(tag, to: $0.tags, known: known) } }
        newTagText = ""
        tagHighlight = nil
        tagSuggestionsHidden = false
    }

    private func linkBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { document.root.node(with: id)?.link ?? "" },
            set: { new in document.root.update(id) { $0.link = new.isEmpty ? nil : new } }
        )
    }

    private func openLink(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// Live binding into the selected node's notes. Direct write-through —
    /// notes edits are autosaved with the document but not undo-tracked.
    private var selectedNodeText: String {
        selection.flatMap { document.root.node(with: $0)?.text } ?? ""
    }

    private func commitTitleDraft() {
        guard let selection else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        titleDraft = trimmed
        commit(text: trimmed, to: selection)
    }

    private func notesBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { document.root.node(with: id)?.notes ?? "" },
            set: { new in document.root.update(id) { $0.notes = new } }
        )
    }

    // MARK: Zoom

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomAtGestureStart ?? zoom
                zoomAtGestureStart = base
                setZoom(base * value.magnification)
            }
            .onEnded { _ in zoomAtGestureStart = nil }
    }

    private func setZoom(_ newZoom: CGFloat) {
        let clamped = Metrics.quantizeZoom(newZoom)
        guard clamped != zoom else { return }
        // Keep the point at the viewport center fixed while zooming.
        let factor = clamped / zoom
        pan.width *= factor
        pan.height *= factor
        zoom = clamped
        pan = clampPan(pan, viewSize: canvasSize)
    }

    /// Wheel & Cmd+scroll zoom (anchored at the cursor); trackpad scroll pans.
    private func handleScroll(_ event: NSEvent, at point: CGPoint, in size: CGSize) -> Bool {
        // The inspector floats over the canvas, so the wheel monitor sees
        // events the panel should get. Hand those back, or its cards can
        // never be scrolled — the map would pan under them instead.
        if showNotes, selection != nil, point.x > size.width - Metrics.sidebarWidth {
            return false
        }
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            let exponent = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
            zoomTo(zoom * exp(exponent), at: point, in: size)
        } else {
            let target = CGSize(width: pan.width + event.scrollingDeltaX,
                                height: pan.height + event.scrollingDeltaY)
            pan = clampPan(target, viewSize: size)
        }
        return true
    }

    private func zoomTo(_ newZoom: CGFloat, at point: CGPoint, in size: CGSize) {
        let clamped = Metrics.quantizeZoom(newZoom)
        let applied = clamped / zoom
        guard applied != 1 else { return }
        // Keep the world point under the cursor fixed.
        let cx = size.width / 2, cy = size.height / 2
        pan.width = point.x - cx - (point.x - cx - pan.width) * applied
        pan.height = point.y - cy - (point.y - cy - pan.height) * applied
        zoom = clamped
        pan = clampPan(pan, viewSize: size)
    }

    /// Allows panning until the map has just left the screen (fully blank),
    /// but no further. `bounds` defaults to the current layout, but callers
    /// that just changed the tree (e.g. focusNode expanding a branch) pass the
    /// bounds of the tree they are clamping against, since the cached layout
    /// may not reflect the change yet this cycle.
    private func clampPan(_ p: CGSize, viewSize: CGSize, bounds: CGRect? = nil) -> CGSize {
        guard viewSize.width > 0, viewSize.height > 0 else { return p }
        let b = bounds ?? layout.bounds
        let margin: CGFloat = 0
        let cx = viewSize.width / 2, cy = viewSize.height / 2
        let lowerX = margin - cx - b.maxX * zoom
        let upperX = viewSize.width - margin - cx - b.minX * zoom
        let lowerY = margin - cy - b.maxY * zoom
        let upperY = viewSize.height - margin - cy - b.minY * zoom
        return CGSize(width: min(max(p.width, lowerX), upperX),
                      height: min(max(p.height, lowerY), upperY))
    }

    // MARK: Drag & drop re-parenting

    private func nodeDragGesture(id: UUID, viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("canvas"))
            .onChanged { value in
                // ⌥ turns the drag into a connection instead of a move. Plain
                // drag already means re-parent, and re-parenting is the far
                // more common act, so the new gesture takes the modifier.
                if linkDragFrom == nil, dragNodeID == nil,
                   NSEvent.modifierFlags.contains(.option) {
                    commitEditing()
                    linkDragFrom = id
                    hoveredID = nil
                }
                if linkDragFrom == id {
                    linkDragPoint = value.location
                    let hit = node(at: value.location, in: viewSize)
                    linkDragTarget = hit == id ? nil : hit
                    return
                }
                guard id != layoutRootID else { return }
                if dragNodeID != id {
                    commitEditing()
                    dragNodeID = id
                    // A multi-selection travels together; anything nested
                    // inside another member is already coming along with it.
                    let moving = selectedIDs.contains(id) ? actionTargets : [id]
                    dragDescendants = moving.reduce(into: Set<UUID>()) {
                        $0.formUnion(descendantIDs(of: $1))
                    }
                    hoveredID = nil
                }
                dragOffset = value.translation
                dropIndicator = dropTarget(at: value.location, viewSize: viewSize)
            }
            .onEnded { value in
                if linkDragFrom == id {
                    if let target = linkDragTarget { createLink(from: id, to: target) }
                    linkDragFrom = nil
                    linkDragPoint = nil
                    linkDragTarget = nil
                    return
                }
                let indicator = dropTarget(at: value.location, viewSize: viewSize)
                defer {
                    dragNodeID = nil
                    dragOffset = .zero
                    dropIndicator = nil
                    dragDescendants = []
                }
                guard dragNodeID == id else { return }
                let moving = selectedIDs.contains(id) ? actionTargets : [id]
                if let indicator {
                    moveNodes(moving, to: indicator.id, mode: indicator.mode)
                } else if moving.allSatisfy({ document.root.parentID(of: $0) == layoutRootID }) {
                    // Dropped on empty canvas: move the branch to that side.
                    let rootScreenX = screen(.zero, in: viewSize).x
                    let newSide: BranchSide = value.location.x < rootScreenX ? .left : .right
                    apply { doc in
                        for target in moving { doc.root.update(target) { $0.side = newSide } }
                    }
                }
            }
    }

    private func descendantIDs(of id: UUID) -> Set<UUID> {
        guard let node = document.root.node(with: id) else { return [] }
        var ids = Set<UUID>()
        func walk(_ n: MindNode) {
            ids.insert(n.id)
            n.children.forEach(walk)
        }
        walk(node)
        return ids
    }

    /// Where a drop at `point` would land. See `DropTargeting` for why a node
    /// claims a whole column lane rather than just its own rect.
    private func dropTarget(at point: CGPoint, viewSize: CGSize) -> DropIndicator? {
        let layout = self.layout
        return DropTargeting.indicator(
            at: point,
            order: layout.order,
            rootID: layoutRootID,
            excluding: dragDescendants
        ) { id in
            guard let geom = layout.nodes[id] else { return nil }
            let origin = screen(CGPoint(x: geom.rect.minX, y: geom.rect.minY), in: viewSize)
            return CGRect(x: origin.x, y: origin.y,
                          width: geom.rect.width * zoom, height: geom.rect.height * zoom)
        }
    }

    /// Moves nodes (each with its whole subtree): into a new parent, or next to
    /// a sibling for reordering. Order is preserved when several move at once.
    private func moveNodes(_ ids: [UUID], to target: UUID, mode: DropMode) {
        let movable = ids.filter { id in
            id != layoutRootID
                && id != document.root.id
                && !descendantIDs(of: id).contains(target)
        }
        guard !movable.isEmpty else { return }
        var subtrees = movable.compactMap { document.root.node(with: $0) }
        guard !subtrees.isEmpty else { return }
        let targetSide = layout.nodes[target]?.side
        apply { doc in
            movable.forEach { doc.root.remove($0) }
            switch mode {
            case .child:
                doc.root.update(target) {
                    $0.isCollapsed = false
                    $0.children.append(contentsOf: subtrees)
                }
            case .before, .after:
                guard let parentID = doc.root.parentID(of: target) else {
                    doc.root.update(target) { $0.children.append(contentsOf: subtrees) }
                    return
                }
                if parentID == doc.root.id, let targetSide {
                    let side: BranchSide = targetSide == .left ? .left : .right
                    for i in subtrees.indices { subtrees[i].side = side }
                }
                doc.root.update(parentID) { parent in
                    let index = parent.children.firstIndex { $0.id == target } ?? parent.children.count
                    let at = mode == .before ? index : index + 1
                    parent.children.insert(contentsOf: subtrees,
                                           at: min(at, parent.children.count))
                }
            }
        }
        selection = movable[0]
    }

    private func nodeOpacity(_ id: UUID, geom: NodeGeom) -> Double {
        if dragNodeID == id { return 0.8 }
        if dragNodeID != nil, dragDescendants.contains(id) { return 0.45 }
        if dimmed(geom) { return 0.25 }
        // Fade non-matches while searching — but only when the query actually
        // found something, so a zero-result query doesn't grey out the map.
        if searchActive, !searchMatches.isEmpty, !searchMatchSet.contains(id) { return 0.4 }
        return 1
    }

    /// Search-highlight role for a node: the stepped-to match, a plain match,
    /// or nothing.
    private func searchState(_ id: UUID) -> SearchMatchState {
        guard searchActive, !searchMatches.isEmpty else { return .none }
        if searchMatches.indices.contains(currentMatchIndex),
           searchMatches[currentMatchIndex] == id { return .current }
        return searchMatchSet.contains(id) ? .match : .none
    }

    // MARK: Due-date agenda

    private struct DueItem: Identifiable {
        let id: UUID
        let text: String
        let due: Date
        let color: Color
        /// Nearest ancestor's title — the row's disambiguator ("Feedback
        /// Meetings" vs "Set up feedback meetings"). nil for the root's own
        /// children, where it would only repeat the map name on every row.
        let parent: String?
        /// Full ancestry, for the row tooltip and accessibility label.
        let path: String
    }

    private var dueItems: [DueItem] {
        refreshDerivedIfNeeded()
        return cache.dueItems
    }

    private var overdueCount: Int {
        dueItems.filter { DayClock.isOverdue($0.due) }.count
    }

    private var agendaSidebar: some View {
        let today = DayClock.startOfToday
        let items = dueItems
        let overdue = items.filter { $0.due < today }
        let dueToday = items.filter { DayClock.isToday($0.due) && $0.due >= today }
        let upcoming = items.filter { !DayClock.isToday($0.due) && $0.due >= today }

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Due Dates")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                if !overdue.isEmpty {
                    Text("\(overdue.count) overdue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing Scheduled",
                    systemImage: "calendar",
                    description: Text("Add due dates to topics in the details panel.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        agendaSection("Overdue", items: overdue, dateColor: .red,
                                      rowTint: Color.red.opacity(0.07))
                        agendaSection("Today", items: dueToday, dateColor: .orange,
                                      rowTint: Color.orange.opacity(0.09))
                        agendaSection("Upcoming", items: upcoming, dateColor: .secondary,
                                      rowTint: .clear)
                    }
                    .padding(10)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func agendaSection(_ title: String, items: [DueItem], dateColor: Color,
                               rowTint: Color) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(0.7)
                .foregroundStyle(dateColor == .secondary ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(dateColor))
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 2)
            // Row identity has to be scoped to the section. All three sections
            // share one LazyVStack, and keying rows on the node id alone let
            // the lazy container reuse an already-realized row when a topic
            // moved between sections: changing a due date from overdue to
            // upcoming re-sorted the row into Upcoming but kept the view built
            // for Overdue — old date text, old red tint.
            ForEach(items.map { (key: "\(title)#\($0.id)", item: $0) }, id: \.key) { entry in
                let item = entry.item
                Button {
                    focusNode(item.id)
                } label: {
                    // Baseline-aligned so the relative date rides the title's
                    // baseline rather than centering against the two-line block.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(item.color).frame(width: 9, height: 9)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.text)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            // Date · nearest parent. The date keeps its weight
                            // and layout priority; the parent is the element
                            // that gives way when the row runs out of width.
                            HStack(spacing: 5) {
                                Text(item.due, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(dateColor)
                                    .fixedSize()
                                if let parent = item.parent {
                                    Text("·")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                    Text(parent)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        Spacer(minLength: 6)
                        Text(item.due, format: .relative(presentation: .named))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(rowTint))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.panel)
                .help(item.path)
            }
        }
    }

    /// Reveals a node reached from the agenda: expands collapsed ancestors,
    /// selects it, opens the details panel, and centers the viewport on it.
    private func focusNode(_ id: UUID) { revealNode(id, openNotes: true) }

    /// Reveals a node: expands any collapsed ancestors, selects it, optionally
    /// opens the details panel, and glides the viewport so the node sits at the
    /// center. `openNotes` is false for find-stepping, which shouldn't yank the
    /// inspector open on every keystroke.
    private func revealNode(_ id: UUID, openNotes: Bool) {
        // Build the tree as it will be once ancestors are expanded, so the
        // node can be placed even while it is currently hidden — and so the
        // centering math uses the post-expansion position, not the stale one
        // the document binding may still report this cycle.
        var root = document.root
        if let path = root.path(to: id) {
            for ancestor in path.dropLast() where ancestor.isCollapsed {
                root.update(ancestor.id) { $0.isCollapsed = false }
            }
        }
        if root != document.root {
            apply { $0.root = root }
        }
        selection = id
        if openNotes { showNotes = true }

        let target = MapLayout(root: root)
        guard let geom = target.nodes[id], canvasSize != .zero else { return }
        let center = CGPoint(x: geom.rect.midX, y: geom.rect.midY)
        withAnimation(.snappy(duration: 0.3)) {
            pan = clampPan(CGSize(width: -center.x * zoom, height: -center.y * zoom),
                           viewSize: canvasSize, bounds: target.bounds)
        }
    }

    // MARK: Minimap

    private func minimap(_ layout: MapLayout, viewSize: CGSize) -> some View {
        let mmW: CGFloat = 180, mmH: CGFloat = 124
        let b = layout.bounds.insetBy(dx: -30, dy: -30)
        let scale = min(mmW / max(b.width, 1), mmH / max(b.height, 1))
        let offX = (mmW - b.width * scale) / 2
        let offY = (mmH - b.height * scale) / 2
        let effPan = CGSize(width: pan.width + dragPan.width, height: pan.height + dragPan.height)

        // Current viewport in world coords → minimap rect.
        let worldMinX = (0 - viewSize.width / 2 - effPan.width) / zoom
        let worldMinY = (0 - viewSize.height / 2 - effPan.height) / zoom
        let viewport = CGRect(
            x: (worldMinX - b.minX) * scale + offX,
            y: (worldMinY - b.minY) * scale + offY,
            width: viewSize.width / zoom * scale,
            height: viewSize.height / zoom * scale
        )

        // The node rects only move when the map does, but the viewport box
        // moves every pan frame. Drawn as two layers so panning repaints one
        // rounded rect instead of re-filling every node in the map.
        return MinimapNodes(layout: layout, bounds: b, scale: scale, offX: offX, offY: offY)
            .equatable()
            .overlay {
                Canvas { ctx, _ in
                    ctx.fill(Path(roundedRect: viewport, cornerRadius: 3),
                             with: .color(Palette.selection.opacity(0.08)))
                    ctx.stroke(Path(roundedRect: viewport, cornerRadius: 3),
                               with: .color(Palette.selection.opacity(0.85)), lineWidth: 1.5)
                }
            }
            .frame(width: mmW, height: mmH)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let world = CGPoint(
                            x: (value.location.x - offX) / scale + b.minX,
                            y: (value.location.y - offY) / scale + b.minY
                        )
                        pan = clampPan(CGSize(width: -world.x * zoom, height: -world.y * zoom),
                                       viewSize: viewSize)
                    }
            )
            .help("Navigation map — click or drag to move around")
    }

    /// The minimap's static layer: every node rect, redrawn only when the
    /// layout itself changes. Equatable on the layout's generation so a pan
    /// or zoom frame skips it entirely.
    private struct MinimapNodes: View, Equatable {
        var layout: MapLayout
        var bounds: CGRect
        var scale: CGFloat
        var offX: CGFloat
        var offY: CGFloat

        static func == (lhs: MinimapNodes, rhs: MinimapNodes) -> Bool {
            lhs.layout.generation == rhs.layout.generation
                && lhs.bounds == rhs.bounds
                && lhs.scale == rhs.scale
                && lhs.offX == rhs.offX
                && lhs.offY == rhs.offY
        }

        var body: some View {
            Canvas { ctx, _ in
                for id in layout.order {
                    guard let geom = layout.nodes[id] else { continue }
                    let r = CGRect(
                        x: (geom.rect.minX - bounds.minX) * scale + offX,
                        y: (geom.rect.minY - bounds.minY) * scale + offY,
                        width: max(geom.rect.width * scale, 2),
                        height: max(geom.rect.height * scale, 1.5)
                    )
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1.5),
                             with: .color(geom.color.opacity(0.85)))
                }
            }
        }
    }

    // MARK: Mutations (undo-aware)

    private func apply(_ change: (inout MindMapDocument) -> Void) {
        var copy = document
        change(&copy)
        setDocument(copy)
    }

    private func setDocument(_ new: MindMapDocument) {
        let old = document
        guard new != old else { return }
        document = new
        undoManager?.registerUndo(withTarget: UndoShim.shared) { _ in
            setDocument(old)
        }
    }

    private func addChildToSelection() {
        commitEditing()
        guard let selection, document.root.node(with: selection) != nil else { return }
        let new = MindNode()
        apply {
            $0.root.update(selection) {
                $0.isCollapsed = false
                $0.children.append(new)
            }
        }
        self.selection = new.id
        startEditing(new.id, initialDraft: "")
    }

    private func addSiblingToSelection() {
        commitEditing()
        guard let selection else { return }
        guard let parentID = document.root.parentID(of: selection) else {
            // Root has no siblings; add a child instead.
            addChildToSelection()
            return
        }
        let new = MindNode()
        apply {
            $0.root.update(parentID) { parent in
                let index = parent.children.firstIndex { $0.id == selection } ?? parent.children.count - 1
                parent.children.insert(new, at: index + 1)
            }
        }
        self.selection = new.id
        startEditing(new.id, initialDraft: "")
    }

    private func deleteSelection() {
        let target = editingID ?? selection
        editingID = nil
        focus = .canvas
        guard let target, target != document.root.id,
              let node = document.root.node(with: target) else { return }
        if node.text.isEmpty, node.children.isEmpty {
            // Nothing in it — remove immediately, the map rebalances itself.
            performDelete(target)
        } else {
            pendingDelete = target
        }
    }

    private var deleteAlertTitle: String {
        guard let id = pendingDelete, let node = document.root.node(with: id) else { return "Delete topic?" }
        let name = node.text.isEmpty ? "this topic" : "\u{201C}\(node.text)\u{201D}"
        return "Delete \(name)?"
    }

    private var deleteAlertMessage: String {
        guard let id = pendingDelete else { return "" }
        let subtopics = descendantIDs(of: id).count - 1
        if subtopics > 0 {
            return "It has \(subtopics) subtopic\(subtopics == 1 ? "" : "s") that will be deleted with it. You can undo with \u{2318}Z."
        }
        return "You can undo with \u{2318}Z."
    }

    private func performDelete(_ id: UUID) {
        let parentID = document.root.parentID(of: id)
        apply { doc in
            doc.root.remove(id)
            // A connector to a topic that no longer exists has nothing to draw
            // between; drop it in the same undo step as the delete.
            doc.pruneDanglingLinks()
        }
        selectedIDs.remove(id)
        if selectedIDs.count < 2 { selectedIDs = [] }
        selection = parentID ?? document.root.id
    }

    // MARK: Clipboard

    /// Whether canvas-level shortcuts apply. When a text field owns the
    /// keyboard, ⌘C/⌘X/⌘V belong to it, not to the map.
    private var canvasOwnsKeyboard: Bool {
        editingID == nil && !notesFocused && inspectorField == nil && !findFocused
    }

    /// Topics a bulk action applies to: the multi-selection when there is one,
    /// otherwise just the primary. Nested members are dropped so a subtree is
    /// never acted on twice.
    private var actionTargets: [UUID] {
        let ids = selectedIDs.isEmpty ? Set([selection].compactMap { $0 }) : selectedIDs
        return MapSelection.topmost(ids, in: document.root)
    }

    private func copySelection(cut: Bool) {
        // The hidden shortcut button fires app-wide, so hand ⌘C back to
        // whichever text field actually has the keyboard.
        guard canvasOwnsKeyboard else {
            NSApp.sendAction(cut ? #selector(NSText.cut(_:)) : #selector(NSText.copy(_:)),
                             to: nil, from: nil)
            return
        }
        let targets = actionTargets
        let nodes = targets.compactMap { document.root.node(with: $0) }
        guard !nodes.isEmpty else { return }
        MapClipboard.write(nodes)
        guard cut else { return }
        // Copying the root is fine; cutting it is not — there would be no map
        // left to paste back into.
        let removable = targets.filter { $0 != document.root.id }
        guard !removable.isEmpty else { return }
        let parentID = document.root.parentID(of: removable[0])
        apply { doc in
            removable.forEach { doc.root.remove($0) }
            doc.pruneDanglingLinks()
        }
        selectedIDs = []
        selection = parentID ?? document.root.id
    }

    /// Pastes whatever is on the pasteboard under the selected topic.
    private func pasteIntoSelection() {
        guard canvasOwnsKeyboard else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return
        }
        let target = selection ?? layoutRootID
        let nodes = MapClipboard.read()
        // An image on the pasteboard attaches to the topic instead of becoming
        // one — pasting a screenshot onto a topic obviously means "put it here".
        if nodes.isEmpty, let image = ImageStore.prepareFromPasteboard() {
            apply { $0.root.update(target) { $0.image = image } }
            return
        }
        guard !nodes.isEmpty, document.root.node(with: target) != nil else { return }
        apply { doc in
            doc.root.update(target) {
                $0.isCollapsed = false
                $0.children.append(contentsOf: nodes)
            }
        }
        selection = nodes[0].id
        selectedIDs = nodes.count > 1 ? Set(nodes.map(\.id)) : []
    }

    // MARK: Multi-select

    /// Adds or removes a topic from the multi-selection. The primary follows
    /// the most recent addition so the inspector always shows something you
    /// just touched.
    private func toggleInSelection(_ id: UUID) {
        commitEditing()
        var ids = selectedIDs
        if ids.isEmpty, let selection { ids.insert(selection) }
        if ids.contains(id) {
            ids.remove(id)
            if selection == id { selection = ids.first ?? nil }
        } else {
            ids.insert(id)
            selection = id
        }
        selectedIDs = ids.count > 1 ? ids : []
        if selectedIDs.isEmpty, ids.count == 1 { selection = ids.first }
        focus = .canvas
    }

    private func clearMultiSelection() {
        selectedIDs = []
    }

    /// Applies `change` to every target as one undoable step.
    private func applyToTargets(_ change: @escaping (inout MindNode) -> Void) {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        apply { doc in
            for id in targets { doc.root.update(id, change) }
        }
    }

    private func closeTargets() {
        let targets = actionTargets.filter { $0 != document.root.id }
        guard targets.count > 1 else {
            if let id = targets.first { toggleClosed(id) }
            return
        }
        let stamp = Date()
        withAnimation(.easeOut(duration: 0.14)) {
            apply { doc in
                for id in targets { doc.root.update(id) { $0.closedAt = stamp } }
            }
        }
        selection = document.root.parentID(of: targets[0]) ?? document.root.id
        selectedIDs = []
    }

    private func deleteTargets() {
        let targets = actionTargets.filter { $0 != document.root.id }
        guard targets.count > 1 else {
            deleteSelection()
            return
        }
        // Deleting one topic asks first; deleting twenty had better ask too.
        commitEditing()
        pendingBulkDelete = targets
    }

    private func performBulkDelete(_ targets: [UUID]) {
        guard let first = targets.first else { return }
        let parentID = document.root.parentID(of: first)
        apply { doc in
            targets.forEach { doc.root.remove($0) }
            doc.pruneDanglingLinks()
        }
        selectedIDs = []
        selection = parentID ?? document.root.id
    }

    private var bulkDeleteMessage: String {
        guard let pendingBulkDelete else { return "" }
        let total = pendingBulkDelete.reduce(0) {
            $0 + (document.root.node(with: $1)?.subtreeCount ?? 0)
        }
        let extra = total - pendingBulkDelete.count
        var message = extra > 0
            ? "That is \(total) topics in all, including \(extra) subtopic\(extra == 1 ? "" : "s")."
            : ""
        message += message.isEmpty ? "You can undo with \u{2318}Z." : " You can undo with \u{2318}Z."
        return message
    }

    /// Floating bar that appears once more than one topic is selected. Bulk
    /// actions live here rather than in the toolbar because they only exist
    /// while a multi-selection does.
    private var multiSelectBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Chrome.text)
            Divider().frame(height: 16)
            Menu {
                Button {
                    applyToTargets { $0.colorIndex = nil }
                } label: {
                    Label("Automatic", systemImage: "sparkles")
                }
                ForEach(Array(Self.colorNames.enumerated()), id: \.offset) { index, name in
                    Button(name) { applyToTargets { $0.colorIndex = index } }
                }
            } label: {
                Label("Color", systemImage: "paintpalette")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Menu {
                if allTags.isEmpty {
                    Text("No tags yet")
                } else {
                    ForEach(allTags, id: \.self) { tag in
                        Button("#" + tag) {
                            applyToTargets { $0.tags = Tags.adding(tag, to: $0.tags, known: allTags) }
                        }
                    }
                }
            } label: {
                Label("Tag", systemImage: "tag")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                closeTargets()
            } label: {
                Label("Close", systemImage: "checkmark.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.chip)
            Button {
                deleteTargets()
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Chrome.redText)
            }
            .buttonStyle(.chip)
            Divider().frame(height: 16)
            Button("Clear") { clearMultiSelection() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.selection)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    // MARK: Cross-links

    /// Creates a relation, unless one already joins these two topics.
    private func createLink(from: UUID, to: UUID) {
        guard from != to else { return }
        let exists = document.links.contains {
            ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from)
        }
        guard !exists else { return }
        apply { $0.links.append(MindLink(from: from, to: to)) }
    }

    private func removeLink(_ id: UUID) {
        apply { $0.links.removeAll { $0.id == id } }
        if editingLinkID == id { editingLinkID = nil }
    }

    private func commitLinkLabel() {
        guard let editingLinkID else { return }
        let text = linkLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        apply { doc in
            guard let index = doc.links.firstIndex(where: { $0.id == editingLinkID }) else { return }
            doc.links[index].label = text
        }
        self.editingLinkID = nil
    }

    /// Screen point → world point. The inverse of `screen(_:in:)`, needed by
    /// the marquee and the ⌥-drag rubber band.
    private func world(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - pan.width - dragPan.width - size.width / 2) / zoom,
            y: (point.y - pan.height - dragPan.height - size.height / 2) / zoom
        )
    }

    /// Topmost node whose rect contains `point` (screen coordinates).
    private func node(at point: CGPoint, in size: CGSize) -> UUID? {
        let layout = self.layout
        for id in layout.order.reversed() {
            guard let geom = layout.nodes[id] else { continue }
            let origin = screen(CGPoint(x: geom.rect.minX, y: geom.rect.minY), in: size)
            let rect = CGRect(x: origin.x, y: origin.y,
                              width: geom.rect.width * zoom, height: geom.rect.height * zoom)
            if rect.contains(point) { return id }
        }
        return nil
    }

    // MARK: Export

    private func runExport(_ format: MapExport.Format) {
        commitEditing()
        let panel = NSSavePanel()
        let base = OutlineText.title(of: document.root)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = (base.isEmpty ? "Mind Map" : base)
            + "." + format.fileExtension
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = MapExport.data(document, format: format) else {
            exportError = "MindBlow could not render this map as \(format.title)."
            return
        }
        do {
            try data.write(to: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: Closing topics

    /// Closed itself or hidden under a closed ancestor.
    private func effectivelyClosed(_ id: UUID) -> Bool {
        document.root.path(to: id)?.contains { $0.isClosed } ?? false
    }

    /// ⌘Return: close the selected topic, or reopen it when it is closed.
    /// During an inline edit the editor owns the Return family — commit only.
    private func toggleClosedSelection() {
        guard !notesFocused, inspectorField == nil else { return }
        if editingID != nil {
            commitEditing()
            return
        }
        guard selection != nil else { return }
        // With several topics selected, ⌘↩ closes all of them at once.
        closeTargets()
    }

    private func toggleClosed(_ id: UUID) {
        guard id != document.root.id else { return }
        if effectivelyClosed(id) { reopen(id) } else { close(id) }
    }

    private func close(_ id: UUID) {
        guard id != document.root.id, document.root.node(with: id) != nil else { return }
        commitEditing()
        // Closing is a repeated action: land on the next open sibling so
        // ⌘Return, ⌘Return walks a checklist. Fall back to the previous
        // sibling, then the parent. Selection inside the closing subtree
        // climbs to the parent — never point at something the canvas can't
        // draw.
        var nextSelection = selection
        let parentID = document.root.parentID(of: id)
        if let current = selection, current == id || descendantIDs(of: id).contains(current) {
            if current == id, let parentID, let parent = document.root.node(with: parentID),
               let index = parent.children.firstIndex(where: { $0.id == id }) {
                let below = parent.children[(index + 1)...].first { !$0.isClosed }
                let above = parent.children[..<index].reversed().first { !$0.isClosed }
                nextSelection = below?.id ?? above?.id ?? parentID
            } else {
                nextSelection = parentID ?? document.root.id
            }
        }
        withAnimation(.easeOut(duration: 0.14)) {
            apply { $0.root.update(id) { $0.closedAt = Date() } }
        }
        selection = nextSelection
        focus = .canvas
    }

    /// Clears `closedAt` on the topic and on every closed ancestor along the
    /// path — reopening must actually produce a visible topic.
    private func reopen(_ id: UUID) {
        apply { doc in
            guard let path = doc.root.path(to: id) else { return }
            for ancestor in path where ancestor.isClosed {
                doc.root.update(ancestor.id) { $0.closedAt = nil }
            }
        }
        selection = id
    }

    // MARK: Editing

    private func startEditingSelection() {
        guard let selection else { return }
        startEditing(selection)
    }

    /// Every pointer-driven rename goes through here: the bubble's double
    /// click and the context menu's "Edit Topic". Renaming is deliberate now,
    /// so it always claims the selection first.
    private func beginRename(_ id: UUID) {
        guard editingID != id else { return }
        commitEditing()
        selection = id
        startEditing(id)
    }

    private func startEditing(_ id: UUID, initialDraft: String? = nil) {
        // Do not require the node to be readable from the document binding:
        // right after apply() inserts a node, the binding can still return
        // the previous tree (DocumentGroup applies writes asynchronously).
        draft = initialDraft ?? (document.root.node(with: id)?.text ?? "")
        // Entering deliberately (double-click, Space) highlights the old text
        // so it is obvious the topic is live and typing will replace it; a
        // keystroke-started edit keeps that keystroke and parks the caret.
        editingSelectsAll = initialDraft == nil
        editingID = id
        // Release SwiftUI focus so the AppKit editor can hold first responder
        // without the focus system yanking it back to the canvas.
        focus = nil
    }

    private func commitEditing() {
        guard let editingID else { return }
        commit(text: draft, to: editingID)
    }

    /// Commits `text` to a specific node. Safe to call multiple times and
    /// from stale editor callbacks: it never touches another node's editing
    /// session.
    private func commit(text: String, to id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        apply { $0.root.update(id) { $0.text = trimmed } }
        if editingID == id {
            editingID = nil
            focus = .canvas
        }
    }

    private func cancelEditing() {
        // Cancelling a brand-new node that never got a name (and has no
        // children) removes it instead of leaving an empty topic behind.
        if let editingID,
           editingID != document.root.id,
           let node = document.root.node(with: editingID),
           node.text.isEmpty, node.children.isEmpty, draft.isEmpty {
            let parentID = document.root.parentID(of: editingID)
            apply { $0.root.remove(editingID) }
            selection = parentID ?? document.root.id
        }
        editingID = nil
        focus = .canvas
    }

    // MARK: Keyboard navigation

    private enum Direction { case up, down, left, right }

    private func navigate(_ direction: Direction) {
        guard let selection else {
            self.selection = document.root.id
            return
        }
        commitEditing()
        let root = document.root
        let side = layout.nodes[selection]?.side ?? .right
        let isRoot = selection == root.id

        switch direction {
        case .right:
            if isRoot || side == .right {
                selectFirstChild(of: selection)
            } else {
                selectParent(of: selection)
            }
        case .left:
            if isRoot || side == .left {
                selectFirstChild(of: selection, preferring: .left)
            } else {
                selectParent(of: selection)
            }
        case .up, .down:
            // Steps over open siblings only — closed ones aren't on the map.
            guard let parentID = root.parentID(of: selection),
                  let parent = root.node(with: parentID),
                  let index = parent.openChildren.firstIndex(where: { $0.id == selection })
            else { return }
            let next = direction == .up ? index - 1 : index + 1
            if parent.openChildren.indices.contains(next) {
                self.selection = parent.openChildren[next].id
            }
        }
    }

    private func selectFirstChild(of id: UUID, preferring side: Side = .right) {
        guard let node = document.root.node(with: id), !node.isCollapsed else { return }
        let candidates = node.openChildren.filter { layout.nodes[$0.id]?.side == side }
        if let first = candidates.first ?? node.openChildren.first {
            selection = first.id
        }
    }

    private func selectParent(of id: UUID) {
        if let parentID = document.root.parentID(of: id) {
            selection = parentID
        }
    }
}

extension CGRect {
    /// Rectangle spanning two arbitrary corners, in any order — what a drag
    /// from one point to another describes.
    init(corner: CGPoint, opposite: CGPoint) {
        self.init(x: min(corner.x, opposite.x), y: min(corner.y, opposite.y),
                  width: abs(opposite.x - corner.x), height: abs(opposite.y - corner.y))
    }
}

/// Class target for UndoManager registration (undo closures capture the real state).
final class UndoShim {
    static let shared = UndoShim()
}

/// Subtle dot-grid canvas backdrop from the design refresh. Depends only on
/// its size and the color scheme, so panning and zooming never redraw it.
struct DotGridBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(
            colors: dark
                ? [Color(white: 0.125), Color(white: 0.085)]
                : [Color(red: 0.992, green: 0.996, blue: 0.996),
                   Color(red: 0.953, green: 0.961, blue: 0.976)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(
            Canvas { ctx, size in
                let spacing: CGFloat = 26
                var path = Path()
                var y = spacing / 2
                while y < size.height {
                    var x = spacing / 2
                    while x < size.width {
                        path.addEllipse(in: CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3))
                        x += spacing
                    }
                    y += spacing
                }
                ctx.fill(path, with: .color(.primary.opacity(dark ? 0.10 : 0.07)))
            }
        )
    }
}
