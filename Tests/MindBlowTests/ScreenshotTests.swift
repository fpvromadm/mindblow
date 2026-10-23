import AppKit
import SwiftUI
import XCTest
@testable import MindBlow

/// Renders the README screenshots from a seeded demo map, through the real
/// `EditorView` hosted in an offscreen window. Off unless
/// `MINDBLOW_SCREENSHOT_DIR` is set:
///
///     MINDBLOW_SCREENSHOT_DIR=docs/screenshots swift test --filter ScreenshotTests
final class ScreenshotTests: XCTestCase {
    private var outputDir: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["MINDBLOW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set MINDBLOW_SCREENSHOT_DIR to render screenshots")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func testMap() throws {
        let doc = DemoMap.trip()
        try snapshot(doc, name: "map", appearance: .aqua,
                     presentation: .init(selection: doc.root.id))
    }

    func testDetailsDark() throws {
        let doc = DemoMap.trip()
        // Content only: offscreen, the toolbar's glass buttons draw in their
        // light style whatever the appearance.
        try snapshot(doc, name: "details-dark", appearance: .darkAqua,
                     presentation: .init(selection: DemoMap.find("Ryokan in Hakone", in: doc),
                                         showNotes: true),
                     includeChrome: false)
    }

    func testOutline() throws {
        let doc = DemoMap.trip()
        try snapshot(doc, name: "outline", appearance: .aqua,
                     presentation: .init(viewMode: .outline,
                                         selection: DemoMap.find("Kyoto", in: doc)),
                     size: NSSize(width: 1320, height: 640))
    }

    func testAgendaAndTagFilter() throws {
        let doc = DemoMap.trip()
        try snapshot(doc, name: "agenda", appearance: .aqua,
                     presentation: .init(selection: DemoMap.find("JR Pass — 14 days", in: doc),
                                         showAgenda: true, showFilterBar: true,
                                         activeTags: ["booking"]))
    }

    private func snapshot(_ document: MindMapDocument, name: String,
                          appearance: NSAppearance.Name,
                          presentation: EditorView.Presentation,
                          size: NSSize = NSSize(width: 1320, height: 820),
                          includeChrome: Bool = true) throws {
        var doc = document
        let binding = Binding(get: { doc }, set: { doc = $0 })
        let host = NSHostingView(rootView: EditorView(document: binding, presentation: presentation))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The toolbar's materials follow the app's appearance, not the window's.
        NSApp.appearance = NSAppearance(named: appearance)
        window.appearance = NSAppearance(named: appearance)
        window.title = "Japan Trip"
        window.toolbarStyle = .unified
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        // Restore for the next case, which may be in the other appearance.
        defer { NSApp.appearance = nil }

        let frameView = try XCTUnwrap(includeChrome ? window.contentView?.superview : host)
        let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        window.close()
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try png.write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        try encodeWebP(raw, to: outputDir.appendingPathComponent("\(name).webp"))
    }

    /// The raw Retina capture is ~1.3 MB a shot. 1600px wide still covers the
    /// README column at 2x, and lossy WebP keeps text crisp at ~50 KB.
    private func encodeWebP(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["cwebp", "-quiet", "-resize", "1600", "0", "-q", "82", "-m", "6",
                             "-sharp_yuv", source.path, "-o", destination.path]
        do { try process.run() } catch {
            throw XCTSkip("cwebp not found — brew install webp")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("cwebp not found or failed (status \(process.terminationStatus)) — brew install webp")
        }
    }
}

/// The seeded demo content. Due dates are relative to today so the agenda
/// always reads as current.
enum DemoMap {
    static func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset,
                              to: Calendar.current.startOfDay(for: Date()))!
    }

    static func find(_ text: String, in doc: MindMapDocument) -> UUID? {
        func walk(_ node: MindNode) -> UUID? {
            node.text == text ? node.id : node.children.lazy.compactMap(walk).first
        }
        return walk(doc.root)
    }

    /// A branch and everything under it in one palette color, so each branch
    /// reads as its own strand.
    private static func branch(_ text: String, icon: String, color: Int,
                               _ children: [MindNode]) -> MindNode {
        func paint(_ node: MindNode) -> MindNode {
            var n = node
            n.colorIndex = color
            n.children = n.children.map(paint)
            return n
        }
        return paint(MindNode(text: text, icon: icon, children: children))
    }

    static func trip() -> MindMapDocument {
        let done = day(-3)

        let ryokanNotes = """
        ## Hakone Ginyu
        Two nights, **private onsen** on the balcony.

        - [x] Compare three ryokans
        - [ ] Pay the deposit
        - [ ] Ask about a vegetarian kaiseki

        Check-in from 3 pm.
        """

        let plan = branch("Plan", icon: "🗺️", color: 0, [
            MindNode(text: "Book flights", tags: ["booking"], closedAt: done),
            MindNode(text: "JR Pass — 14 days", dueDate: day(-1), tags: ["booking"]),
            MindNode(text: "Ryokan in Hakone", notes: ryokanNotes, dueDate: day(4),
                     link: "https://www.japan-guide.com/e/e5200.html", tags: ["booking", "splurge"]),
            MindNode(text: "Renew passport", closedAt: done),
        ])
        let tokyo = branch("Tokyo", icon: "🗼", color: 1, [
            MindNode(text: "Shibuya Crossing at night"),
            MindNode(text: "teamLab Planets", dueDate: day(12), tags: ["tickets"]),
            MindNode(text: "Tsukiji outer market", tags: ["food"]),
            MindNode(text: "Day trip to Nikko"),
        ])
        let kyoto = branch("Kyoto", icon: "⛩️", color: 4, [
            MindNode(text: "Fushimi Inari at sunrise"),
            MindNode(text: "Arashiyama bamboo grove"),
            MindNode(text: "Tea ceremony in Gion", dueDate: day(15), tags: ["tickets"]),
        ])
        let eat = branch("Eat", icon: "🍜", color: 2, [
            MindNode(text: "Ramen in Shinjuku", tags: ["food"]),
            MindNode(text: "Kaiseki dinner", tags: ["food", "splurge"]),
            MindNode(text: "Osaka street food", tags: ["food"]),
        ])
        let budget = branch("Budget", icon: "💴", color: 3, [
            MindNode(text: "Flights ¥180k", closedAt: done),
            MindNode(text: "Hotels ¥240k"),
            MindNode(text: "Food & fun ¥120k"),
        ])
        let pack = branch("Pack", icon: "🎒", color: 5, [
            MindNode(text: "Pocket Wi-Fi", dueDate: day(0), tags: ["booking"]),
            MindNode(text: "IC card (Suica)"),
            MindNode(text: "Comfy shoes", closedAt: done),
        ])

        let root = MindNode(text: "Japan Trip", icon: "🇯🇵",
                            children: [plan, tokyo, kyoto, eat, budget, pack])
        let links = [
            MindLink(from: plan.children[1].id, to: kyoto.id, label: "Shinkansen"),
        ]
        return MindMapDocument(root: root, links: links)
    }
}
