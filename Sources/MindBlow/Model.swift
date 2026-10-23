import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tree model

/// Which side of the root a top-level branch sits on; nil = auto-balance.
enum BranchSide: String, Codable {
    case left, right
}

/// A picture attached to a topic.
///
/// The bytes live in the document itself (base64 in the JSON) rather than
/// beside it, so a `.mindblow` file stays a single self-contained thing you can
/// mail, diff, or drop in a repo. That is only affordable because everything is
/// downscaled on import — see `ImageStore.prepare`.
struct NodeImage: Codable, Equatable {
    /// Cache key for the decoded `NSImage`. Stable across saves; a fresh id is
    /// minted whenever the bytes change.
    var id: UUID
    var data: Data
    /// Intrinsic pixel size, stored so layout never has to decode the image.
    var pixelWidth: Int
    var pixelHeight: Int

    init(id: UUID = UUID(), data: Data, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Compares by identity, not by bytes. `id` is minted fresh whenever the
    /// data changes, so this is exact — and it keeps the document equality
    /// check (which runs on every body evaluation and every undo registration)
    /// from memcmp-ing megabytes of image data per frame.
    static func == (lhs: NodeImage, rhs: NodeImage) -> Bool {
        lhs.id == rhs.id && lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
    }

    /// Aspect-preserving display size for a given width cap.
    func displaySize(maxWidth: CGFloat) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let aspect = CGFloat(pixelHeight) / CGFloat(pixelWidth)
        let width = min(maxWidth, CGFloat(pixelWidth))
        return CGSize(width: width, height: (width * aspect).rounded())
    }
}

struct MindNode: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String = ""
    var isCollapsed: Bool = false
    /// Palette override; nil means the level default.
    var colorIndex: Int? = nil
    /// Markdown notes attached to the topic.
    var notes: String = ""
    var dueDate: Date? = nil
    /// External link attached to the topic.
    var link: String? = nil
    var tags: [String] = []
    var side: BranchSide? = nil
    /// Emoji shown before the title. A string rather than a Character so a
    /// multi-scalar emoji (flags, skin tones, ZWJ families) survives intact.
    var icon: String? = nil
    var image: NodeImage? = nil
    /// When the topic was closed; nil means open. Descendants of a closed
    /// node are closed implicitly and are never stamped, so reopening the
    /// ancestor restores the subtree exactly as it was.
    var closedAt: Date? = nil
    var children: [MindNode] = []

    init(id: UUID = UUID(), text: String = "", isCollapsed: Bool = false,
         colorIndex: Int? = nil, notes: String = "", dueDate: Date? = nil,
         link: String? = nil, tags: [String] = [], side: BranchSide? = nil,
         icon: String? = nil, image: NodeImage? = nil,
         closedAt: Date? = nil, children: [MindNode] = []) {
        self.id = id
        self.text = text
        self.isCollapsed = isCollapsed
        self.colorIndex = colorIndex
        self.notes = notes
        self.dueDate = dueDate
        self.link = link
        self.tags = tags
        self.side = side
        self.icon = icon
        self.image = image
        self.closedAt = closedAt
        self.children = children
    }

    enum CodingKeys: String, CodingKey {
        case id, text, isCollapsed, colorIndex, notes, dueDate, link, tags, side,
             icon, image, closedAt, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        side = try c.decodeIfPresent(BranchSide.self, forKey: .side)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        image = try c.decodeIfPresent(NodeImage.self, forKey: .image)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        children = try c.decodeIfPresent([MindNode].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(isCollapsed, forKey: .isCollapsed)
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        try c.encodeIfPresent(dueDate, forKey: .dueDate)
        if let link, !link.isEmpty { try c.encode(link, forKey: .link) }
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        try c.encodeIfPresent(side, forKey: .side)
        if let icon, !icon.isEmpty { try c.encode(icon, forKey: .icon) }
        try c.encodeIfPresent(image, forKey: .image)
        try c.encodeIfPresent(closedAt, forKey: .closedAt)
        try c.encode(children, forKey: .children)
    }
}

/// A non-hierarchical connection between two topics — "this relates to that".
///
/// Stored on the document rather than on either node: an edge is not owned by
/// its endpoints, and hanging it off one of them would either duplicate it or
/// silently lose it when that subtree is moved or copied.
struct MindLink: Identifiable, Codable, Equatable {
    var id: UUID
    var from: UUID
    var to: UUID
    var label: String

    init(id: UUID = UUID(), from: UUID, to: UUID, label: String = "") {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
    }

    func touches(_ ids: Set<UUID>) -> Bool {
        ids.contains(from) || ids.contains(to)
    }
}

extension MindNode {
    var isClosed: Bool { closedAt != nil }
    var openChildren: [MindNode] { children.filter { !$0.isClosed } }
    var closedChildren: [MindNode] { children.filter(\.isClosed) }

    /// Size of the open subtree, counting through collapsed branches. Side
    /// balancing weighs branches by this rather than by their on-screen span
    /// so that folding a branch can never re-decide which side anything sits
    /// on — the thing that used to make branches jump across the root.
    var openWeight: Int {
        openChildren.reduce(1) { $0 + $1.openWeight }
    }

    func node(with id: UUID) -> MindNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.node(with: id) { return found }
        }
        return nil
    }

    /// Nodes from self down to the node with `id`, inclusive.
    func path(to id: UUID) -> [MindNode]? {
        if self.id == id { return [self] }
        for child in children {
            if let sub = child.path(to: id) { return [self] + sub }
        }
        return nil
    }

    func parentID(of id: UUID) -> UUID? {
        if children.contains(where: { $0.id == id }) { return self.id }
        for child in children {
            if let found = child.parentID(of: id) { return found }
        }
        return nil
    }

    @discardableResult
    mutating func update(_ id: UUID, _ change: (inout MindNode) -> Void) -> Bool {
        if self.id == id {
            change(&self)
            return true
        }
        for i in children.indices {
            if children[i].update(id, change) { return true }
        }
        return false
    }

    mutating func remove(_ id: UUID) {
        children.removeAll { $0.id == id }
        for i in children.indices {
            children[i].remove(id)
        }
    }

    /// Every id in this subtree, including this node's own.
    var subtreeIDs: Set<UUID> {
        var ids: Set<UUID> = []
        func walk(_ n: MindNode) {
            ids.insert(n.id)
            n.children.forEach(walk)
        }
        walk(self)
        return ids
    }

    /// Number of nodes in this subtree, including this one.
    var subtreeCount: Int {
        children.reduce(1) { $0 + $1.subtreeCount }
    }

    /// Fresh ids for this node and everything under it. Used when pasting a
    /// copied subtree so the copy can live alongside its original instead of
    /// colliding with it (every lookup in this app is by id).
    func rekeyed() -> MindNode {
        var copy = self
        copy.id = UUID()
        if var image = copy.image {
            image.id = UUID()
            copy.image = image
        }
        copy.children = children.map { $0.rekeyed() }
        return copy
    }
}

/// How much of a branch is finished.
struct SubtreeProgress: Equatable {
    var done: Int
    var total: Int

    var isEmpty: Bool { total == 0 }
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

extension MindNode {
    /// Completion of everything *below* this topic. A closed topic drags its
    /// whole subtree along as done — descendants of a closed node are closed
    /// implicitly and are never stamped individually, so counting them any
    /// other way would report a branch as unfinished the moment you close it.
    var progress: SubtreeProgress {
        var done = 0
        var total = 0
        for child in children {
            let size = child.subtreeCount
            total += size
            if child.isClosed {
                done += size
            } else {
                let sub = child.progress
                done += sub.done
            }
        }
        return SubtreeProgress(done: done, total: total)
    }
}

// MARK: - Document

extension UTType {
    static let mindblow = UTType(exportedAs: "io.github.fpvromadm.mindblow.mindmap")
}

struct MindMapDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] { [.mindblow] }

    var root: MindNode
    /// Non-hierarchical connections between topics.
    var links: [MindLink] = []

    init() {
        root = MindNode(text: "Central Topic")
    }

    init(root: MindNode, links: [MindLink] = []) {
        self.root = root
        self.links = links
    }

    /// On-disk shape once a map has cross-links. Files without them keep the
    /// original "the JSON *is* the root node" form, so nothing an earlier
    /// version wrote — or reads — changes.
    private struct Wrapper: Codable {
        var root: MindNode
        var links: [MindLink]
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self = try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> MindMapDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let wrapper = try? decoder.decode(Wrapper.self, from: data) {
            var doc = MindMapDocument(root: wrapper.root, links: wrapper.links)
            doc.pruneDanglingLinks()
            return doc
        }
        return MindMapDocument(root: try decoder.decode(MindNode.self, from: data))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Only pay for the wrapper when there is something to wrap.
        return links.isEmpty
            ? try encoder.encode(root)
            : try encoder.encode(Wrapper(root: root, links: links))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try encoded())
    }

    // MARK: Links

    /// Drops links whose endpoints no longer exist, are the same node, or are
    /// duplicates of a link already present. Called after any structural edit
    /// so a deleted topic can never leave a connector pointing at nothing.
    mutating func pruneDanglingLinks() {
        guard !links.isEmpty else { return }
        let live = root.subtreeIDs
        var seen = Set<[UUID]>()
        links = links.filter { link in
            guard link.from != link.to,
                  live.contains(link.from), live.contains(link.to) else { return false }
            // A relation is undirected for the purpose of "already linked".
            let key = [link.from, link.to].sorted { $0.uuidString < $1.uuidString }
            return seen.insert(key).inserted
        }
    }

    /// Links attached to a topic, in either direction.
    func links(touching id: UUID) -> [MindLink] {
        links.filter { $0.from == id || $0.to == id }
    }
}
