//
//  PackageLookupCache.swift
//  AptRepository
//

import Foundation
import LRUCache

/// The repository packages a list is drawing, by identity and repository.
///
/// A row is configured on the main actor, and a package read there is a
/// query and a decode of its whole payload: once per row, it stalls a
/// scroll. So a row asks here and never waits. What is not held yet is
/// answered `.loading` and read off the main actor, together with
/// everything else asked for in the same turn; when it arrives, `loaded`
/// names what came, and the row asks again. A repository written makes what
/// is held stale, not gone: it is still answered, and read again behind it.
///
/// Everything here is the main actor's, as the center's state is: the read
/// takes a copy of the index and commits back, and an answer read before
/// the database changed never passes for a current one.
@MainActor
public final class PackageLookupCache {
    public struct Key: Hashable, Sendable {
        public let identity: String
        public let repository: URL

        public init(identity: String, repository: URL) {
            self.identity = identity
            self.repository = repository
        }
    }

    public enum Lookup {
        /// nothing is held yet; `loaded` says when it is
        case loading
        /// what the repository offers under the key, nil when nothing
        case loaded(Package?)
    }

    /// Posted on the main actor once a read is held; `userInfo[keysKey]` is
    /// the `Set<Key>` it answered.
    public nonisolated static let loaded = Notification.Name(
        rawValue: "\(kPackageCenterIdentity).packageLookupLoaded"
    )
    public nonisolated static let keysKey = "keys"

    private struct Entry {
        let package: Package?
        /// the `generation` it was read in
        let generation: Int
    }

    /// the rows of a few screens, and cleared under memory pressure
    private let entries = LRUCache<Key, Entry>(countLimit: 512)
    /// one more for every write of the repositories
    private var generation = 0
    /// asked for in this generation and not held yet: queued or in flight
    private var requested = Set<Key>()
    /// asked for since the last read began
    private var queued = Set<Key>()

    public nonisolated init() {}

    /// What `repository` offers as `identity`, from memory. Anything not
    /// held, or held from before the last write, is read in the background.
    public func package(identity: String, in repository: URL) -> Lookup {
        let key = Key(identity: identity, repository: repository)
        let entry = entries.value(forKey: key)
        if entry?.generation != generation {
            request(key)
        }
        guard let entry else { return .loading }
        return .loaded(entry.package)
    }

    /// The repositories were written: everything held is read again when
    /// next asked for, and a read already running answers the old catalogue.
    func invalidate() {
        generation += 1
        requested.removeAll()
    }

    private func request(_ key: Key) {
        guard requested.insert(key).inserted else { return }
        queued.insert(key)
        guard queued.count == 1 else { return }
        // every row of a layout pass asks before this runs, and one read
        // answers them all
        Task { await load() }
    }

    private func load() async {
        let keys = queued
        queued.removeAll()
        let read = generation
        let found = await Self.read(keys, from: PackageCenter.default.index)
        for key in keys {
            // an older read never replaces a newer one
            if let held = entries.value(forKey: key), held.generation >= read { continue }
            entries.setValue(Entry(package: found[key], generation: read), forKey: key)
        }
        // an answer from before a write stays requested in no generation:
        // shown for now, and asked for again by the row it wakes
        if read == generation {
            requested.subtract(keys)
        }
        NotificationCenter.default.post(name: Self.loaded, object: nil, userInfo: [Self.keysKey: keys])
    }

    /// one statement per repository asked about
    private nonisolated static func read(_ keys: Set<Key>, from index: PackageIndex) async -> [Key: Package] {
        var found = [Key: Package]()
        for (repository, keys) in Dictionary(grouping: keys, by: \.repository) {
            for package in index.db.packages(identities: keys.map(\.identity), in: repository) {
                found[Key(identity: package.identity, repository: repository)] = package
            }
        }
        return found
    }
}
