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
    /// catalogue keeps and what the resolver may pick; which Packages index
    /// a suite repository is asked for still follows `deviceArchitecture`,
    /// so only a flat repository can offer an adapter's source packages.
    public var installableArchitectures: Set<String> {
        readInstallableArchitectures()
    }

    private let readInstallableArchitectures: @Sendable () -> Set<String>

    /// What the embedder's adapter prepends to the Pre-Depends of a package
    /// it rewrites; nil when nothing is adapted. See `ResolutionSnapshot`.
    public let adaptedPreDepends: String?

    public let storage: any AptStorage
    public let logger: any AptLogger

    public init(
        workingLocation: URL,
        dpkgStatusLocation: String,
        aptExtendedStatesLocation: String? = nil,
        deviceArchitecture: @escaping @Sendable () -> String,
        installableArchitectures: (@Sendable () -> Set<String>)? = nil,
        adaptedPreDepends: String? = nil,
        storage: any AptStorage,
        logger: any AptLogger
    ) {
        self.workingLocation = workingLocation
        self.dpkgStatusLocation = dpkgStatusLocation
        self.aptExtendedStatesLocation = aptExtendedStatesLocation
        readDeviceArchitecture = deviceArchitecture
        readInstallableArchitectures = installableArchitectures ?? { [deviceArchitecture()] }
        self.adaptedPreDepends = adaptedPreDepends
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

/// A value persisted through the injected `AptStorage`, cached after the first
/// read. Owned by a center, so read and written on the main actor only.
@propertyWrapper
public final class AptSetting<Value: Codable & Sendable> {
    private let key: String
    private let defaultValue: Value
    private var cachedValue: Value?

    public init(key: String, defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
        cachedValue = Self.readDisk(key: key)
    }

    public var wrappedValue: Value {
        get { cachedValue ?? Self.readDisk(key: key) ?? defaultValue }
        set {
            cachedValue = newValue
            AptEnvironment.current.storage.write(key: key, value: try? JSONEncoder().encode(newValue))
        }
    }

    private static func readDisk(key: String) -> Value? {
        guard let data = AptEnvironment.current.storage.read(key: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
