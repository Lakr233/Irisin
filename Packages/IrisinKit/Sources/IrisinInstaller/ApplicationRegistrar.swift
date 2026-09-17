import Foundation
import IrisinProtocol
#if canImport(IcliKit) && !targetEnvironment(simulator)
    import IcliKit
#endif

/// icli, linked into the helper as `IcliKit`, asked to do the LaunchServices
/// work `uicache` used to and the graceful respring `sbreload` used to.
///
/// One closed request per operation and a reply dictionary that is read
/// rather than shown: the transcript gets one line per call, and icli's
/// message when it refused. Nothing the app sent is ever a request on its
/// own authority; the bundle paths come from the package database and the
/// applications directory.
struct ApplicationRegistrar {
    enum Request: Equatable {
        /// Register, or re-register an updated app at the same path. icli
        /// checks LaunchServices lists it afterwards.
        case register(bundle: String)
        /// Drop the registration, whether or not the bundle is still on
        /// disk. Not being registered is success.
        case unregister(bundle: String)
        /// Register new or moved bundles in the directory, skip unchanged
        /// ones, drop registrations whose bundle is gone.
        case refresh(directory: String)
        /// FrontBoard's relaunch action, the graceful fade `sbreload` sends,
        /// verified by SpringBoard's pid changing.
        case respring
    }

    enum Outcome {
        /// The reply.
        case done([String: Any])
        /// icli refused: the message it gave.
        case failed(String)

        var succeeded: Bool {
            if case .done = self {
                return true
            }
            return false
        }

        /// What to tell the user, when it went wrong.
        var reason: String {
            switch self {
            case .done: ""
            case let .failed(message): message
            }
        }
    }

    /// A refusal from whatever stands in for icli: the harness, or a platform
    /// icli is not built for.
    struct Refusal: Error {
        let message: String
    }

    /// `ApplicationRegistrar.live`, except in the harness.
    let perform: (Request) throws -> [String: Any]

    func register(bundleAt kernelPath: String) -> Outcome {
        run(.register(bundle: kernelPath))
    }

    func unregister(bundleAt kernelPath: String) -> Outcome {
        run(.unregister(bundle: kernelPath))
    }

    /// A reply that lists failures is a failure.
    func refresh(directory: String) -> Outcome {
        let outcome = run(.refresh(directory: directory))
        guard case let .done(reply) = outcome else { return outcome }
        let failed = (reply["failed"] as? [Any]) ?? []
        let unverified = (reply["unverified"] as? [Any]) ?? []
        guard failed.isEmpty, unverified.isEmpty else {
            return .failed("\(failed.count) failed, \(unverified.count) unverified")
        }
        return outcome
    }

    func respring() -> Outcome {
        run(.respring)
    }

    private func run(_ request: Request) -> Outcome {
        do {
            return try .done(perform(request))
        } catch {
            return .failed(Self.message(of: error))
        }
    }

    private static func message(of error: Error) -> String {
        if let refusal = error as? Refusal {
            return refusal.message
        }
        #if canImport(IcliKit) && !targetEnvironment(simulator)
            if let refusal = error as? IcliError {
                return refusal.message
            }
        #endif
        return String(describing: error)
    }

    #if targetEnvironment(simulator)
        /// The simulator's home screen is not ours to change: every request
        /// is announced and answered as done, with the empty reply the
        /// callers already read as nothing to count.
        static func live(emit: @escaping (InstallerEvent) -> Void) -> (Request) throws -> [String: Any] {
            { request in
                emit(.notice("Simulator: \(request) was not carried out"))
                return [:]
            }
        }

    #elseif canImport(IcliKit)
        static func live(emit _: @escaping (InstallerEvent) -> Void) -> (Request) throws -> [String: Any] {
            { request in
                switch request {
                case let .register(bundle):
                    return try registerApp(bundle)
                case let .unregister(bundle):
                    return try unregisterApp(bundle, force: true)
                case let .refresh(directory):
                    do {
                        return try refreshApps(directory: directory)
                    } catch let IcliError.commandFailed(reply) {
                        // The incomplete reply still lists what failed;
                        // `refresh(directory:)` counts it.
                        return reply
                    }
                case .respring:
                    return try IcliKit.respring()
                }
            }
        }

    #else
        /// icli is built for iOS alone; a Mac has no home screen to tell.
        static func live(emit _: @escaping (InstallerEvent) -> Void) -> (Request) throws -> [String: Any] {
            { _ in throw Refusal(message: "icli is not available on this platform") }
        }
    #endif
}
