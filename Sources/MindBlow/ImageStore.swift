import AppKit
import UniformTypeIdentifiers

/// Import and caching for topic images.
///
/// Two jobs, both about keeping the document cheap. `prepare` downscales and
/// re-encodes on the way in, because a `.mindblow` file carries its pictures
/// inline as base64 — a 12MP phone photo pasted onto a topic would otherwise
/// turn a 40KB map into a 20MB one, and every undo step would copy it. `image`
/// memoizes the decode, because layout and rendering ask for the same picture
/// many times per frame and `NSImage(data:)` is not free.
enum ImageStore {
    /// Longest edge kept on import. A topic bubble never shows an image wider
    /// than `Metrics.maxImageWidth` (240pt), so 640px still has headroom for a
    /// Retina render and for a PDF export at 2×.
    static let maxPixelEdge: CGFloat = 640
    static let jpegQuality: CGFloat = 0.8

    // MARK: Import

    /// Downscales and re-encodes `image` for storage. Returns nil when the
    /// image can't be rasterized at all.
    static func prepare(_ image: NSImage) -> NodeImage? {
        guard let source = bitmap(from: image) else { return nil }
        let scaled = downscale(source) ?? source
        // Alpha has to survive — a logo re-encoded as JPEG picks up a black box.
        let opaque = !scaled.hasAlpha
        let type: NSBitmapImageRep.FileType = opaque ? .jpeg : .png
        let props: [NSBitmapImageRep.PropertyKey: Any] =
            opaque ? [.compressionFactor: jpegQuality] : [:]
        guard let data = scaled.representation(using: type, properties: props) else { return nil }
        return NodeImage(data: data,
                         pixelWidth: scaled.pixelsWide,
                         pixelHeight: scaled.pixelsHigh)
    }

    /// Reads a file from disk and prepares it.
    static func prepare(contentsOf url: URL) -> NodeImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return prepare(image)
    }

    /// Whatever image is on the pasteboard, prepared for storage.
    static func prepareFromPasteboard(_ pasteboard: NSPasteboard = .general) -> NodeImage? {
        if let url = pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingContentsConformToTypes:
                                                        [UTType.image.identifier]]) as? [URL],
           let first = url.first, let prepared = prepare(contentsOf: first) {
            return prepared
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return prepare(image)
    }

    /// A bitmap of `image` at its own pixel size. Going through a rep rather
    /// than `image.tiffRepresentation` keeps vector sources (PDF, SVG) from
    /// rasterizing at their tiny natural size.
    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return rep
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Returns a rep no larger than `maxPixelEdge` on its long side, or nil if
    /// the source is already small enough.
    private static func downscale(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let longest = max(w, h)
        guard longest > maxPixelEdge, longest > 0 else { return nil }
        let scale = maxPixelEdge / longest
        let width = max(1, Int((w * scale).rounded()))
        let height = max(1, Int((h * scale).rounded()))
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        target.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: target)
        ctx?.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        rep.draw(in: CGRect(x: 0, y: 0, width: width, height: height),
                 from: .zero, operation: .copy, fraction: 1,
                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        return target
    }

    // MARK: Cache

    /// Keyed by the stored image's id, which is minted fresh whenever the bytes
    /// change — so a hit is always the right picture without hashing megabytes.
    private static var cache: [UUID: NSImage] = [:]
    private static var order: [UUID] = []
    private static let maxCached = 120

    static func image(for stored: NodeImage) -> NSImage? {
        if let hit = cache[stored.id] { return hit }
        guard let decoded = NSImage(data: stored.data) else { return nil }
        cache[stored.id] = decoded
        order.append(stored.id)
        while order.count > maxCached {
            cache.removeValue(forKey: order.removeFirst())
        }
        return decoded
    }
}
