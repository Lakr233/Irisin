import Foundation

/// The bootstrap layouts a package can be built for, named by the dpkg
/// architecture its control file carries. The name is the whole contract:
/// where the files go, how a load command spells a library, whether a
/// hard-coded path exists at runtime.
public enum BootstrapArchitecture: String, Hashable, Sendable {
    /// Files at `/`, iOS 14 and before. Nothing installs it today; packages
    /// built for it are what the adapters rewrite.
    case rootful = "iphoneos-arm"
    /// Files under `/var/jb`: Dopamine, palera1n rootless.
    case rootless = "iphoneos-arm64"
    /// Files at rootful paths, relocated by dpkg into a randomized root.
    case roothide = "iphoneos-arm64e"

    /// The order a suite repository with nothing built for this device is
    /// probed in, after the device's own. Rootful is last: nothing installs
    /// it, and its index is there to say so rather than fail the refresh.
    public static let probeOrder: [BootstrapArchitecture] = [.roothide, .rootless, .rootful]
}
