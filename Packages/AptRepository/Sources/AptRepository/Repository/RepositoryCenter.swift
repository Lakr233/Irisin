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
/// repository are dictionary operations that finish well inside a frame.
/// Nothing here writes the database on the main actor: a write waits for
/// SQLite's lock, which a refresh holds while it writes a repository's
/// packages, so each commit's row is written after it (`write(_:then:)`).
/// Anything slower — downloading and compiling an index, writing its
/// packages — runs off the main actor and commits its result here.
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

    /// True once `repositories` is what the database holds, never while
    /// `load()` is still reading: an empty list before that says nothing.
    public private(set) var isLoaded = false
    private var isLoading = false

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

    /// A repository older than this is out of date: its dot says so. One day.
    public let smartUpdateTimeInterval = 86400

    /// How old a repository may get before it is refreshed on its own, in
    /// seconds; zero never does. Asked at launch here, and after that by
    /// the app (`dispatchAutomaticRefresh()`). A day unless Settings says
    /// otherwise. Writing it queues nothing: whoever writes it asks.
    private let automaticRefreshStore = AptSetting<TimeInterval>(
        key: "\(kRepositoryCenterIdentity).automaticRefreshInterval",
        defaultValue: 86400
    )
    public var automaticRefreshInterval: TimeInterval {
        get { automaticRefreshStore.wrappedValue }
        set { automaticRefreshStore.wrappedValue = max(newValue, 0) }
    }

    /// When the automatic refresh last queued each repository. A refresh
    /// that fails leaves the repository as old as it was, and without this
    /// it would be queued again at every look; it waits an interval instead.
    var automaticAttempts: [URL: Date] = [:]

    /// used to present notification to user interface
    lazy var notificationThrottle = Throttler(minimumDelay: 0.5)

    /// notification name
    public nonisolated static let registrationUpdate = Notification.Name(
        "\(kRepositoryCenterIdentity).registrationUpdate"
    )
    public nonisolated static let metadataUpdate = Notification.Name("\(kRepositoryCenterIdentity).metadataUpdate")

    /// How the update engine paces itself: how many at once, and when an
    /// update is stalled or given up (`UpdateSchedule`).
    let updateLimits = UpdateSchedule.Limits()

    /// update queue
    var pendingUpdateRequest: Set<URL> = []
    var currentlyInUpdate: Set<URL> = []
    var currentUpdateProgress: [URL: Progress] = [:]
    private var updateLoop: Task<Void, Never>?

    /// Each update in flight: its task, to give it up by, when it started,
    /// and when it last heard from the server.
    var updateTasks: [URL: Task<Void, Never>] = [:]
    var updateStarted: [URL: Date] = [:]
    var lastActivity: [URL: Date] = [:]
    /// in flight and out of their slots for making no progress
    var stalledUpdates: Set<URL> = []
    /// cancelled for making no progress, and not finished yet
    var givenUpUpdates: Set<URL> = []
    /// cancelled because the repository was deleted, and not finished yet:
    /// out of their slots, and what they bring back is thrown away
    var deletedUpdates: Set<URL> = []
    /// the limit the last decision came to, and whether it was held back,
    /// to log a change once
    var updateLimit = 4
    var updateLimitHeldBack = false
    /// from the queue's first dispatch until it is empty again
    var refreshRound: RefreshRound?
    /// The last database write asked for on the main actor; each one runs
    /// after the one before it, off the main actor (`write(_:then:)`).
    var lastWrite: Task<Void, Never>?

    /// when updating repository property, set by application to user default, not here
    @AptSetting(key: "\(kRepositoryCenterIdentity).networkingHeaders", defaultValue: [:])
    public var networkingHeaders: [String: String]
    /// Seconds a request may go without hearing from the server. Under
    /// the watchdog's 25, so a silent host always ends as a timed-out
    /// request, unreachable, and never as whichever of the two fired first.
    public let networkingTimeout = 20
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

    /// The launch's refresh of what is out of date has been queued, or found
    /// nothing to do. Until then an empty queue says nothing about whether
    /// the catalogue is about to move.
    public private(set) var hasQueuedLaunchRefresh = false

    /// Reads the repositories and starts the update engine. Once per
    /// process, after `PackageCenter.load()`.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true

        aptLog(self, "initializing manager")

        repositories = await Self.readRepositories(from: AptDatabase.shared)
        isLoaded = true
        aptLog(self, "database reported \(repositories.keys.count) repository", level: .info)
        // a page built before this read has an empty list to replace
        NotificationCenter.default.post(name: RepositoryCenter.registrationUpdate, object: nil)

        // Give the app a moment to finish booting, then look over the
        // update queue once a second: the watchdog runs on this tick.
        updateLoop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3 * NSEC_PER_SEC)
            self?.dispatchAutomaticRefresh()
            self?.hasQueuedLaunchRefresh = true
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
