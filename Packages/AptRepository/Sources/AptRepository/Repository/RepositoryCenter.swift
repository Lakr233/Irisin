//
//  RepositoryCenter.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

let kRepositoryCenterIdentity = "wiki.qaq.irisin.RepositoryCenter"

/// Repository Center manages every software distribution source.
///
/// Main-actor state and no locks: registering, looking up and queueing a
/// repository are dictionary operations that finish well inside a frame,
/// and each commit is one row written to the database. Anything slower —
/// downloading and compiling an index, writing its packages — runs off the
/// main actor and commits its result here.
///
/// Everything it needs from the outside — where the database lives, which
/// package flavour this device takes, where settings live, where logs go —
/// arrives in `AptEnvironment.bootstrap(_:)` before `load()` is called.
@MainActor
public final class RepositoryCenter {
    public nonisolated static let `default` = RepositoryCenter()

    /// Every registered repository by url. A value: hand it to work that runs
    /// off the main actor instead of calling back in.
    public internal(set) var repositories: [URL: Repository] = [:]

    public private(set) var isLoaded = false

    /// Deleted repositories as source lines, offered again by the add sheet.
    @AptSetting(key: "\(kRepositoryCenterIdentity).historyRecords", defaultValue: [])
    private var _historyRecords: [String]
    public var historyRecords: Set<String> {
        set {
            _historyRecords = [String](newValue)
        }
        get {
            Set<String>(_historyRecords)
        }
    }

    /// A repository older than this is refreshed on launch: one day.
    public let smartUpdateTimeInterval = 86400

    /// used to control update engine
    lazy var updateDispatchThrottle = Throttler(minimumDelay: 1)
    /// used to present notification to user interface
    lazy var notificationThrottle = Throttler(minimumDelay: 0.5)

    /// notification name
    public nonisolated static let registrationUpdate = Notification.Name(
        "\(kRepositoryCenterIdentity).registrationUpdate"
    )
    public nonisolated static let metadataUpdate = Notification.Name("\(kRepositoryCenterIdentity).metadataUpdate")

    /// How many repositories the update engine refreshes at once.
    public let updateConcurrencyLimit = 4

    /// update queue
    var pendingUpdateRequest: Set<URL> = []
    var currentlyInUpdate: Set<URL> = []
    var currentUpdateProgress: [URL: Progress] = [:]
    private var updateLoop: Task<Void, Never>?

    /// when updating repository property, set by application to user default, not here
    @AptSetting(key: "\(kRepositoryCenterIdentity).networkingHeaders", defaultValue: [:])
    public var networkingHeaders: [String: String]
    /// Seconds a single request may take.
    public let networkingTimeout = 60
    @AptSetting(key: "\(kRepositoryCenterIdentity).networkingVerboseLogging", defaultValue: false)
    public var networkingVerboseLogging: Bool
    @AptSetting(key: "\(kRepositoryCenterIdentity).networkingRedirect", defaultValue: Data())
    private var _networkingRedirect: Data
    public var networkingRedirect: [URL: URL] {
        set {
            _networkingRedirect = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
        get {
            (try? JSONDecoder().decode([URL: URL].self, from: _networkingRedirect)) ?? [:]
        }
    }

    /// The headers, timeout and logging switch a download runs with, taken
    /// when the update is dispatched.
    var networkingConfiguration: NetworkingConfiguration {
        .init(
            headers: networkingHeaders,
            timeout: networkingTimeout,
            verboseLogging: networkingVerboseLogging
        )
    }

    /// Nothing is read here: the first touch of `default` may come from any
    /// thread, and the work waits for `load()`.
    private nonisolated init() {}

    /// Reads the repositories and starts the update engine. Once per
    /// process, after `PackageCenter.load()`.
    public func load() async {
        guard !isLoaded else { return }
        isLoaded = true

        aptLog(self, "initializing manager")

        repositories = await Self.readRepositories(from: AptDatabase.shared)
        aptLog(self, "database reported \(repositories.keys.count) repository", level: .info)

        // Give the app a moment to finish booting, then keep draining the
        // update queue once a second.
        updateLoop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3 * NSEC_PER_SEC)
            self?.dispatchSmartUpdateRequestOnAll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                self?.dispatchUpdateOnCurrentCenter()
            }
        }
    }

    nonisolated static func readRepositories(from db: AptDatabase) async -> [URL: Repository] {
        var build = [URL: Repository]()
        for repository in db.repositories() {
            build[repository.url] = repository
        }
        return build
    }
}
