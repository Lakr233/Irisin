//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

let kPackageCenterIdentity = "wiki.qaq.irisin.PackageCenter"

/// Package Center answers what is installed, what every repository offers and
/// what changed when.
///
/// The catalogue is the database; every query on `index` is a statement
/// against it. The two jobs that take real time — parsing the dpkg status
/// file, tracing what changed — run off the main actor and write the
/// database directly; the center only announces the result.
///
/// The bootstrap's dpkg status file, the database location and the logger
/// all come from `AptEnvironment.bootstrap(_:)`.
@MainActor
public final class PackageCenter {
    // MARK: - PROPERTY

    public nonisolated static let `default` = PackageCenter()

    /// The handle to what the center knows. Copy it for work off the main actor.
    public internal(set) var index = PackageIndex(db: AptDatabase.shared)

    public private(set) var isLoaded = false

    // MARK: - PACKAGE TABLE

    public struct InstallationInfo: Sendable {
        public let identity: String
        public let version: String
        public let representObject: Package
    }

    // MARK: - RECORDS

    /// a newer trace cancels the one in flight
    var traceTask: Task<Void, Never>?

    /// update blocker
    private let blockedUpdateStore = AptSetting<[String]>(
        key: "\(kPackageCenterIdentity).blockedUpdateTable",
        defaultValue: []
    )
    public var blockedUpdateTable: [String] {
        get { index.blockedUpdateTable }
        set {
            index.blockedUpdateTable = newValue
            blockedUpdateStore.wrappedValue = newValue
            dispatchNotification()
        }
    }

    /// updates an adapter would have to rewrite, off until the user asks
    private let offersAdaptedUpdatesStore = AptSetting<Bool>(
        key: "\(kPackageCenterIdentity).offersAdaptedUpdates",
        defaultValue: false
    )
    public var offersAdaptedUpdates: Bool {
        get { index.offersAdaptedUpdates }
        set {
            index.offersAdaptedUpdates = newValue
            offersAdaptedUpdatesStore.wrappedValue = newValue
            dispatchNotification()
        }
    }

    // MARK: - NOTIFICATIONS

    public nonisolated static let packageRecordChanged = Notification.Name(
        rawValue: "\(kPackageCenterIdentity).packageRecordChanged"
    )
    lazy var notificationThrottle = Throttler(minimumDelay: 0.5)

    // MARK: - INIT

    /// Nothing is read here: the first touch of `default` may come from any
    /// thread, and the work waits for `load()`.
    private nonisolated init() {}

    /// Reads the dpkg status file. Once per process, before
    /// `RepositoryCenter.load()`.
    public func load() async {
        guard !isLoaded else { return }
        isLoaded = true

        aptLog(self, "tracing package status with \(AptEnvironment.current.dpkgStatusLocation)", level: .info)

        index.blockedUpdateTable = blockedUpdateStore.wrappedValue
        index.offersAdaptedUpdates = offersAdaptedUpdatesStore.wrappedValue

        await reloadLocalPackages()
    }
}
