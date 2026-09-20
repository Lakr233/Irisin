import Foundation
import IrisinProtocol
#if canImport(IcliKit) && !targetEnvironment(simulator)
    import IcliKit
#endif

/// The two launchd changes Irisin's own package may make. The plist path is
/// derived by `InstallerRunner`; neither the app nor a package supplies it.
struct LaunchDaemonManager {
    private static let label = "wiki.qaq.irisind"

    enum Request: Equatable {
        case bootstrap(plist: String)
        case bootout(plist: String)
    }

    let perform: (Request) throws -> Void

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
                case let .bootstrap(plist):
                    // A package upgrade replaces both the plist and daemon.
                    // Boot out the old instance, load the new file, then start
                    // it now instead of waiting for the first Mach lookup.
                    _ = try loadServices([plist], load: false, override: false)
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
