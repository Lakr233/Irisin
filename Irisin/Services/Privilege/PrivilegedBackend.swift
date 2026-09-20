//
//  PrivilegedBackend.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Combine
import Dog
import Foundation
import IrisinClient
import IrisinProtocol

/// The app's one door to root: `irisind` over XPC, and behind it the
/// `irisin-install` helper that carries out the job.
///
/// The app itself never raises privilege. Everything that used to be a
/// `rootspawn` is now an `InstallerJob`, and the answer to "am I privileged"
/// is whatever `DaemonLink.hello()` said, published on `backend` for the
/// screens that show it.
///
/// Nonisolated: `run` suspends on the daemon's transcript and is awaited from
/// wherever the job was asked for, and `start` polls from a detached task.
nonisolated enum PrivilegedBackend {
    static let link = DaemonLink()

    /// The bound backend, nil until the handshake has answered.
    static var backend: DaemonLink.Backend? {
        link.backend
    }

    /// The same answer as it changes. A screen subscribes rather than asking
    /// once: the daemon answers a moment after launch, and a build without
    /// one settles on `.local` after the grace period.
    @MainActor static let backendUpdates = CurrentValueSubject<DaemonLink.Backend?, Never>(nil)

    static var localizedStatus: String {
        switch link.backend {
        case let .daemon(root):
            "irisind · \(root.isEmpty ? "/" : root)"
        case .local:
            String(localized: "You can browse, but not install. Install the Irisin package.")
        case nil:
            String(localized: "Connecting…")
        }
    }

    /// Keeps asking for the daemon until a backend is bound. On a jailbroken
    /// device a miss means launchd has not started it yet, so this never
    /// gives up; a build without a daemon settles on the local backend after
    /// the grace period.
    static func start() {
        link.onLinkLost = {
            Dog.shared.join("PrivilegedBackend", "link to irisind dropped", level: .info)
        }
        Task.detached(priority: .utility) {
            // A miss is the normal case until launchd starts the daemon, so
            // only the first one is worth a line: after that the log would be
            // a heartbeat of the same failure once a second.
            var reportedMiss = false
            while true {
                do {
                    let backend = try await link.hello()
                    Dog.shared.join(
                        "PrivilegedBackend",
                        "backend \(backend) root \(backend.installRoot)",
                        level: .info
                    )
                    // libroot spells the prefix as it was given it, the daemon
                    // resolves its own executable's path: `/var` and
                    // `/private/var` are the same jbroot, so compare resolved.
                    if backend.isPrivileged,
                       backend.installRoot != ProcessPath.canonical(JailbreakRoot.prefix)
                    {
                        Dog.shared.join(
                            "PrivilegedBackend",
                            "daemon root \(backend.installRoot) differs from libroot \(JailbreakRoot.prefix)",
                            level: .warning
                        )
                    }
                    await MainActor.run { backendUpdates.send(backend) }
                    return
                } catch {
                    if !reportedMiss {
                        reportedMiss = true
                        Dog.shared.join(
                            "PrivilegedBackend",
                            "irisind did not answer hello: \(error) — retrying every second",
                            level: .warning
                        )
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    /// Run one job as root and hand every transcript event to `onEvent` as it
    /// arrives, in order. Returns the helper's exit status, or nil when the
    /// job could not be started or the helper died without reporting one.
    ///
    /// Every event is mirrored into the log as it passes, at a level that
    /// matches what it is. `onEvent` draws the operation console, which
    /// lives only as long as the sheet on screen; the helper's own account of
    /// what it did is the one thing a support report cannot be written
    /// without, so it has to outlive that sheet.
    @discardableResult
    static func run(
        _ job: InstallerJob,
        onEvent: @escaping @Sendable (InstallerEvent) async -> Void = { _ in }
    ) async -> Int32? {
        do {
            Dog.shared.join("Installer", "running \(job.name)", level: .info)
            let transcript = try await link.run(job)
            var status: Int32?
            for await event in transcript.events {
                if case let .exit(announced) = event {
                    status = announced
                }
                // a ring's ticks are for the screen, as in the helper's own log
                if case .packageProgress = event {} else {
                    Dog.shared.join("Installer", event.description, level: logLevel(of: event))
                }
                await onEvent(event)
            }
            Dog.shared.join(
                "Installer",
                "\(job.name) ended with status \(status.map(String.init) ?? "none reported")",
                level: status == 0 ? .info : .error
            )
            return status
        } catch let failure as IrisinFailure {
            Dog.shared.join(
                "PrivilegedBackend",
                "\(job.name) refused: \(failure.code) \(failure.systemErrorDescription ?? "")",
                level: .error
            )
            await onEvent(.failure(failure.code == .notPermitted ? .browsingOnly : .helperUnreachable))
            return nil
        } catch {
            Dog.shared.join("PrivilegedBackend", "\(job.name) failed: \(error)", level: .error)
            await onEvent(.failure(.helperUnreachable))
            return nil
        }
    }

    private static func logLevel(of event: InstallerEvent) -> Dog.DogLevel {
        switch event {
        case .started, .phase, .package: .info
        case .warning: .warning
        case .failure: .error
        case .progress, .packageProgress, .script, .output, .notice, .exit: .verbose
        }
    }
}
