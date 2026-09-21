import Foundation
import IrisinProtocol
#if canImport(IcliKit) && !targetEnvironment(simulator)
    import IcliKit
#endif

/// The two launchd changes Irisin's own package may make. The plist path is
/// derived by `InstallerRunner`; neither the app nor a package supplies it.
struct LaunchDaemon {
    private static let label = "wiki.qaq.irisind"

    enum Request: Equatable {
        case bootstrap(plist: String, executable: String)
        case bootout(plist: String)
    }

    let perform: (Request) throws -> Void

    /// launchd reads kernel paths; unlike the bootstrap's launchctl, IcliKit
    /// does not translate rootful program paths for RootHide.
    ///
    /// RootHide renames the bootstrap root at every jailbreak and its
    /// launchctl then rewrites each plist here (`plistpatch.m`): one marked
    /// `__Patched` has the old root taken off its paths before the new one is
    /// put on, one without the mark only gets the new root in front. A kernel
    /// path written without the mark comes out as new root + old root and the
    /// daemon never starts again. launchd itself ignores the key.
    static func preparePlist(at path: String, executable: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        plist["ProgramArguments"] = [executable]
        plist["__Patched"] = true
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: url, options: .atomic)
    }

    #if targetEnvironment(simulator)
        static func live(emit: @escaping (InstallerEvent) -> Void) -> (Request) throws -> Void {
            { request in
                emit(.notice("Simulator: \(request) was not carried out"))
            }
        }

    #elseif canImport(IcliKit)
        static func live(emit _: @escaping (InstallerEvent) -> Void) -> (Request) throws -> Void {
            { request in
                switch request {
                case let .bootstrap(plist, executable):
                    // A package upgrade replaces both the plist and daemon.
                    // Boot out the old instance, load the new file, then start
                    // it now instead of waiting for the first Mach lookup.
                    _ = try loadServices([plist], load: false, override: false)
                    try preparePlist(at: plist, executable: executable)
                    _ = try loadServices([plist], load: true, override: false)
                    _ = try startService(Self.label)
                case let .bootout(plist):
                    _ = try loadServices([plist], load: false, override: false)
                }
            }
        }

    #else
        static func live(emit _: @escaping (InstallerEvent) -> Void) -> (Request) throws -> Void {
            { _ in throw CocoaError(.featureUnsupported) }
        }
    #endif
}
