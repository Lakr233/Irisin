import Foundation

/// One conversion between two bootstrap layouts, applied to a package after
/// the app has unpacked it (`ArchiveStream.prepareDebianPackage`) and before
/// the helper is asked to install it. It rewrites the prepared tree in
/// place: entry paths, the control paragraph, maintainer scripts, Mach-O
/// load commands, and re-signs what it touched.
///
/// There is no setting behind an adapter. Being listed in
/// `PackageAdapters.installed` is what allows a package of its `source`
/// architecture to be offered and installed.
public protocol PackageAdapter: Sendable {
    /// The dpkg architecture the adapter reads.
    var source: BootstrapArchitecture { get }
    /// The dpkg architecture it writes; the bootstrap the app runs on.
    var target: BootstrapArchitecture { get }

    /// Whether this package is one the adapter will try, decided from the
    /// control paragraph alone (lowercase field names). False for a package
    /// the adapter knows it cannot make work, not for one that might fail.
    func canAttemptInstall(control: [String: String]) -> Bool

    /// What `adapt` puts in front of the package's Pre-Depends, spelled as
    /// it is written there; nil when it adds nothing. The resolver is told
    /// before anything is downloaded, since `adapt` runs after the plan.
    var impliedPreDepends: String? { get }

    /// Rewrite the prepared package under `directory` for `target` and
    /// return the digest of the manifest as rewritten, the value the job
    /// carries as `preparedSHA256`. The helper re-hashes every blob (sha256
    /// and md5) and checks its size against the manifest, so a blob that was
    /// changed (a patched Mach-O, a re-signed binary) needs its
    /// `PreparedFile` rewritten as well, under its `blob-<n>` name. Throws
    /// `AdaptationFailure` when the package cannot be made to fit; nothing
    /// has been sent to the helper yet, so the transaction simply does not
    /// start.
    func adapt(preparedPackageAt directory: URL) throws -> String
}

public extension PackageAdapter {
    var impliedPreDepends: String? {
        nil
    }
}

/// Why a package could not be adapted. Typed, not prose: the app spells
/// each case in the user's language when it records the report.
public enum AdaptationFailure: Error, Equatable, Sendable {
    /// The pair is listed, so the catalogue offers the package, but the
    /// conversion is not written yet.
    case unavailable(from: BootstrapArchitecture, to: BootstrapArchitecture)
    /// The adapter knows this package does not work once converted
    /// (`canAttemptInstall`), so it is not converted.
    case incompatible(package: String)
    /// The package is more than the adapter converts. `path` is the entry
    /// that says so, as the archive spells it: a file outside the jailbreak
    /// root, conffiles, a daemon's list the patcher would garble.
    case notSimple(package: String, path: String)
    /// A Mach-O the adapter cannot rewrite: damaged, not 64-bit, with no
    /// room left for the longer load commands, or a program whose
    /// entitlements it cannot carry over.
    case malformedBinary(package: String, path: String)
}
