import SwiftUI
import AppKit

enum Side {
    case left, right
}

/// Earliest due date hidden inside a collapsed branch.
struct CollapsedDueInfo: Equatable {
    var date: Date
    var nodeID: UUID
    var color: Color
}

struct NodeGeom: Equatable {
    var rect: CGRect
    var level: Int
    var side: Side
    var color: Color
    /// Raw topic text, carried here so views never have to search the tree.
    var text: String
    /// Open (non-closed) children only — drives the collapse badge and span.
    var childCount: Int
    /// Direct closed children, surfaced by the ✓N badge.
    var closedChildCount: Int
    var isCollapsed: Bool
    var hasNotes: Bool
    var dueDate: Date?
    var link: String?
    var tags: [String]
    var icon: String? = nil
    var image: NodeImage? = nil
    /// Completion of the subtree below this node; drives the progress ring.
    var progress: SubtreeProgress = SubtreeProgress(done: 0, total: 0)
    var collapsedDue: CollapsedDueInfo? = nil
}

extension NodeGeom {
    /// Whether two geometries would draw the same bubble — everything except
    /// *where* it sits.
    ///
    /// This is the difference between a collapse feeling instant and taking
    /// about a second on a big map. Collapsing a branch re-stacks nearly every
    /// node, so comparing whole rects made every `NodeView` unequal and forced
    /// all of them to re-render their gradients, shadows, and badges. None of
    /// that depends on position: the canvas applies `.position()` outside the
    /// node's body, so a node that only moved can keep its rendered content
    /// and just be placed somewhere new.
    func matchesRendering(of other: NodeGeom) -> Bool {
        rect.size == other.rect.size
            && level == other.level
            && side == other.side
            && color == other.color
            && text == other.text
            && childCount == other.childCount
            && closedChildCount == other.closedChildCount
            && isCollapsed == other.isCollapsed
            && hasNotes == other.hasNotes
            && dueDate == other.dueDate
            && link == other.link
            && tags == other.tags
            && icon == other.icon
            && image?.id == other.image?.id
            && progress == other.progress
            && collapsedDue == other.collapsedDue
    }
}

extension MapLayout {
    /// Node color: explicit override first, then the level default.
    static func color(for node: MindNode, level: Int) -> Color {
        if let i = node.colorIndex, Palette.branches.indices.contains(i) {
            return Palette.branches[i]
        }
        return level == 0 ? Palette.root : Palette.branch(level - 1)
    }

    /// Earliest due date among a node's open descendants (not the node
    /// itself). Closed subtrees are skipped — a collapse badge must not
    /// advertise a due date for work that is already done.
    static func earliestDue(in node: MindNode, level: Int) -> CollapsedDueInfo? {
        var best: (date: Date, node: MindNode, level: Int)?
        func walk(_ n: MindNode, _ lvl: Int) {
            if let due = n.dueDate, best == nil || due < best!.date {
                best = (due, n, lvl)
            }
            n.openChildren.forEach { walk($0, lvl + 1) }
        }
        node.openChildren.forEach { walk($0, level + 1) }
        guard let best else { return nil }
        return CollapsedDueInfo(date: best.date, nodeID: best.node.id,
                                color: color(for: best.node, level: best.level))
    }
}

struct EdgeGeom: Identifiable {
    let id: UUID
    var from: CGPoint
    var to: CGPoint
    let color: Color
    /// Depth of the child node — trunk edges (level 1) draw thicker.
    let level: Int
}

/// Geometry for cross-links, shared by the live canvas and the image exporter
/// so an exported PNG traces the same curves you were looking at.
enum LinkCurve {
    /// Where a connector meets a topic: the point on the bubble's edge facing
    /// the other end, so the curve stops at the border instead of burrowing
    /// into the middle of the card.
    static func anchor(on rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let sx = dx == 0 ? CGFloat.greatestFiniteMagnitude : (rect.width / 2) / abs(dx)
        let sy = dy == 0 ? CGFloat.greatestFiniteMagnitude : (rect.height / 2) / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: center.x + dx * s, y: center.y + dy * s)
    }

    /// Single control point for the connector's arc. Bowed perpendicular to the
    /// straight line so a link between two topics on the same branch doesn't
    /// disappear under the tree edge that already joins them.
    static func control(from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(hypot(dx, dy), 1)
        let bow = min(70, length * 0.22)
        return CGPoint(x: (from.x + to.x) / 2 - dy / length * bow,
                       y: (from.y + to.y) / 2 + dx / length * bow)
    }

    /// Midpoint of the arc — where the label sits. For a cubic with both
    /// controls at `control`, t=0.5 lands three-quarters of the way to it.
    static func midpoint(from: CGPoint, to: CGPoint, control: CGPoint) -> CGPoint {
        CGPoint(x: (from.x + to.x) / 8 + control.x * 0.75,
                y: (from.y + to.y) / 8 + control.y * 0.75)
    }
}

/// A rigid vertical shift applied to one side of the map.
///
/// Expand/collapse pins the node you clicked by translating only its own side,
/// so the opposite side and the root never move. Keeping the correction to a
/// single number per side is what makes it safe: a rigid translation can't
/// introduce overlap (each side is internally non-overlapping, and the two
/// never cross the root), and it costs two floats to store and undo.
struct SideOffsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0

    static let zero = SideOffsets()
    var isZero: Bool { left == 0 && right == 0 }

    subscript(side: Side) -> CGFloat {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }

    /// Re-anchors so that `id` keeps the position it currently occupies in
    /// `shown` once the freshly laid out `base` takes over.
    ///
    /// Absolute, not accumulated: the offset is derived from where the node
    /// actually is versus where it would land, so a collapse followed by an
    /// expand lands back on exactly zero and error can never pile up over a
    /// long session of folding.
    mutating func anchor(_ id: UUID, shown: MapLayout, base: MapLayout) {
        guard id != base.rootID, let old = shown.nodes[id], let new = base.nodes[id] else {
            self = .zero
            return
        }
        self[old.side] = old.rect.midY - new.rect.midY
    }
}

// MARK: - Node sizing / styling

enum Metrics {
    static let maxTextWidth: CGFloat = 240
    static let hGap: CGFloat = 56
    static let vGap: CGFloat = 14
    /// Width of the agenda sidebar and of the inspector that floats over the
    /// canvas — the canvas has to know the latter to leave its scroll wheel
    /// alone.
    static let sidebarWidth: CGFloat = 300

    static func fontSize(for level: Int) -> CGFloat {
        switch level {
        case 0: return 17
        case 1: return 14
        default: return 13
        }
    }

    static func fontWeight(for level: Int) -> NSFont.Weight {
        switch level {
        case 0: return .bold
        case 1: return .semibold
        default: return .medium
        }
    }

    static func nsFont(for level: Int) -> NSFont {
        nsFont(for: level, scale: 1)
    }

    static func font(for level: Int) -> Font {
        font(for: level, scale: 1)
    }

    // Screen-space variants: nodes render at final size for crisp text at
    // any zoom (a scale transform would rasterize and blur).
    // The root topic uses the rounded design for a friendlier display face.
    static func nsFont(for level: Int, scale: CGFloat) -> NSFont {
        let size = fontSize(for: level) * scale
        let base = NSFont.systemFont(ofSize: size, weight: fontWeight(for: level))
        guard level == 0,
              let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size)
        else { return base }
        return rounded
    }

    private struct TextKey: Hashable {
        let text: String
        let level: Int
    }

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 2.5

    /// Zoom is snapped to this many steps per unit. Text is measured and
    /// rendered at the live scale (see `textSize`), so an unquantized zoom
    /// mints a fresh TextKit pass for *every* node on *every* gesture tick —
    /// the single most expensive thing the canvas can do. Snapping to ~2%
    /// steps is visually continuous but bounds the distinct scales, so a
    /// pinch mostly reuses measurements and repeated ticks that land on the
    /// same step short-circuit before touching the view tree at all.
    static let zoomSteps: CGFloat = 48

    static func quantizeZoom(_ zoom: CGFloat) -> CGFloat {
        let clamped = min(max(zoom, minZoom), maxZoom)
        return (clamped * zoomSteps).rounded() / zoomSteps
    }

    /// Measuring text is a full TextKit layout pass (~15µs each), and the
    /// same strings are measured on every relayout — memoize. Bucketed by
    /// scale so a zoom sweep evicts stale scales instead of wiping every
    /// measurement (including the scale-1 ones the layout engine lives on).
    /// Main-thread only, like all of SwiftUI layout.
    private static var textSizeCache: [CGFloat: [TextKey: CGSize]] = [:]
    /// Scales in insertion order, oldest first.
    private static var cachedScales: [CGFloat] = []
    private static var cachedEntries = 0
    /// Budgeted by entry rather than by scale: a small map can afford to keep
    /// the whole zoom ladder warm (so zooming out and back is free), while a
    /// huge one still stops at a few megabytes.
    private static let maxCachedEntries = 60_000

    /// Measures at the actual rendered size — font metrics are not linear
    /// with point size, so scaling a base-size measurement mis-wraps (it
    /// changes the line count outright at some zooms).
    static func textSize(for text: String, level: Int, scale: CGFloat) -> CGSize {
        // Levels ≥ 2 share a font, so they share cache entries too.
        let key = TextKey(text: text, level: min(level, 2))
        if let cached = textSizeCache[scale]?[key] { return cached }
        let measured = text.isEmpty ? "Topic" : text
        let bounds = (measured as NSString).boundingRect(
            with: NSSize(width: maxTextWidth * scale, height: 4000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: nsFont(for: level, scale: scale)]
        )
        let size = CGSize(width: ceil(bounds.width) + 3, height: ceil(bounds.height))
        if textSizeCache[scale] == nil { cachedScales.append(scale) }
        textSizeCache[scale, default: [:]][key] = size
        cachedEntries += 1
        // Evict whole scales, oldest first, but never scale 1 — the layout
        // engine measures every node at it on every relayout.
        while cachedEntries > maxCachedEntries,
              let victim = cachedScales.firstIndex(where: { $0 != 1 }) {
            let dropped = cachedScales.remove(at: victim)
            cachedEntries -= textSizeCache.removeValue(forKey: dropped)?.count ?? 0
        }
        return size
    }

    static func font(for level: Int, scale: CGFloat) -> Font {
        let weight: Font.Weight = level == 0 ? .bold : (level == 1 ? .semibold : .medium)
        return .system(size: fontSize(for: level) * scale, weight: weight,
                       design: level == 0 ? .rounded : .default)
    }

    static func padding(for level: Int) -> (h: CGFloat, v: CGFloat) {
        level == 0 ? (18, 12) : (14, 8)
    }

    static func textSize(for text: String, level: Int) -> CGSize {
        textSize(for: text, level: level, scale: 1)
    }

    /// Width a topic's text is *drawn* at for a given zoom.
    ///
    /// Deliberately the scale-1 measurement scaled up, rather than a fresh
    /// measurement at `scale: zoom`: measuring per-zoom also multiplies the
    /// `maxTextWidth` wrap cap, so a label long enough to reach it re-wraps
    /// into different lines and measures far narrower than the rect the layout
    /// reserved for it. The bubble is centred on that rect, so the shortfall
    /// split either side and the branch line — which ends at `rect.minX` —
    /// stopped short of the node.
    static func displayTextWidth(for text: String, level: Int, zoom: CGFloat) -> CGFloat {
        textSize(for: text, level: level).width * zoom
    }

    /// Lines the layout reserved for this label, measured at scale 1.
    ///
    /// Glyph advances are not linear in point size: the same string set at
    /// `size * zoom` needs *more* than `width * zoom` when zoomed out (up to
    /// ~20% at the minimum zoom). Rendered into the scaled-down rect it
    /// re-wraps — "Documentation" breaks mid-word, one-liners become two — and
    /// the bubble grows taller than the rect the layout placed its siblings
    /// around. Pinning the line count keeps the box honest and lets the text
    /// tighten/shrink into it instead.
    static func lineCount(for text: String, level: Int) -> Int {
        let measured = textSize(for: text, level: level).height
        let single = textSize(for: "X", level: level).height
        guard single > 0 else { return 1 }
        return max(1, Int((measured / single).rounded()))
    }

    /// Widest a topic image is ever drawn. Beyond this the bubble stops being a
    /// topic and starts being a picture frame.
    static let maxImageWidth: CGFloat = 200
    static let imageGap: CGFloat = 6
    static let iconGap: CGFloat = 5

    /// Horizontal room an emoji icon takes at a given level. Emoji render at
    /// roughly square advance, so this tracks the font size rather than being
    /// measured per glyph — measuring would put a TextKit pass on the layout's
    /// hot path for a value that never varies by more than a point.
    static func iconWidth(for level: Int) -> CGFloat {
        (fontSize(for: level) * 1.3).rounded()
    }

    /// On-canvas size of a topic's image, aspect-preserved and capped.
    static func imageDisplaySize(for node: MindNode) -> CGSize {
        node.image?.displaySize(maxWidth: maxImageWidth) ?? .zero
    }

    static func nodeSize(for node: MindNode, level: Int) -> CGSize {
        let text = textSize(for: node.text, level: level)
        let pad = padding(for: level)
        let meta = metaSize(for: node, level: level)
        let image = imageDisplaySize(for: node)
        var titleWidth = text.width
        if let icon = node.icon, !icon.isEmpty {
            titleWidth += iconWidth(for: level) + iconGap
        }
        var height = text.height + pad.v * 2
        if meta.height > 0 { height += meta.height + 4 }
        if image.height > 0 { height += image.height + imageGap }
        let width = max(max(titleWidth, min(meta.width, 230)), image.width) + pad.h * 2
        return CGSize(width: width, height: height)
    }

    // MARK: Metadata chips (due date + tags)

    static let metaFontSize: CGFloat = 9.5
    /// Vertical room reserved above a node for its protruding due-date chip.
    static let dueClearance: CGFloat = 12
    static let maxVisibleTags = 2

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static func dueString(_ date: Date) -> String {
        dueFormatter.string(from: date)
    }

    private static let dueLongFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM"
        return f
    }()

    /// Inspector due-date value, e.g. "Thu, 24 Jul" (design spec 1a).
    static func dueLongString(_ date: Date) -> String {
        dueLongFormatter.string(from: date)
    }

    private static var chipWidthCache: [String: CGFloat] = [:]

    /// Rendered width of one metadata chip. Shared by the layout engine, the
    /// node view, and the image exporter so all three agree on how wide a tag
    /// row is.
    static func chipWidth(_ label: String, level: Int) -> CGFloat {
        // Dot pills carry a 6pt dot + gap; hash pills only their padding.
        let chrome: CGFloat = level >= 2 ? 22 : 14
        let key = "\(chrome)|\(label)"
        if let cached = chipWidthCache[key] { return cached }
        let font = NSFont.systemFont(ofSize: metaFontSize, weight: .semibold)
        let w = ceil((label as NSString).size(withAttributes: [.font: font]).width) + chrome
        chipWidthCache[key] = w
        return w
    }

    /// Chip labels a node actually shows, overflow pill included.
    static func chipLabels(for tags: [String], level: Int) -> [String] {
        guard !tags.isEmpty else { return [] }
        var labels = tags.prefix(maxVisibleTags).map { chipLabel($0, level: level) }
        if tags.count > maxVisibleTags {
            labels.append("+\(tags.count - maxVisibleTags)")
        }
        return labels
    }

    /// Chip text for a tag: deep levels use a colored-dot pill (no hash),
    /// filled levels keep the classic #tag treatment.
    static func chipLabel(_ tag: String, level: Int) -> String {
        level >= 2 ? tag : "#" + tag
    }

    /// Size of the metadata area under the node text (tags row);
    /// .zero when there is none.
    static func metaSize(for node: MindNode, level: Int) -> CGSize {
        let labels = chipLabels(for: node.tags, level: level)
        guard !labels.isEmpty else { return .zero }
        let width = labels.reduce(0) { $0 + chipWidth($1, level: level) }
            + CGFloat(labels.count - 1) * 4
        return CGSize(width: width, height: 17)
    }
}

/// A due date means a calendar *day*, but the model stores an instant. Storing
/// the day's midnight puts the value right against the day boundary, so any
/// time-zone difference between writing and reading it — travel, a system
/// time-zone change, a calendar snapshot taken before one — renders it as the
/// day before. Midday is the furthest point from either boundary and survives
/// a shift of up to 12 hours in either direction.
enum DueDay {
    static func canonical(_ date: Date, in calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date).addingTimeInterval(12 * 3600)
    }
}

/// Today's date boundaries, cached. `Calendar.current` builds a fresh
/// calendar on every access and `startOfDay` is not cheap; the due-date chip
/// asked for both on every node on every render.
enum DayClock {
    private static var day: (start: Date, end: Date, computedAt: Date)?

    private static func current() -> (start: Date, end: Date, computedAt: Date) {
        let now = Date()
        // Recheck at most once a minute — enough to roll over at midnight
        // without measurable cost while the app is idle.
        if let day, now.timeIntervalSince(day.computedAt) < 60, now < day.end {
            return day
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let fresh = (start, end, now)
        day = fresh
        return fresh
    }

    static var startOfToday: Date { current().start }

    static func isToday(_ date: Date) -> Bool {
        let day = current()
        return date >= day.start && date < day.end
    }

    static func isOverdue(_ date: Date) -> Bool { date < current().start }
}

enum Palette {
    static let root = Color(red: 0.16, green: 0.22, blue: 0.31)

    /// Brand blue used for selection, primary actions, and the minimap
    /// viewport (design spec #2F6BD6).
    static let selection = Color(red: 0.184, green: 0.420, blue: 0.839)

    /// A fully closed branch. The only place completion earns a color.
    static let done = Color(light: NSColor(red: 0.13, green: 0.60, blue: 0.36, alpha: 1),
                            dark: NSColor(red: 0.35, green: 0.80, blue: 0.55, alpha: 1))

    /// Cross-link connectors. Deliberately outside the branch palette: a
    /// relation belongs to neither topic's hue, and borrowing one would read as
    /// "part of that branch" — the opposite of what a cross-link means.
    static let crossLink = Color(light: NSColor(red: 0.45, green: 0.36, blue: 0.62, alpha: 1),
                                 dark: NSColor(red: 0.72, green: 0.63, blue: 0.90, alpha: 1))

    /// Root topic gradient (design spec #33425C → #232F45).
    static let rootGradientTop = Color(red: 0.200, green: 0.259, blue: 0.361)
    static let rootGradientBottom = Color(red: 0.137, green: 0.184, blue: 0.271)

    static let branches: [Color] = [
        Color(red: 0.26, green: 0.54, blue: 0.83),  // blue
        Color(red: 0.88, green: 0.34, blue: 0.29),  // coral
        Color(red: 0.94, green: 0.60, blue: 0.13),  // orange
        Color(red: 0.18, green: 0.66, blue: 0.41),  // green
        Color(red: 0.58, green: 0.37, blue: 0.76),  // purple
        Color(red: 0.10, green: 0.62, blue: 0.58),  // teal
        Color(red: 0.88, green: 0.25, blue: 0.53),  // pink
        Color(red: 0.55, green: 0.44, blue: 0.36),  // brown
    ]

    static func branch(_ index: Int) -> Color {
        branches[index % branches.count]
    }
}

/// Toolbar / chrome tokens from the design spec (light values are the spec
/// hexes; dark values are hand-tuned equivalents).
enum Chrome {
    static let text = Color(light: NSColor(red: 0.122, green: 0.153, blue: 0.200, alpha: 1),
                            dark: NSColor(white: 0.92, alpha: 1))                     // #1F2733
    static let toolIcon = Color(light: NSColor(red: 0.333, green: 0.380, blue: 0.478, alpha: 1),
                                dark: NSColor(white: 0.78, alpha: 1))                 // #55617A
    static let inactiveText = Color(light: NSColor(red: 0.486, green: 0.522, blue: 0.596, alpha: 1),
                                    dark: NSColor(white: 0.55, alpha: 1))             // #7C8598
    static let toolBg = Color(light: NSColor(red: 0.933, green: 0.945, blue: 0.965, alpha: 1),
                              dark: NSColor(white: 1, alpha: 0.09))                   // #EEF1F6
    static let segmentBg = Color(light: NSColor(red: 0.906, green: 0.918, blue: 0.941, alpha: 1),
                                 dark: NSColor(white: 1, alpha: 0.11))                // #E7EAF0
    static let segmentActive = Color(light: .white,
                                     dark: NSColor(white: 1, alpha: 0.18))
    static let activeTint = Color(light: NSColor(red: 0.914, green: 0.941, blue: 0.988, alpha: 1),
                                  dark: NSColor(red: 0.184, green: 0.420, blue: 0.839, alpha: 0.30)) // #E9F0FC
    static let activeIcon = Color(light: NSColor(red: 0.184, green: 0.420, blue: 0.839, alpha: 1),
                                  dark: NSColor(red: 0.55, green: 0.72, blue: 1.0, alpha: 1))        // #2F6BD6
    static let redBg = Color(light: NSColor(red: 0.992, green: 0.925, blue: 0.918, alpha: 1),
                             dark: NSColor(red: 0.88, green: 0.30, blue: 0.26, alpha: 0.25))         // #FDECEA
    static let redText = Color(light: NSColor(red: 0.820, green: 0.282, blue: 0.247, alpha: 1),
                               dark: NSColor(red: 1.0, green: 0.55, blue: 0.50, alpha: 1))           // #D1483F
}

extension Color {
    /// Appearance-adaptive color: resolves per the effective light/dark mode.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Slightly lighter/darker variants used for node gradient fills.
    func lightened(_ fraction: CGFloat) -> Color {
        Color(nsColor: NSColor(self).blended(withFraction: fraction, of: .white) ?? NSColor(self))
    }

    func darkened(_ fraction: CGFloat) -> Color {
        Color(nsColor: NSColor(self).blended(withFraction: fraction, of: .black) ?? NSColor(self))
    }
}

// MARK: - Layout engine

/// Classic mind map layout: root centered at the origin, top-level branches
/// balanced left/right, each subtree stacked vertically around its parent.
struct MapLayout {
    var nodes: [UUID: NodeGeom] = [:]
    var order: [UUID] = []
    var edges: [EdgeGeom] = []
    /// World-space bounding box of all placed nodes.
    var bounds: CGRect = .zero

    /// Node sizes and subtree spans, filled by one bottom-up pass so every
    /// node is measured exactly once per layout (the old recursive `span`
    /// re-measured each node once per ancestor level).
    private var sizes: [UUID: CGSize] = [:]
    private var spans: [UUID: CGFloat] = [:]
    /// Subtree completion for every node, from one bottom-up pass. Asking each
    /// node for its own `progress` while placing it would re-walk its subtree
    /// once per ancestor — quadratic, on the layout's hot path.
    private var progressByID: [UUID: SubtreeProgress] = [:]

    /// Cheap identity for a layout. Views that only need to know "is this
    /// still the same layout?" compare this instead of walking every node
    /// geometry — an O(1) check on a hot path that runs per frame.
    private(set) var generation: Int
    private static var nextGeneration = 0

    /// The root sits at the origin and never takes a side offset.
    private(set) var rootID: UUID = UUID()

    init(root: MindNode) {
        rootID = root.id
        Self.nextGeneration += 1
        generation = Self.nextGeneration
        computeMetrics(root, level: 0)
        computeProgress(root)
        let rootSize = sizes[root.id] ?? .zero
        let rootRect = CGRect(
            x: -rootSize.width / 2, y: -rootSize.height / 2,
            width: rootSize.width, height: rootSize.height
        )
        let rootChildren = root.openChildren
        nodes[root.id] = NodeGeom(
            rect: rootRect, level: 0, side: .right, color: Self.color(for: root, level: 0),
            text: root.text,
            childCount: rootChildren.count, closedChildCount: root.closedChildren.count,
            isCollapsed: root.isCollapsed,
            hasNotes: !root.notes.isEmpty, dueDate: root.dueDate,
            link: root.link, tags: root.tags,
            icon: root.icon, image: root.image,
            progress: progressByID[root.id] ?? SubtreeProgress(done: 0, total: 0),
            collapsedDue: root.isCollapsed ? Self.earliestDue(in: root, level: 0) : nil
        )
        order.append(root.id)

        bounds = rootRect
        guard !root.isCollapsed else { return }

        // Honor explicit side choices; auto branches go to the lighter side.
        //
        // Weighed by subtree size rather than on-screen span, because span
        // skips collapsed branches: folding one branch used to shrink a side's
        // running total, flip this comparison, and fling every later auto-sided
        // branch across the root. `openWeight` ignores collapse, so a fold can
        // never re-decide a side.
        let childWeights = rootChildren.map(\.openWeight)
        var right: [MindNode] = []
        var left: [MindNode] = []
        var rightWeight = 0
        var leftWeight = 0
        for (i, child) in rootChildren.enumerated() {
            switch child.side {
            case .right:
                right.append(child)
                rightWeight += childWeights[i]
            case .left:
                left.append(child)
                leftWeight += childWeights[i]
            case nil:
                if rightWeight <= leftWeight {
                    right.append(child)
                    rightWeight += childWeights[i]
                } else {
                    left.append(child)
                    leftWeight += childWeights[i]
                }
            }
        }

        layoutBranchGroup(right, side: .right, parentRect: rootRect)
        layoutBranchGroup(left, side: .left, parentRect: rootRect)
        bounds = nodes.values.map(\.rect).reduce(rootRect) { $0.union($1) }
    }

    /// Returns this layout with each side shifted vertically by `offsets`.
    ///
    /// The root stays where it is, so a level-1 edge simply stretches: its
    /// `from` end is anchored on the root and only its `to` end moves.
    func applying(_ offsets: SideOffsets) -> MapLayout {
        guard !offsets.isZero else { return self }
        var copy = self
        Self.nextGeneration += 1
        copy.generation = Self.nextGeneration

        for (id, geom) in nodes where id != rootID {
            copy.nodes[id]?.rect.origin.y += offsets[geom.side]
        }
        for i in copy.edges.indices {
            guard let side = nodes[copy.edges[i].id]?.side else { continue }
            let shift = offsets[side]
            copy.edges[i].to.y += shift
            // Level-1 edges hang off the root, which never moves.
            if copy.edges[i].level > 1 { copy.edges[i].from.y += shift }
        }
        copy.bounds = copy.nodes.values.map(\.rect).reduce(
            copy.nodes[rootID]?.rect ?? bounds
        ) { $0.union($1) }
        return copy
    }

    /// Bottom-up sizing: measures each visible node once and derives the
    /// vertical span its subtree needs. Skips inside collapsed branches and
    /// closed subtrees — those nodes are never placed.
    private mutating func computeMetrics(_ node: MindNode, level: Int) {
        let size = Metrics.nodeSize(for: node, level: level)
        sizes[node.id] = size
        let children = node.openChildren
        guard !node.isCollapsed, !children.isEmpty else {
            spans[node.id] = size.height
            return
        }
        var childTotal: CGFloat = 0
        for child in children {
            computeMetrics(child, level: level + 1)
            childTotal += (spans[child.id] ?? 0)
                + (child.dueDate != nil ? Metrics.dueClearance : 0)
        }
        childTotal += CGFloat(children.count - 1) * Metrics.vGap
        spans[node.id] = max(size.height, childTotal)
    }

    /// Fills `progressByID` for the whole tree — collapsed and closed branches
    /// included, since a closed subtree is exactly what the ring counts.
    /// Returns the node's own subtree size so parents can total it up.
    @discardableResult
    private mutating func computeProgress(_ node: MindNode) -> Int {
        var done = 0
        var total = 0
        for child in node.children {
            let size = computeProgress(child)
            total += size
            done += child.isClosed ? size : (progressByID[child.id]?.done ?? 0)
        }
        progressByID[node.id] = SubtreeProgress(done: done, total: total)
        return total + 1
    }

    private mutating func layoutBranchGroup(_ group: [MindNode], side: Side, parentRect: CGRect) {
        guard !group.isEmpty else { return }
        let childSpans = group.map { spans[$0.id] ?? 0 }
        let extras = group.map { $0.dueDate != nil ? Metrics.dueClearance : 0 }
        let total = childSpans.reduce(0, +) + extras.reduce(0, +)
            + CGFloat(max(0, group.count - 1)) * Metrics.vGap
        var y = parentRect.midY - total / 2
        for (i, child) in group.enumerated() {
            y += extras[i]
            place(child, level: 1, side: side, parentRect: parentRect,
                  parentID: nil, centerY: y + childSpans[i] / 2)
            y += childSpans[i] + Metrics.vGap
        }
    }

    private mutating func place(
        _ node: MindNode, level: Int, side: Side, parentRect: CGRect,
        parentID: UUID?, centerY: CGFloat
    ) {
        // Same depth shares a color unless the node has an explicit override.
        let color = Self.color(for: node, level: level)
        let size = sizes[node.id] ?? .zero
        let x = side == .right
            ? parentRect.maxX + Metrics.hGap
            : parentRect.minX - Metrics.hGap - size.width
        let rect = CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)

        let children = node.openChildren
        nodes[node.id] = NodeGeom(
            rect: rect, level: level, side: side, color: color,
            text: node.text,
            childCount: children.count, closedChildCount: node.closedChildren.count,
            isCollapsed: node.isCollapsed,
            hasNotes: !node.notes.isEmpty, dueDate: node.dueDate,
            link: node.link, tags: node.tags,
            icon: node.icon, image: node.image,
            progress: progressByID[node.id] ?? SubtreeProgress(done: 0, total: 0),
            collapsedDue: node.isCollapsed ? Self.earliestDue(in: node, level: level) : nil
        )
        order.append(node.id)

        let from = side == .right
            ? CGPoint(x: parentRect.maxX, y: parentRect.midY)
            : CGPoint(x: parentRect.minX, y: parentRect.midY)
        let to = side == .right
            ? CGPoint(x: rect.minX, y: rect.midY)
            : CGPoint(x: rect.maxX, y: rect.midY)
        edges.append(EdgeGeom(id: node.id, from: from, to: to, color: color, level: level))

        guard !node.isCollapsed, !children.isEmpty else { return }

        let childSpans = children.map { spans[$0.id] ?? 0 }
        let extras = children.map { $0.dueDate != nil ? Metrics.dueClearance : 0 }
        let total = childSpans.reduce(0, +) + extras.reduce(0, +)
            + CGFloat(children.count - 1) * Metrics.vGap
        var y = centerY - total / 2
        for (i, child) in children.enumerated() {
            y += extras[i]
            place(child, level: level + 1, side: side, parentRect: rect,
                  parentID: node.id, centerY: y + childSpans[i] / 2)
            y += childSpans[i] + Metrics.vGap
        }
    }
}
