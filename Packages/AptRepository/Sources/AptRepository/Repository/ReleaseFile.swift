import Foundation

/// A repository's Release file, read the way repositories actually write
/// it. A package's control paragraph is held to `DebianControl.parse`,
/// which refuses a duplicate field because a second `Depends` must not
/// silently replace the first; a Release is only ever read for its name,
/// its architectures and its digests, and one that says something twice is
/// still worth its name. mtac.app's has a `SHA256:` table for every publish
/// it ever made, one under the other, with blank lines between them.
enum ReleaseFile {
    /// The fields that list what each index hashes to.
    static let digestFields: Set<String> = ["md5sum", "sha1", "sha256", "sha512"]

    struct Reading: Sendable, Equatable {
        /// lowercased field names to values, the first of each name kept;
        /// no digest field when any of them came more than once
        var fields: [String: String]
        /// a digest field came more than once: which table is the current
        /// one is anybody's guess, so none of them judges an index
        var digestsDuplicated: Bool
    }

    /// The file's fields, or nil when it is not a Release at all: nothing
    /// in it, a NUL byte, or a line that is neither a field, a
    /// continuation, a comment nor blank (a web page served under 200).
    /// A blank line does not end the file's one paragraph, and a field that
    /// comes again is skipped with the lines that continue it.
    static func read(_ text: String) -> Reading? {
        var fields = [String: String]()
        var duplicated = Set<String>()
        // the field the next continuation line belongs to, nil after a
        // skipped duplicate so its lines go with it
        var current: String?
        var skipping = false
        let lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map {
            String(decoding: $0.last == 0x0D ? $0.dropLast() : $0, as: UTF8.self)
        }
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.utf8.first == UInt8(ascii: "#") {
                continue
            }
            guard !line.utf8.contains(0) else { return nil }
            if line.utf8.first == 0x20 || line.utf8.first == 0x09 {
                if skipping {
                    continue
                }
                guard let current else { return nil }
                fields[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let separator = line.utf8.firstIndex(of: UInt8(ascii: ":")) else { return nil }
            let key = String(decoding: line.utf8[..<separator], as: UTF8.self).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 58 }) else { return nil }
            if fields[key] != nil {
                duplicated.insert(key)
                skipping = true
                current = nil
                continue
            }
            fields[key] = String(decoding: line.utf8[line.utf8.index(after: separator)...], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            skipping = false
            current = key
        }
        guard !fields.isEmpty else { return nil }
        let digestsDuplicated = !duplicated.isDisjoint(with: digestFields)
        if digestsDuplicated {
            for field in digestFields {
                fields.removeValue(forKey: field)
            }
        }
        return Reading(fields: fields, digestsDuplicated: digestsDuplicated)
    }
}
