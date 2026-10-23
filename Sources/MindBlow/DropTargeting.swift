import CoreGraphics
import Foundation

/// Resolves a pointer position on the canvas to a drop target.
///
/// Siblings are spaced by `Metrics.vGap` between their *subtree spans*, not
/// between their rects, so on any map whose branches have children the gap
/// between two sibling rects is many times the height of a node. Asking only
/// whether the pointer sits inside a rect therefore left most of a sibling
/// column dead: a drop in the gap resolved to nothing and fell through to
/// "move this branch to that side" instead of reordering. With three children
/// per branch only 15% of the column responded, and with eight, 5%.
///
/// So a node claims a *lane* — its horizontal span, widened a little. Anywhere
/// in a lane resolves to the vertically nearest node in it, which makes the
/// whole column live however far apart the branches sit. Landing inside a node
/// still re-parents into it, and a pointer in no lane at all still resolves to
/// nothing, so dropping past the root keeps meaning "swap sides".
enum DropTargeting {
    /// Fraction of a node's height at each end that inserts beside it rather
    /// than re-parenting into it.
    static let edgeBand: CGFloat = 0.28
    /// Slack around a node's own rect that still counts as a direct hit.
    static let hitMargin = CGSize(width: 6, height: 8)
    /// How far past its left and right edges a node's lane reaches. Kept under
    /// half of `Metrics.hGap` so two neighbouring levels can never share a lane.
    static let laneMargin: CGFloat = 24

    /// - Parameters:
    ///   - order: every placed node, parents before children (`MapLayout.order`).
    ///   - rootID: the node acting as the map's root; it has no siblings to sit
    ///     beside, so it can only ever be a parent.
    ///   - excluding: the dragged node and its subtree — never a target.
    ///   - rect: each node's rect in the same space as `point`.
    static func indicator(
        at point: CGPoint,
        order: [UUID],
        rootID: UUID,
        excluding: Set<UUID>,
        rect: (UUID) -> CGRect?
    ) -> DropIndicator? {
        // Best lane candidate so far: vertical distance to its rect, and which
        // side of it the pointer is on.
        var nearest: (id: UUID, distance: CGFloat, above: Bool)?

        // Topmost first, so an overlapping node wins the direct hit.
        for id in order.reversed() {
            guard !excluding.contains(id), let box = rect(id) else { continue }

            if box.insetBy(dx: -hitMargin.width, dy: -hitMargin.height).contains(point) {
                guard id != rootID else { return DropIndicator(id: id, mode: .child) }
                if point.y < box.minY + box.height * edgeBand {
                    return DropIndicator(id: id, mode: .before)
                }
                if point.y > box.maxY - box.height * edgeBand {
                    return DropIndicator(id: id, mode: .after)
                }
                return DropIndicator(id: id, mode: .child)
            }

            guard id != rootID,
                  point.x >= box.minX - laneMargin,
                  point.x <= box.maxX + laneMargin
            else { continue }

            let distance = point.y < box.minY
                ? box.minY - point.y
                : (point.y > box.maxY ? point.y - box.maxY : 0)
            if nearest == nil || distance < nearest!.distance {
                nearest = (id, distance, point.y < box.midY)
            }
        }

        guard let nearest else { return nil }
        return DropIndicator(id: nearest.id, mode: nearest.above ? .before : .after)
    }
}
