import Foundation

/// Tag identity. A tag is whatever it says folded to lower case, so `Work`,
/// `work` and `WORK` are one tag everywhere — one chip in the filter bar, one
/// entry on a node, one thing to filter by. The first spelling the map shows is
/// the one that sticks; typing a variant adopts it instead of minting a twin.
///
/// Only case is folded. Accents still separate tags: find folds them because
/// guessing helps when you are searching, but `#resume` and `#résumé` are
/// plausibly two different labels and merging them silently would lose one.
enum Tags {
    static func key(_ tag: String) -> String {
        tag.lowercased()
    }

    static func keys<S: Sequence>(_ tags: S) -> Set<String> where S.Element == String {
        Set(tags.map(key))
    }

    /// One tag per key, in first-seen order, keeping the spelling first seen.
    static func distinct<S: Sequence>(_ tags: S) -> [String] where S.Element == String {
        var seen: Set<String> = []
        return tags.filter { seen.insert(key($0)).inserted }
    }

    static func contains<S: Sequence>(_ tags: S, _ tag: String) -> Bool where S.Element == String {
        let k = key(tag)
        return tags.contains { key($0) == k }
    }

    /// `tag` appended to `tags`, spelled the way `known` already spells it.
    /// A tag the node already carries in any casing is left alone.
    static func adding(_ tag: String, to tags: [String], known: [String]) -> [String] {
        guard !contains(tags, tag) else { return tags }
        return tags + [canonical(tag, among: known)]
    }

    static func removing(_ tag: String, from tags: [String]) -> [String] {
        let k = key(tag)
        return tags.filter { key($0) != k }
    }

    /// The spelling `known` uses for this tag, or `tag` itself if it is new.
    static func canonical(_ tag: String, among known: [String]) -> String {
        let k = key(tag)
        return known.first { key($0) == k } ?? tag
    }

    /// Tags worth offering while `query` is being typed: the ones that start
    /// with it first, since those are what a completion can finish, then the
    /// ones that merely contain it. Tags the topic already carries are left
    /// out — there is nothing to add.
    static func suggestions(for query: String, from known: [String],
                            excluding taken: [String], limit: Int = 6) -> [String] {
        let typed = key(query.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        guard !typed.isEmpty else { return [] }
        let available = known.filter { !contains(taken, $0) }
        let prefixed = available.filter { key($0).hasPrefix(typed) }
        let contained = available.filter { !key($0).hasPrefix(typed) && key($0).contains(typed) }
        return Array((prefixed + contained).prefix(limit))
    }

    /// Does a node carrying `tags` pass a filter holding these keys?
    /// An empty filter is handled by the caller; here it matches nothing.
    static func matches<S: Sequence>(_ tags: S, anyOf activeKeys: Set<String>) -> Bool
    where S.Element == String {
        tags.contains { activeKeys.contains(key($0)) }
    }
}
