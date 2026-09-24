//
//  AptRepositoryBootstrap.swift
//  Irisin
//

import AptRepository
import Dog
import Foundation
import IrisinAdapter

/// Irisin's side of AptRepository's seams. The package holds no opinion on
/// where settings live or where logs go; this is where that gets decided.
/// AptRepository calls back from its own queues, so none of this is isolated.
nonisolated enum AptRepositoryBootstrap {
    static func environment(documentsDirectory: URL) -> AptEnvironment {
        AptEnvironment(
            workingLocation: documentsDirectory,
            dpkgStatusLocation: JailbreakRoot.path("/Library/dpkg/status"),
            aptExtendedStatesLocation: JailbreakRoot.path("/var/lib/apt/extended_states"),
            deviceArchitecture: { PackagedArchitecture.architecture },
            installableArchitectures: { installableArchitectures },
            indexFallbacks: { BootstrapArchitecture.probeOrder.map(\.rawValue) },
            adaptedManifestPreview: {
                PackageAdapters.installed.resolveAdaptedPackageManifestPreview(
                    control: $0,
                    on: PackagedArchitecture.architecture
                )
            },
            storage: SettingStore(),
            logger: DogLogger()
        )
    }

    /// The device's own architecture plus what the shipped adapters rewrite
    /// into it. Both inputs are constants, so this is one.
    static let installableArchitectures: Set<String> =
        PackageAdapters.installed.installable(on: PackagedArchitecture.architecture)
}

/// Dog stamps, formats, hands the line to os_log and writes the file on the
/// caller's thread, and AptRepository logs from the main actor: a line or
/// two for every repository a refresh finishes. The lines go to Dog from
/// one queue, in the order they were logged, and the caller goes on; a
/// critical line, the one a crash may follow, is waited for.
private nonisolated struct DogLogger: AptLogger {
    private static let queue = DispatchQueue(label: "wiki.qaq.irisin.log", qos: .utility)

    func log(_ kind: String, _ message: String, level: AptLogLevel) {
        let join: @Sendable () -> Void = {
            let dogLevel: Dog.DogLevel = switch level {
            case .verbose: .verbose
            case .info: .info
            case .warning: .warning
            case .error: .error
            case .critical: .critical
            }
            Dog.shared.join(kind, message, level: dogLevel)
        }
        if level == .critical {
            Self.queue.sync(execute: join)
        } else {
            Self.queue.async(execute: join)
        }
    }
}
