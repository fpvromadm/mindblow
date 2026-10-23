import SwiftUI

/// The one canonical tag pill. The inspector tag list and the filter bar both
/// render through this, so a filter chip is visually identical to the chip a
/// topic carries in the details panel. (The on-canvas `metaChip` in NodeView
/// is a separate, zoom-scaled variant — it lives and dies with the layout.)
struct TagChip: View {
    enum Style {
        /// Editable chip in the details panel: carries a remove control.
        case inspector
        /// Toggleable chip in the filter bar: filled when selected.
        case filter
    }

    var text: String
    /// Leading dot color. Filter chips pass a neutral color — a tag spans many
    /// differently-colored topics, so no single node hue is honest there.
    var color: Color
    var style: Style
    var isSelected: Bool = false
    /// Trailing ✕; when set the chip shows a remove button (inspector).
    var onRemove: (() -> Void)? = nil
    /// Whole-chip tap (filter toggle). When set the chip is a button.
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { pill }
                .buttonStyle(.chip)
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isSelected ? Color.white : color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8))
                                                    : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.nodeBadge)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(isSelected ? Palette.selection : Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule().stroke(isSelected ? Color.clear : Color.primary.opacity(0.09), lineWidth: 1)
        )
        .fixedSize()
    }
}
