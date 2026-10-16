import Darwin
import Foundation

/// Which executables `irisind` serves, decided on the file the kernel says
/// the peer is running, after its entitlements.
///
/// Until 4.7 the answer was one path, Irisin's own app. Other packages now
/// install through Irisin too (Apelin's session host first), so the answer is
/// a place and a shape instead of a name:
///
/// - the path is canonical (`realpath(3)`, a NUL refused first), and lies
///   inside the bootstrap's install root or on the system volume, compared
///   component by component, never as a string prefix (`/var/jb2` is not
///   inside `/var/jb`);
/// - every directory from the install root down to the file is owned by
///   root or a system account and writable by nobody else, so no process
///   with less than that could have put the file there or swapped it since;
/// - the file is regular, owned by root, executable by its owner and
///   writable by nobody else.
///
/// What this admits is any installed package's root-owned program that also
/// carries the client entitlements: the entitlement says a program means to
/// be a client, not which package it came from. `Documentation/ExternalClients.md`
/// writes the trust model down.
public struct ExecutableAdmission: Sendable {
    /// Why a path was refused, for the daemon's log. Never sent to the peer.
    public enum Refusal: Error, Equatable, Sendable {
        case unresolvable
        case outsideTrustedPlaces
        case untrustedDirectory(String)
        case untrustedFile
    }

    /// The canonical install root, or nil where there is none to trust
    /// (rootful, or a daemon that could not resolve its own): then only the
    /// system volume is.
    public let installRoot: String?
    /// Whether a file on the read-only volume mounted at `/` (iOS's sealed
    /// system volume) is trusted for being there.
    public let trustsSystemVolume: Bool
    /// The owners a trusted file may have. Root on a device; the harness
    /// passes its own uid, since it cannot make a file root's.
    public let trustedOwners: Set<uid_t>

    public init(installRoot: String?, trustsSystemVolume: Bool, trustedOwners: Set<uid_t> = [0]) {
        self.installRoot = installRoot.flatMap { root in
            root.isEmpty ? nil : ProcessPath.canonical(root)
        }
        self.trustsSystemVolume = trustsSystemVolume
        self.trustedOwners = trustedOwners
    }

    /// The canonical path when `path` may be served, or the reason not.
    public func admit(_ path: String) -> Result<String, Refusal> {
        guard let canonical = ProcessPath.canonical(path) else { return .failure(.unresolvable) }
        var info = stat()
        guard lstat(canonical, &info) == 0 else { return .failure(.unresolvable) }
        guard info.st_mode & S_IFMT == S_IFREG,
              trustedOwners.contains(info.st_uid),
              info.st_mode & S_IXUSR != 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else { return .failure(.untrustedFile) }

        if let installRoot, Self.isInside(canonical, root: installRoot) {
            // From the root itself down to the file's own directory.
            var directory = installRoot
            let below = Self.components(canonical).dropFirst(Self.components(installRoot).count).dropLast()
            guard isTrustedDirectory(directory) else { return .failure(.untrustedDirectory(directory)) }
            for component in below {
                let name = String(decoding: component, as: UTF8.self)
                directory = directory == "/" ? "/" + name : directory + "/" + name
                guard isTrustedDirectory(directory) else { return .failure(.untrustedDirectory(directory)) }
            }
            return .success(canonical)
        }
        // The sealed system volume: nothing writes there at all.
        if trustsSystemVolume, Self.isOnReadOnlyRootVolume(canonical) {
            return .success(canonical)
        }
        return .failure(.outsideTrustedPlaces)
    }

    /// Owned by root or a system account below 500 (mobile is 501), not a
    /// link, and writable by nobody but its owner.
    private func isTrustedDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        let owner = info.st_uid
        return (owner < 500 || trustedOwners.contains(owner)) && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    /// Whether the file system `path` is on is the one mounted at `/`, and
    /// mounted read-only. `/private/var` and `/private/preboot` are volumes
    /// of their own, mounted elsewhere, and a root remounted writable is
    /// not trusted for being the root.
    static func isOnReadOnlyRootVolume(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) != 0 else { return false }
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return mountPoint == "/"
    }

    /// Whether canonical `path` is `root` or below it, by component.
    public static func isInside(_ path: String, root: String) -> Bool {
        let rootComponents = components(root)
        let pathComponents = components(path)
        return pathComponents.count >= rootComponents.count
            && zip(rootComponents, pathComponents).allSatisfy { $0.elementsEqual($1) }
    }

    /// The bytes between slashes, empty ones dropped. By bytes, as the
    /// kernel reads a path: a combining mark after `/` must not merge into
    /// a character with it.
    private static func components(_ path: String) -> [Substring.UTF8View] {
        path.utf8.split(separator: 0x2F)
    }
}
