import IrisinProtocol

extension PackageArchive {
    /// Each link chain is walked once; resolved suffixes are reused by later
    /// links. Large archives do not rebuild the entry table for every file.
    static func resolveHardLinks(_ entries: [PreparedEntry]) throws -> [String: String] {
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var resolved: [String: String] = [:]
        for entry in entries where entry.kind == .hardLink && resolved[entry.path] == nil {
            var chain: [String] = []
            var seen = Set<String>()
            var current = entry
            while current.kind == .hardLink, resolved[current.path] == nil {
                guard seen.insert(current.path).inserted, let target = current.linkTarget,
                      let next = byPath[target]
                else {
                    throw PackageFailure("Missing or cyclic hard link target: \(entry.path)")
                }
                chain.append(current.path)
                current = next
            }
            let target: String
            if let known = resolved[current.path] {
                target = known
            } else if current.kind == .file {
                target = current.path
            } else {
                throw PackageFailure("Hard link has no regular file target: \(entry.path)")
            }
            for path in chain {
                resolved[path] = target
            }
        }
        return resolved
    }
}
