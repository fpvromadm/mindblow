import AppKit
import XCTest
@testable import MindBlow

final class ExportTests: XCTestCase {
    private func sampleDocument() -> MindMapDocument {
        var root = MindNode(text: "Plan", icon: "🧠")
        var a = MindNode(text: "Research", tags: ["q3"])
        a.children = [MindNode(text: "Interviews"), MindNode(text: "Desk work", closedAt: Date())]
        let b = MindNode(text: "Build", notes: "the body")
        root.children = [a, b]
        var doc = MindMapDocument(root: root)
        doc.links = [MindLink(from: a.id, to: b.id, label: "feeds")]
        return doc
    }

    // MARK: Markdown

    func testMarkdownStartsWithTheRootAsAHeading() {
        let md = MapExport.markdown(sampleDocument())
        XCTAssertTrue(md.hasPrefix("# 🧠 Plan\n"), md)
    }

    func testMarkdownNestsChildrenAsBullets() {
        let md = MapExport.markdown(sampleDocument())
        XCTAssertTrue(md.contains("- Research #q3"), md)
        XCTAssertTrue(md.contains("  - Interviews"), md)
        XCTAssertTrue(md.contains("  - [x] Desk work"), md)
    }

    func testMarkdownCarriesNotesAndConnections() {
        let md = MapExport.markdown(sampleDocument())
        XCTAssertTrue(md.contains("the body"), md)
        XCTAssertTrue(md.contains("## Connections"), md)
        XCTAssertTrue(md.contains("Research → Build — feeds"), md)
    }

    func testMarkdownRoundTripsBackIntoTheSameShape() {
        let md = MapExport.markdown(sampleDocument(), includeClosed: false)
        // Drop the connections section — it is prose about the map, not part
        // of the outline.
        let outline = md.components(separatedBy: "## Connections")[0]
        let parsed = OutlineText.parse(outline)
        XCTAssertEqual(parsed.map(\.text), ["Plan"])
        XCTAssertEqual(parsed[0].children.map(\.text), ["Research", "Build"])
        XCTAssertEqual(parsed[0].children[0].children.map(\.text), ["Interviews"])
        // "the body" is Build's note, not a topic of its own.
        XCTAssertTrue(parsed[0].children[1].children.isEmpty,
                      "notes must not come back as topics")
    }

    // MARK: OPML

    func testOPMLIsWellFormedAndNested() throws {
        let opml = MapExport.opml(sampleDocument())
        XCTAssertTrue(opml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        let data = try XCTUnwrap(opml.data(using: .utf8))
        // XMLDocument is the real check: it fails on any malformed markup.
        let xml = try XMLDocument(data: data, options: [])
        XCTAssertEqual(try xml.nodes(forXPath: "//outline").count, 5)
        // Nesting, checked by path rather than by a flat list — XPath does not
        // promise document order for attribute nodes.
        XCTAssertEqual(try xml.nodes(forXPath: "/opml/body/outline/@text")
            .first?.stringValue, "🧠 Plan")
        XCTAssertEqual(try xml.nodes(forXPath: "/opml/body/outline/outline/@text")
            .map(\.stringValue).compactMap { $0 }.sorted(), ["Build", "Research"])
        XCTAssertEqual(try xml.nodes(forXPath: "/opml/body/outline/outline[@text='Research']/outline/@text")
            .map(\.stringValue).compactMap { $0 }.sorted(), ["Desk work", "Interviews"])
    }

    func testOPMLCarriesMetadataAttributes() throws {
        let data = try XCTUnwrap(MapExport.opml(sampleDocument()).data(using: .utf8))
        let xml = try XMLDocument(data: data, options: [])
        XCTAssertEqual(try xml.nodes(forXPath: "//outline[@text='Research']/@_tags")
            .first?.stringValue, "q3")
        XCTAssertEqual(try xml.nodes(forXPath: "//outline[@text='Build']/@_note")
            .first?.stringValue, "the body")
        XCTAssertEqual(try xml.nodes(forXPath: "//outline[@text='Desk work']/@_status")
            .first?.stringValue, "closed")
    }

    func testOPMLEscapesMarkupInTitles() throws {
        var root = MindNode(text: "a & b <c> \"d\"")
        root.children = []
        let opml = MapExport.opml(MindMapDocument(root: root))
        XCTAssertFalse(opml.contains("text=\"a & b"))
        let data = try XCTUnwrap(opml.data(using: .utf8))
        let xml = try XMLDocument(data: data, options: [])
        XCTAssertEqual(try xml.nodes(forXPath: "//outline/@text").first?.stringValue,
                       "a & b <c> \"d\"")
    }

    func testOPMLCanOmitClosedTopics() throws {
        let data = try XCTUnwrap(MapExport.opml(sampleDocument(), includeClosed: false)
            .data(using: .utf8))
        let xml = try XMLDocument(data: data, options: [])
        let titles = try xml.nodes(forXPath: "//outline/@text").map(\.stringValue)
        XCTAssertFalse(titles.contains("Desk work"))
    }

    // MARK: Image rendering

    func testPNGRendersAtTwiceTheLayoutSize() throws {
        let doc = sampleDocument()
        let renderer = MapRenderer(document: doc)
        let bounds = renderer.contentBounds(MapLayout(root: doc.root))
        let data = try XCTUnwrap(renderer.pngData(scale: 2))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, Int((bounds.width * 2).rounded()))
        XCTAssertEqual(image.pixelsHigh, Int((bounds.height * 2).rounded()))
    }

    func testPNGActuallyDrawsSomething() throws {
        let data = try XCTUnwrap(MapRenderer(document: sampleDocument()).pngData(scale: 1))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        // The background is white; a rendered map has to put ink on it.
        var inked = 0
        for x in stride(from: 0, to: image.pixelsWide, by: 3) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 3) {
                guard let color = image.colorAt(x: x, y: y) else { continue }
                if color.brightnessComponent < 0.9 { inked += 1 }
            }
        }
        XCTAssertGreaterThan(inked, 100, "expected the map to be drawn, not a blank page")
    }

    func testPDFIsAValidSinglePageDocument() throws {
        let data = try XCTUnwrap(MapRenderer(document: sampleDocument()).pdfData())
        let pdf = try XCTUnwrap(PDFDocumentShim(data: data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertGreaterThan(pdf.mediaBox.width, 100)
    }

    func testAnEmptyMapStillRenders() throws {
        let doc = MindMapDocument(root: MindNode(text: ""))
        XCTAssertNotNil(MapRenderer(document: doc).pngData(scale: 1))
        XCTAssertNotNil(MapRenderer(document: doc).pdfData())
    }

    func testEveryFormatProducesData() {
        let doc = sampleDocument()
        for format in MapExport.Format.allCases {
            XCTAssertNotNil(MapExport.data(doc, format: format), "\(format) produced nothing")
        }
    }

    /// Renders a map exercising every visual feature. Set `MINDBLOW_EXPORT_DIR`
    /// to also drop the files somewhere you can look at them — the renderer
    /// shares its layout with the canvas, so this is the closest thing to a
    /// screenshot that does not need a window.
    func testRichMapRendersEveryFeature() throws {
        var swatch = NSImage(size: NSSize(width: 240, height: 150))
        swatch.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 150).fill()
        NSColor.white.setFill()
        NSRect(x: 30, y: 30, width: 90, height: 90).fill()
        swatch.unlockFocus()
        swatch = NSImage(data: swatch.tiffRepresentation!) ?? swatch
        let picture = try XCTUnwrap(ImageStore.prepare(swatch))

        var research = MindNode(text: "Research", tags: ["q3", "team", "extra"], icon: "🔬")
        research.children = [
            MindNode(text: "Interviews", dueDate: Date().addingTimeInterval(86_400 * 3)),
            MindNode(text: "Desk work", closedAt: Date()),
            MindNode(text: "Survey", icon: "📊", closedAt: Date()),
        ]
        var build = MindNode(text: "Build", notes: "notes body", icon: "🔧")
        build.children = [
            MindNode(text: "Prototype", image: picture),
            MindNode(text: "Ship it", dueDate: Date().addingTimeInterval(-86_400)),
        ]
        var launch = MindNode(text: "Launch", side: .left, icon: "🚀")
        launch.children = [MindNode(text: "Press"), MindNode(text: "Docs")]

        var root = MindNode(text: "Product Plan", icon: "🧠")
        root.children = [research, build, launch]
        var doc = MindMapDocument(root: root)
        doc.links = [
            MindLink(from: research.id, to: build.id, label: "feeds"),
            MindLink(from: build.id, to: launch.id, label: ""),
        ]

        let png = try XCTUnwrap(MapRenderer(document: doc).pngData(scale: 2))
        let pdf = try XCTUnwrap(MapRenderer(document: doc).pdfData())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThan(rep.pixelsWide, 400)
        XCTAssertGreaterThan(rep.pixelsHigh, 300)

        guard let dir = ProcessInfo.processInfo.environment["MINDBLOW_EXPORT_DIR"] else { return }
        let base = URL(fileURLWithPath: dir)
        try png.write(to: base.appendingPathComponent("sample.png"))
        try pdf.write(to: base.appendingPathComponent("sample.pdf"))
        try XCTUnwrap(MapExport.markdown(doc).data(using: .utf8))
            .write(to: base.appendingPathComponent("sample.md"))
        try XCTUnwrap(MapExport.opml(doc).data(using: .utf8))
            .write(to: base.appendingPathComponent("sample.opml"))
    }
}

/// Minimal PDF reader so the test target does not need PDFKit.
private struct PDFDocumentShim {
    let pageCount: Int
    let mediaBox: CGRect

    init?(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return nil }
        pageCount = document.numberOfPages
        mediaBox = document.page(at: 1)?.getBoxRect(.mediaBox) ?? .zero
    }
}
