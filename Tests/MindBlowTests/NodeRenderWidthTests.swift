import XCTest
import SwiftUI
import AppKit
@testable import MindBlow

/// Hosts the real `NodeView` offscreen and measures the bubble it actually
/// draws, so the "line stops short of the node" bug is checked against the
/// view rather than against a re-derivation of its arithmetic.
final class NodeRenderWidthTests: XCTestCase {

    private func geometry(text: String, zoom: CGFloat) -> NodeGeom {
        var node = MindNode(text: text)
        node.side = .right
        var root = MindNode(text: "Root")
        root.children = [node]
        let layout = MapLayout(root: root)
        return layout.nodes[node.id]!
    }

    private func drawnSize(text: String, zoom: CGFloat) -> CGSize {
        let geom = geometry(text: text, zoom: zoom)
        let view = NodeView(
            geom: geom,
            zoom: zoom,
            isSelected: false,
            isHovered: false,
            anyDragActive: false,
            dropMode: nil,
            editingDraft: nil,
            datePickerShown: false,
            draft: .constant(""),
            actions: .noop
        )
        let host = NSHostingView(rootView: view)
        return host.fittingSize
    }

    private func drawnWidth(text: String, zoom: CGFloat) -> CGFloat {
        drawnSize(text: text, zoom: zoom).width
    }

    /// The label that showed the gap, at the zooms a user actually lands on.
    func testDrawnBubbleFillsItsLayoutRect() {
        let text = "Azorra, Claim creation from Assembly Event fails"
        for zoom in [CGFloat(0.5), 0.75, 0.8, 0.9, 1, 1.25, 1.5] {
            let geom = geometry(text: text, zoom: zoom)
            let reserved = geom.rect.width * zoom
            let drawn = drawnWidth(text: text, zoom: zoom)
            // A bubble narrower than its rect leaves the branch line hanging in
            // space; half the shortfall is the visible gap on the near edge.
            XCTAssertEqual(drawn, reserved, accuracy: 1.5,
                           "at zoom \(zoom) the bubble is \(reserved - drawn)pt "
                           + "narrower than its rect — a \((reserved - drawn) / 2)pt gap")
        }
    }

    /// The zoom-out counterpart. Glyph advances grow relative to point size as
    /// the font shrinks, so a label set at `size * zoom` needs more than
    /// `width * zoom` — rendered into the scaled rect it re-wraps ("Strategy
    /// Deck" onto two lines, "Documentation" broken mid-word) and the bubble
    /// outgrows the rect its siblings were spaced around.
    func testBubbleKeepsItsRectHeightWhenZoomedOut() {
        let texts = ["Strategy Deck", "Documentation", "Support", "Roadmap",
                     "2026 Aug Sharepoint Integration"]
        for text in texts {
            for zoom in [CGFloat(0.25), 0.35, 0.5, 0.6, 0.75, 0.85] {
                let geom = geometry(text: text, zoom: zoom)
                let reserved = geom.rect.height * zoom
                let drawn = drawnSize(text: text, zoom: zoom).height
                XCTAssertEqual(drawn, reserved, accuracy: 2,
                               "\"\(text)\" at zoom \(zoom) draws \(drawn)pt tall "
                               + "into a \(reserved)pt rect — the label re-wrapped")
            }
        }
    }

    func testShortLabelsAlsoFillTheirRect() {
        for text in ["Support", "Managed fields missing", "2026 Aug Sharepoint Integration"] {
            for zoom in [CGFloat(0.75), 1, 1.5] {
                let reserved = geometry(text: text, zoom: zoom).rect.width * zoom
                XCTAssertEqual(drawnWidth(text: text, zoom: zoom), reserved, accuracy: 1.5,
                               "\(text) at zoom \(zoom)")
            }
        }
    }
}

private extension NodeView.Actions {
    /// Every closure a hosted node needs, all inert.
    static var noop: NodeView.Actions {
        NodeView.Actions(
            toggleCollapse: {},
            prepareCollapseToggle: {},
            addChild: {},
            expandCollapsedDue: { _ in },
            openLink: { _ in },
            showNotes: {},
            setDatePickerShown: { _ in },
            setDueDate: { _ in },
            removeDueDate: {},
            affordanceHoverChanged: { _ in },
            commit: { _ in },
            commitAndAddChild: { _ in },
            cancelEditing: {},
            closedChildren: { [] },
            reopenClosedChild: { _ in },
            reopenAllClosed: {},
            revealClosedInOutline: { _ in },
            setClosedPopoverShown: { _ in }
        )
    }
}
