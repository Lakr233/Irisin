import CryptoKit
import Foundation

/// What a Release says its indexes hash to, so an index that is not the one
/// the Release was written beside is refused instead of compiled. A CDN
/// keeps each file on its own clock: GitHub Pages served apt.owngoal.dev a
/// day-old `Packages.xz` beside a current Release and a current `Packages`,
/// and the old one parsed perfectly well.
struct IndexDigests: Sendable {
    enum Verdict: Sendable {
        /// the Release lists the file and this is it
        case matches
        /// the Release lists the file and this is another
        case differs
        /// the Release says nothing about the file: nothing to hold it to
        case unlisted
    }

    /// lowercase hex by the path the Release spells, which is relative to
    /// the directory the Release is in
    private let sha256: [String: String]
    /// the address of that directory, ending in a slash
    private let directory: String

    /// - Parameters:
    ///   - release: the parsed Release, its keys lowercased; the parser
    ///     folds the `SHA256` lines into one, so the value reads hash, size
    ///     and path over and over
    ///   - releaseUrl: where that Release was fetched from
    init(release: [String: String], releaseUrl: URL) {
        let words = release["sha256"]?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        var sha256 = [String: String]()
        var entry = 0
        while entry + 2 < words.count {
            let digest = words[entry].lowercased()
            // a word out of place costs the entry it is in, not the table
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit), Int(words[entry + 1]) != nil else {
                entry += 1
                continue
            }
            sha256[Self.normalized(words[entry + 2])] = digest
            entry += 3
        }
        self.sha256 = sha256
        let directory = releaseUrl.deletingLastPathComponent().absoluteString
        self.directory = directory.hasSuffix("/") ? directory : directory + "/"
    }

    /// The Release lists any digest at all: one that lists none vouches for
    /// nothing, and no index is the worse for it.
    var listsAnything: Bool {
        !sha256.isEmpty
    }

    /// Whether the Release lists the file at `url` at all: one it lists and
    /// the server does not hand over is missing, not merely never offered.
    func lists(_ url: URL) -> Bool {
        path(of: url).map { sha256[$0] != nil } ?? false
    }

    /// Whether `data`, fetched from `url`, is the file the Release lists
    /// there. The bytes are judged as served, before any decompression.
    func verdict(of data: Data, at url: URL) -> Verdict {
        guard let path = path(of: url), let expected = sha256[path] else { return .unlisted }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if digest == expected {
            return .matches
        }
        // URLSession undoes a Content-Encoding by itself, and a server that
        // labels `Packages.gz` that way has it arrive unpacked: then it is
        // the uncompressed index the Release lists that these bytes are.
        let unpacked = (path as NSString).deletingPathExtension
        if unpacked != path, sha256[unpacked] == digest {
            return .matches
        }
        return .differs
    }

    /// The path the Release would list `url` under, nil for a file that is
    /// not under the Release's directory.
    private func path(of url: URL) -> String? {
        let address = url.absoluteString
        guard address.hasPrefix(directory) else { return nil }
        return Self.normalized(String(address.dropFirst(directory.count)))
    }

    /// When a Release says it was written, nil when it does not say or
    /// says it some other way. A Release older than the one already read is
    /// the CDN's stale copy, and no index is held to that.
    static func date(of release: [String: String]) -> Date? {
        guard let text = release["date"] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    /// A flat repository's Release may spell `./Packages`.
    private static func normalized(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }
}
