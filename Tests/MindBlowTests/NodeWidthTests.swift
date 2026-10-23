import XCTest
import SwiftUI
@testable import MindBlow

/// The layout sizes every node from a scale-1 text measurement and scales the
/// rect by zoom. NodeView used to re-measure at `scale: zoom`, which multiplies
/// the *wrap width* by zoom too — so any label long enough to reach
/// `Metrics.maxTextWidth` re-wrapped into different lines and came out much
/// narrower than the rect it was centred in. The branch line, which ends at
/// `rect.minX`, then visibly stopped short of the bubble.
final class NodeWidthTests: XCTestCase {
    /// Exactly the label that showed the gap: 241pt at scale 1, so it sits on
    /// the 240pt wrap cap and re-wraps as soon as the cap is scaled.
    private let wrapped = "Azorra, Claim creation from Assembly Event fails"
    private let zooms: [CGFloat] = [0.25, 0.5, 0.75, 0.8, 0.9, 1, 1.2, 1.5, 2.5]

    func testWrappedTextIsDrawnAtTheWidthTheLayoutReserved() {
        let reserved = Metrics.textSize(for: wrapped, level: 2).width
        for zoom in zooms {
            let drawn = Metrics.displayTextWidth(for: wrapped, level: 2, zoom: zoom)
            XCTAssertEqual(drawn / zoom, reserved, accuracy: 0.5,
                           "at zoom \(zoom) the bubble is drawn "
                           + "\(reserved - drawn / zoom)pt narrower than its rect")
        }
    }

    func testShortTextIsUnaffected() {
        for text in ["Support", "CSM/PM procedure", "Managed fields missing"] {
            let reserved = Metrics.textSize(for: text, level: 2).width
            for zoom in zooms {
                XCTAssertEqual(Metrics.displayTextWidth(for: text, level: 2, zoom: zoom) / zoom,
                               reserved, accuracy: 0.5)
            }
        }
    }

    /// Why `displayTextWidth` exists at all: measuring per-zoom really does
    /// diverge, so this must keep failing the naive way.
    func testPerZoomMeasurementDivergesForWrappedText() {
        let reserved = Metrics.textSize(for: wrapped, level: 2).width
        let perZoom = Metrics.textSize(for: wrapped, level: 2, scale: 0.8).width
        XCTAssertLessThan(perZoom, reserved * 0.8 - 20,
                          "if this stops diverging the bug it guards is gone")
    }
}
