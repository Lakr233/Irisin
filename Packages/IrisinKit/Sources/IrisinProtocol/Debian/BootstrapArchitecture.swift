import Foundation

/// The bootstrap layouts a package can be built for, named by the dpkg
/// architecture its control file carries. A package installs only on the
/// bootstrap it names, or on any when it names `all`.
public enum BootstrapArchitecture: String, Hashable, Sendable {
    /// Files at `/`, iOS 14 and before. Nothing installs it today.
    case rootful = "iphoneos-arm"
    /// Files under `/var/jb`: Dopamine, palera1n rootless.
    case rootless = "iphoneos-arm64"
    /// Files at rootful paths, relocated by dpkg into a randomized root.
    case roothide = "iphoneos-arm64e"

    /// The order a suite repository's index directories are probed in,
    /// after the device's own: a directory's name need not be the
    /// architecture of what it holds (Procursus keeps its rootless packages
    /// in `binary-iphoneos-arm`). Only packages built for the device, or
    /// for `all`, are kept from any of them.
    public static let probeOrder: [BootstrapArchitecture] = [.roothide, .rootless, .rootful]
}
