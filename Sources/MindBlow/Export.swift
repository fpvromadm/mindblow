import AppKit
import SwiftUI

/// Getting a map out of MindBlow.
///
/// Text exports go through `OutlineText` so what you copy and what you export
/// agree. The picture exports go through `MapRenderer`, which draws from the
/// same `MapLayout` the canvas uses but with Core Graphics instead of SwiftUI —
/// so an export is reproducible, testable, and does not need a window on screen.
enum MapExport {
    enum Format: String, CaseIterable, Identifiable {
        case png, pdf, markdown, opml
        var id: String { rawValue }

        var title: String {
            switch self {
            case .png: return "PNG Image"
            case .pdf: return "PDF"
            case .markdown: return "Markdown Outline"
            case .opml: return "OPML Outline"
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .pdf: return "pdf"
            case .markdown: return "md"
            case .opml: return "opml"
            }
        }

        var systemImage: String {
            switch self {
            case .png: return "photo"
            case .pdf: return "doc.richtext"
            case .markdown: return "text.alignleft"
            case .opml: return "list.bullet.indent"
            }
        }
    }

    /// Bytes for `format`, or nil when rendering failed.
    static func data(_ document: MindMapDocument, format: Format) -> Data? {
        switch format {
        case .png: return MapRenderer(document: document).pngData()
        case .pdf: return MapRenderer(document: document).pdfData()
        case .markdown: return markdown(document).data(using: .utf8)
        case .opml: return opml(document).data(using: .utf8)
        }
    }

    // MARK: Markdown

    /// The root becomes an `#` heading and everything under it a nested bullet
    /// list — the shape a Markdown reader expects, and the shape `OutlineText`
    /// parses straight back into a map.
    static func markdown(_ document: MindMapDocument, includeClosed: Bool = true) -> String {
        let root = document.root
        var out = "# " + OutlineText.title(of: root) + "\n"
        if !root.notes.isEmpty { out += "\n" + root.notes + "\n" }
        let body = root.children
            .filter { includeClosed || !$0.isClosed }
            .map { OutlineText.serialize($0, includeClosed: includeClosed, includeNotes: true) }
            .joined(separator: "\n")
        if !body.isEmpty { out += "\n" + body + "\n" }
        if !document.links.isEmpty {
            out += "\n## Connections\n\n"
            for link in document.links {
                guard let from = root.node(with: link.from),
                      let to = root.node(with: link.to) else { continue }
                let label = link.label.isEmpty ? "" : " — " + link.label
                out += "- \(OutlineText.title(of: from)) → \(OutlineText.title(of: to))\(label)\n"
            }
        }
        return out
    }

    // MARK: OPML

    /// OPML 2.0. Notes, tags, and due dates ride along as attributes so a
    /// round-trip through another outliner keeps more than the titles.
    static func opml(_ document: MindMapDocument, includeClosed: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>\(escape(OutlineText.title(of: document.root)))</title>
          </head>
          <body>

        """
        func walk(_ node: MindNode, indent: String) {
            if node.isClosed && !includeClosed { return }
            var attributes = "text=\"\(escape(OutlineText.title(of: node)))\""
            if !node.notes.isEmpty { attributes += " _note=\"\(escape(node.notes))\"" }
            if !node.tags.isEmpty { attributes += " _tags=\"\(escape(node.tags.joined(separator: ",")))\"" }
            if let due = node.dueDate { attributes += " _due=\"\(formatter.string(from: due))\"" }
            if let link = node.link, !link.isEmpty { attributes += " url=\"\(escape(link))\"" }
            if node.isClosed { attributes += " _status=\"closed\"" }
            let visible = node.children.filter { includeClosed || !$0.isClosed }
            if visible.isEmpty {
                out += indent + "<outline \(attributes)/>\n"
            } else {
                out += indent + "<outline \(attributes)>\n"
                visible.forEach { walk($0, indent: indent + "  ") }
                out += indent + "</outline>\n"
            }
        }
        walk(document.root, indent: "    ")
        out += """
          </body>
        </opml>

        """
        return out
    }

    /// XML-escapes text for use in an attribute value or element body.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Draws a whole map into a Core Graphics context.
///
/// Shares `MapLayout`, `Metrics`, and `Palette` with the live canvas, so an
/// export matches what is on screen without the canvas having to be on screen.
/// Always renders the entire document at 1:1 — export is not a screenshot.
struct MapRenderer {
    var document: MindMapDocument
    var padding: CGFloat = 40
    /// Exports always read as light-mode artwork: they end up in documents and
    /// slide decks, not in the app's own window.
    var backgroundColor: NSColor = .white

    private var layout: MapLayout { MapLayout(root: document.root) }

    /// World-space rectangle the export covers.
    func contentBounds(_ layout: MapLayout) -> CGRect {
        let bounds = layout.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return CGRect(x: -100, y: -60, width: 200, height: 120)
        }
        // Extra headroom at the top for due chips, which overhang their node.
        return bounds.insetBy(dx: -padding, dy: -padding)
    }

    // MARK: Output

    func pngData(scale: CGFloat = 2) -> Data? {
        let layout = self.layout
        let bounds = contentBounds(layout)
        let size = bounds.size
        let pixelsWide = max(1, Int((size.width * scale).rounded()))
        let pixelsHigh = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        withFlippedContext(base.cgContext, height: size.height) {
            draw(layout, bounds: bounds)
        }
        return rep.representation(using: .png, properties: [:])
    }

    func pdfData() -> Data? {
        let layout = self.layout
        let bounds = contentBounds(layout)
        let size = bounds.size
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        withFlippedContext(ctx, height: size.height) {
            draw(layout, bounds: bounds)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Runs `body` with a top-left-origin AppKit drawing context installed.
    ///
    /// Both the CTM flip *and* `NSGraphicsContext(cgContext:flipped:)` are
    /// needed: the transform puts the origin where layout coordinates expect
    /// it, and the flag tells AppKit's text and image drawing about it. Setting
    /// only one of the two silently draws everything upside down.
    private func withFlippedContext(_ ctx: CGContext, height: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.current?.flushGraphics()
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Drawing

    private func draw(_ layout: MapLayout, bounds: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        backgroundColor.setFill()
        CGRect(origin: .zero, size: bounds.size).fill()

        ctx.saveGState()
        // Layout is in world coordinates; shift so the content's top-left
        // corner is the page's top-left corner.
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)

        drawEdges(layout)
        drawLinks(layout)
        for id in layout.order {
            guard let geom = layout.nodes[id] else { continue }
            drawNode(geom)
        }
        ctx.restoreGState()
    }

    private func drawEdges(_ layout: MapLayout) {
        for edge in layout.edges {
            let path = NSBezierPath()
            path.move(to: edge.from)
            let dx = (edge.to.x - edge.from.x) * 0.5
            path.curve(to: edge.to,
                       controlPoint1: CGPoint(x: edge.from.x + dx, y: edge.from.y),
                       controlPoint2: CGPoint(x: edge.to.x - dx, y: edge.to.y))
            path.lineWidth = edge.level == 1 ? 3 : 2.2
            path.lineCapStyle = .round
            ns(edge.color).withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
    }

    private func drawLinks(_ layout: MapLayout) {
        for link in document.links {
            guard let a = layout.nodes[link.from], let b = layout.nodes[link.to] else { continue }
            let from = LinkCurve.anchor(on: a.rect, toward: CGPoint(x: b.rect.midX, y: b.rect.midY))
            let to = LinkCurve.anchor(on: b.rect, toward: CGPoint(x: a.rect.midX, y: a.rect.midY))
            let control = LinkCurve.control(from: from, to: to)
            let path = NSBezierPath()
            path.move(to: from)
            path.curve(to: to, controlPoint1: control, controlPoint2: control)
            path.lineWidth = 1.8
            path.setLineDash([6, 5], count: 2, phase: 0)
            ns(Palette.crossLink).setStroke()
            path.stroke()
            drawArrowHead(at: to, from: control)
            guard !link.label.isEmpty else { continue }
            let mid = LinkCurve.midpoint(from: from, to: to, control: control)
            drawLinkLabel(link.label, at: mid)
        }
    }

    private func drawArrowHead(at tip: CGPoint, from origin: CGPoint) {
        let dx = tip.x - origin.x, dy = tip.y - origin.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let size: CGFloat = 8
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: CGPoint(x: base.x - uy * size * 0.45, y: base.y + ux * size * 0.45))
        path.line(to: CGPoint(x: base.x + uy * size * 0.45, y: base.y - ux * size * 0.45))
        path.close()
        ns(Palette.crossLink).setFill()
        path.fill()
    }

    private func drawLinkLabel(_ label: String, at point: CGPoint) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let size = (label as NSString).size(withAttributes: [.font: font])
        let rect = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height / 2 - 3,
                          width: size.width + 12, height: size.height + 6)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        backgroundColor.setFill()
        pill.fill()
        ns(Palette.crossLink).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        (label as NSString).draw(
            at: CGPoint(x: rect.minX + 6, y: rect.minY + 3),
            withAttributes: [.font: font, .foregroundColor: ns(Palette.crossLink)]
        )
    }

    private func drawNode(_ geom: NodeGeom) {
        let rect = geom.rect
        let radius: CGFloat = geom.level == 0 ? 15 : (geom.level == 1 ? 12 : 10)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let color = ns(geom.color)

        switch geom.level {
        case 0:
            let isDefault = geom.color == Palette.root
            let top = isDefault ? ns(Palette.rootGradientTop) : color.blended(withFraction: 0.12, of: .white)!
            let bottom = isDefault ? ns(Palette.rootGradientBottom) : color.blended(withFraction: 0.08, of: .black)!
            NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -45)
        case 1:
            let top = color.blended(withFraction: 0.12, of: .white) ?? color
            let bottom = color.blended(withFraction: 0.05, of: .black) ?? color
            NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -45)
        default:
            NSColor.white.setFill()
            shape.fill()
            color.withAlphaComponent(0.5).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }

        let onFill = geom.level <= 1
        let textColor: NSColor = onFill ? .white : NSColor(white: 0.1, alpha: 1)
        let pad = Metrics.padding(for: geom.level)
        var y = rect.minY + pad.v

        if let stored = geom.image, let image = ImageStore.image(for: stored) {
            let size = stored.displaySize(maxWidth: Metrics.maxImageWidth)
            let frame = CGRect(x: rect.midX - size.width / 2, y: y,
                               width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
            image.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            y += size.height + Metrics.imageGap
        }

        let display = geom.text.isEmpty ? "Topic" : geom.text
        let textSize = Metrics.textSize(for: geom.text, level: geom.level)
        let iconWidth = (geom.icon?.isEmpty == false) ? Metrics.iconWidth(for: geom.level) : 0
        let titleWidth = textSize.width + (iconWidth > 0 ? iconWidth + Metrics.iconGap : 0)
        var x = rect.midX - titleWidth / 2

        if let icon = geom.icon, !icon.isEmpty {
            let font = NSFont.systemFont(ofSize: Metrics.fontSize(for: geom.level) * 1.15)
            (icon as NSString).draw(in: CGRect(x: x, y: y, width: iconWidth, height: textSize.height),
                                    withAttributes: [.font: font])
            x += iconWidth + Metrics.iconGap
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (display as NSString).draw(
            in: CGRect(x: x, y: y, width: textSize.width, height: textSize.height),
            withAttributes: [
                .font: Metrics.nsFont(for: geom.level),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
        )
        y += textSize.height

        let labels = Metrics.chipLabels(for: geom.tags, level: geom.level)
        if !labels.isEmpty {
            y += 4
            drawTagRow(labels, centerX: rect.midX, top: y, geom: geom)
        }

        if let due = geom.dueDate {
            drawDueChip(due, at: CGPoint(x: rect.minX + 4, y: rect.minY - 9))
        }
        if geom.progress.done > 0 {
            let inset: CGFloat = 6
            let center = geom.side == .right
                ? CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
                : CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)
            drawProgressRing(geom.progress, at: center)
        }
    }

    private func drawTagRow(_ labels: [String], centerX: CGFloat, top: CGFloat, geom: NodeGeom) {
        let font = NSFont.systemFont(ofSize: Metrics.metaFontSize, weight: .semibold)
        let widths = labels.map { Metrics.chipWidth($0, level: geom.level) }
        let total = widths.reduce(0, +) + CGFloat(labels.count - 1) * 4
        var x = centerX - total / 2
        let onFill = geom.level <= 1
        for (label, width) in zip(labels, widths) {
            let rect = CGRect(x: x, y: top, width: width, height: 15)
            let pill = NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5)
            (onFill ? NSColor.white.withAlphaComponent(0.22)
                    : NSColor.black.withAlphaComponent(0.06)).setFill()
            pill.fill()
            var textX = rect.minX + 7
            if geom.level >= 2 {
                let dot = CGRect(x: rect.minX + 6, y: rect.midY - 3, width: 6, height: 6)
                ns(geom.color).setFill()
                NSBezierPath(ovalIn: dot).fill()
                textX = dot.maxX + 4
            }
            (label as NSString).draw(
                at: CGPoint(x: textX, y: rect.minY + 2),
                withAttributes: [
                    .font: font,
                    .foregroundColor: onFill ? NSColor.white
                                             : NSColor.black.withAlphaComponent(0.75),
                ]
            )
            x += width + 4
        }
    }

    private func drawDueChip(_ date: Date, at origin: CGPoint) {
        let text = Metrics.dueString(date)
        let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 14, height: size.height + 5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let overdue = DayClock.isOverdue(date)
        (overdue ? NSColor.systemRed : NSColor(white: 0.35, alpha: 1)).setFill()
        pill.fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 2.5),
                                withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }

    /// The completion badge, matching `NodeView.progressBadge`: a filled disc,
    /// a track, the done/total arc, and the count (a checkmark once finished).
    private func drawProgressRing(_ progress: SubtreeProgress, at center: CGPoint) {
        let radius: CGFloat = 10
        let complete = progress.total > 0 && progress.done >= progress.total
        let disc = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        backgroundColor.setFill()
        disc.fill()

        let ringRadius = radius - 1.25
        let track = NSBezierPath(ovalIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                                width: ringRadius * 2, height: ringRadius * 2))
        NSColor.black.withAlphaComponent(0.12).setStroke()
        track.lineWidth = 2.5
        track.stroke()

        let sweep = 360 * min(1, max(0.02, progress.fraction))
        let arc = NSBezierPath()
        // Flipped context: a clockwise sweep on screen is an increasing angle
        // here, starting from straight up.
        arc.appendArc(withCenter: center, radius: ringRadius,
                      startAngle: -90, endAngle: -90 + sweep, clockwise: false)
        arc.lineWidth = 2.5
        arc.lineCapStyle = .round
        (complete ? ns(Palette.done) : NSColor(white: 0.42, alpha: 1)).setStroke()
        arc.stroke()

        let label = complete ? "\u{2713}" : "\(progress.done)"
        let font = NSFont.systemFont(ofSize: complete ? 9 : 8.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: complete ? ns(Palette.done) : NSColor(white: 0.12, alpha: 1),
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: CGPoint(x: center.x - size.width / 2,
                                             y: center.y - size.height / 2),
                                 withAttributes: attributes)
    }

    private func ns(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }
}
