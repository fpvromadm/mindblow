import CoreGraphics

/// How the topic inspector divides itself between its cards and the notes
/// editor, and what order the cards come in.
enum InspectorLayout {
    /// The cards, in the order they appear. Ordered by what you reach for:
    /// closing a topic and its due date and tags are acts, while its colour and
    /// icon are decoration. Decoration used to hold the top of the panel and
    /// push Close/Reopen — the last card — off the bottom.
    enum Card: CaseIterable {
        case closed, dueDate, tags, link, connections, color, iconImage
    }

    static let cardOrder: [Card] = [
        .closed, .dueDate, .tags, .link, .connections, .color, .iconImage,
    ]

    /// Height of the collapsed notes section: its eyebrow plus a single line
    /// inviting you to write.
    static let collapsedNotesHeight: CGFloat = 64

    /// Height the notes section should take.
    ///
    /// Notes earn their space. An empty, unfocused box collapses to a one-line
    /// affordance so the cards get the panel; the moment it holds text or takes
    /// focus it expands to its full share, so there is always room to write in.
    static func notesHeight(panelHeight: CGFloat, hasText: Bool, isFocused: Bool) -> CGFloat {
        guard hasText || isFocused else { return min(collapsedNotesHeight, panelHeight / 2) }
        // Never so tall that the cards lose their scroll area.
        return min(max(200, panelHeight * 0.45), max(140, panelHeight - 170), panelHeight / 2)
    }
}
