import Darwin
import Foundation
import IrisinProtocol

/// The directories the tweak loader reads, as they stand: every entry by
/// its file, size and change time. The home screen loads its tweaks once,
/// as it starts, so an operation that leaves these different ends by
/// offering to reload it. A daemon a tweak injects into is the tweak's to
/// restart, and its package does.
nonisolated struct TweakInjection: Equatable, Sendable {
    /// ElleKit reads `usr/lib/TweakInject` and links the Substrate directory
    /// to it; a bootstrap without ElleKit may have the Substrate directory
    /// alone. Both are read, and a directory reached through both once.
    static let directories = [
        "/Library/MobileSubstrate/DynamicLibraries",
        "/usr/lib/TweakInject",
    ]

    private struct Entry: Hashable {
        let path: String
        let inode: UInt64
        let size: Int64
        /// A file put in place is a new inode with a new change time, even
        /// when a reinstall keeps its name, size and modification time.
        let changed: Int
        let changedNanoseconds: Int
    }

    private let entries: Set<Entry>

    /// The directories under this device's bootstrap.
    @concurrent
    static func read() async -> TweakInjection {
        read(directories.map(JailbreakRoot.installedPath))
    }

    /// `paths` as they stand now. One that does not exist has nothing in it.
    /// An entry is itself, a link never its target, and a hidden one is no
    /// tweak: roothide keeps a `.jbroot` link in the directory, which leads
    /// to the bootstrap's root and changes with everything there.
    static func read(_ paths: [String]) -> TweakInjection {
        var entries = Set<Entry>()
        for directory in Set(paths.compactMap(ProcessPath.canonical)) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = directory + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                entries.insert(Entry(
                    path: path,
                    inode: info.st_ino,
                    size: info.st_size,
                    changed: info.st_ctimespec.tv_sec,
                    changedNanoseconds: info.st_ctimespec.tv_nsec
                ))
            }
        }
        return TweakInjection(entries: entries)
    }
}
