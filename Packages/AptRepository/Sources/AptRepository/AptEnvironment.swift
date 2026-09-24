//
//  AptEnvironment.swift
//  AptRepository
//
//  Everything this package needs from whoever embeds it.
//

import Foundation

// MARK: - Seams

/// Small persisted settings, one value per key. The embedder decides where
/// they live; the package only reads and writes bytes.
public protocol AptStorage: Sendable {
    func read(key: String) -> Data?
    func write(key: String, value: Data?)
}

public enum AptLogLevel: String, Sendable {
    case verbose
    case info
    case warning
    case error
    case critical
}

public protocol AptLogger: Sendable {
    func log(_ kind: String, _ message: String, level: AptLogLevel)
}

// MARK: - Environment

/// The package used to reach for all of this itself: UserDefaults for the store
/// prefix, Dog for logging, and two mutable statics for the bootstrap layout.
/// That tied it to one app and left it untestable anywhere but a jailbroken
/// device. Now the embedder hands it over once, up front.
public struct AptEnvironment: Sendable {
    /// Where both centers persist their compiled state.
    public let workingLocation: URL

    /// The bootstrap's dpkg status file, read to learn what is installed.
    public let dpkgStatusLocation: String

    /// APT's `extended_states`, read to learn which installed packages came
    /// in as dependencies. None, or a missing file, marks every package as
    /// installed by hand.
    public let aptExtendedStatesLocation: String?

    /// Picks package flavours and builds download URLs, eg `iphoneos-arm64`.
    /// Read on every use: the embedder lets the user override it in settings
    /// and the next repository refresh must pick the new one up without a relaunch.
    public var deviceArchitecture: String {
        readDeviceArchitecture()
    }

    private let readDeviceArchitecture: @Sendable () -> String

    /// Every architecture a package may carry and still install here:
    /// `deviceArchitecture` plus those the embedder's adapters rewrite into
    /// it. `all` is always accepted and never listed. Decides what the
    /// resolver may pick and which flavour of a package the catalogue
    /// prefers; what a suite repository is asked for is `indexArchitectures`.
    public var installableArchitectures: Set<String> {
        readInstallableArchitectures()
    }

    private let readInstallableArchitectures: @Sendable () -> Set<String>

    /// The index directories a suite repository is probed for, in order:
    /// `deviceArchitecture` first, then the other bootstraps the embedder
    /// knows. Those in `installableArchitectures` are read together as one
    /// catalogue; the rest are reached one by one only when nothing before
    /// them answered, so a suite with nothing that installs here still
    /// lists what it has, and each package says whether it installs here
    /// (`Repository.packageIndexUrls`). An installable architecture the
    /// embedder leaves out of its fallbacks has no directory read.
    public var indexArchitectures: [String] {
        let device = deviceArchitecture
        return [device] + readIndexFallbacks().filter { $0 != device }
    }

    private let readIndexFallbacks: @Sendable () -> [String]

    /// The embedder's adapters' preview of a package they rewrite; nil when
    /// nothing is adapted. See `ResolutionSnapshot`.
    public let adaptedManifestPreview: ResolutionSnapshot.ManifestPreview?

    public let storage: any AptStorage
    public let logger: any AptLogger

    public init(
        workingLocation: URL,
        dpkgStatusLocation: String,
        aptExtendedStatesLocation: String? = nil,
        deviceArchitecture: @escaping @Sendable () -> String,
        installableArchitectures: (@Sendable () -> Set<String>)? = nil,
        indexFallbacks: @escaping @Sendable () -> [String] = { [] },
        adaptedManifestPreview: ResolutionSnapshot.ManifestPreview? = nil,
        storage: any AptStorage,
        logger: any AptLogger
    ) {
        self.workingLocation = workingLocation
        self.dpkgStatusLocation = dpkgStatusLocation
        self.aptExtendedStatesLocation = aptExtendedStatesLocation
        readDeviceArchitecture = deviceArchitecture
        readInstallableArchitectures = installableArchitectures ?? { [deviceArchitecture()] }
        readIndexFallbacks = indexFallbacks
        self.adaptedManifestPreview = adaptedManifestPreview
        self.storage = storage
        self.logger = logger
    }
}

public extension AptEnvironment {
    /// Hand the package its environment. Call once, before either center is
    /// touched — both are lazy singletons that read this while initializing.
    static func bootstrap(_ environment: AptEnvironment) {
        environmentLock.withLock {
            assert(stored == nil, "AptEnvironment.bootstrap was called twice")
            stored = environment
        }
    }

    static var current: AptEnvironment {
        guard let environment = environmentLock.withLock({ stored }) else {
            preconditionFailure("AptEnvironment.bootstrap must run before RepositoryCenter or PackageCenter")
        }
        return environment
    }
}

private let environmentLock = NSLock()
private nonisolated(unsafe) var stored: AptEnvironment?

// MARK: - Convenience

func aptLog(_ kind: Any, _ message: String, level: AptLogLevel = .info) {
    AptEnvironment.current.logger.log(String(describing: kind), message, level: level)
}

/// A value persisted through the injected `AptStorage`, read once when the
/// center that owns it is made. Owned by a center, so read and written on the
/// main actor only.
@propertyWrapper
public final class AptSetting<Value: Codable & Sendable> {
    private let key: String
    /// A key never written is its default from then on: the storage is in
    /// place before either center exists, and a miss used to go back to the
    /// disk on every read, once per dispatched update for the logging switch.
    private var value: Value

    public init(key: String, defaultValue: Value) {
        self.key = key
        value = Self.readDisk(key: key) ?? defaultValue
    }

    public var wrappedValue: Value {
        get { value }
        set {
            value = newValue
            AptEnvironment.current.storage.write(key: key, value: try? JSONEncoder().encode(newValue))
        }
    }

    private static func readDisk(key: String) -> Value? {
        guard let data = AptEnvironment.current.storage.read(key: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
