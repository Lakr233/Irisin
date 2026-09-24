//
//  Installer.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/25.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import AptResolver
import Dog
import Foundation
import IrisinAdapter
import IrisinProtocol

/// Turns one solved plan into one package transaction and runs it through
/// the privileged helper. One operation at a time; the plan is read on the
/// main actor and the files are staged off it. A running operation is an
/// `OperationMonitor`, which the console binds to.
final class Installer {
    static let shared = Installer()

    nonisolated let workingLocation: URL
    private(set) var inProcessingQueue = false

    private init() {
        workingLocation = documentsDirectory.appendingPathComponent("Installer")
        try? Self.reset(workingLocation)
    }

    /// Copies every download the plan installs into the staging directory.
    /// nil when a download is missing, the copy failed, or an operation is
    /// already running out of that directory.
    func createOperationPayload(
        plan: ResolutionPlan,
        ignoreScriptFailures: Bool = false
    ) async -> OperationPayload? {
        guard !inProcessingQueue else {
            Dog.shared.join(self, "refusing to stage a payload while an operation runs", level: .warning)
            return nil
        }
        // Reserve staging across awaits; a second tap must not erase the first
        // payload's files. Each confirmed plan has a separate directory.
        inProcessingQueue = true
        defer { inProcessingQueue = false }
        PackageQueue.shared.operationBegan()
        var sources: [(Package, URL, PackageQueue.PatchedPackage?)] = []
        do {
            guard try await PackageQueue.currency(of: plan, index: PackageCenter.default.index) == .current else {
                // read again, so the queue is solved against what moved and
                // Retry stages that plan, not this one again
                await PackageCenter.default.reloadLocalPackages()
                PackageQueue.shared.solveAgainNow()
                throw ResolutionFailure(message: String(localized: "Packages changed. Review the changes and try again."))
            }
            for package in plan.install {
                var file = package.localFileURL
                if file == nil {
                    file = await Downloads.shared.downloadedFile(for: package)
                }
                guard let file else {
                    throw MissingDownload(identity: package.identity)
                }
                sources.append((package, file, PackageQueue.shared.patched[package]))
            }
            let install = try await Self.stage(sources, at: workingLocation.appendingPathComponent(plan.id.uuidString))
            // checked again after the await: staging takes a while
            guard try await PackageQueue.currency(of: plan, index: PackageCenter.default.index) == .current else {
                await PackageCenter.default.reloadLocalPackages()
                PackageQueue.shared.solveAgainNow()
                throw ResolutionFailure(
                    message: String(localized: "Packages changed while preparing the installation. Try again.")
                )
            }
            let installing = Set(install.map(\.identity))
            let configuring = Set(plan.stages.flatMap { stage -> [String] in
                if case let .configure(names) = stage {
                    return names
                }
                return []
            })
            let transaction = InstallerJob.Transaction(
                install: install,
                remove: plan.remove.map(\.identity),
                stages: plan.stages,
                configureExisting: configuring.subtracting(installing).sorted(),
                autoInstalled: plan.autoInstalled,
                statusDigest: plan.snapshot.statusDigest,
                // read now, not when the plan was solved: a switch turned
                // off since then has the helper refuse the removal
                allowSystemRemoval: PackageQueue.shared.allowSystemRemoval,
                ignoreScriptFailures: ignoreScriptFailures,
                recoveryMode: plan.recoveryMode
            )
            try InstallerJob.transaction(transaction).validate()
            return OperationPayload(plan: plan, transaction: transaction)
        } catch let missing as MissingDownload {
            // not a resolution problem: the plan is fine, the file is not
            // there. The caller asks for it again.
            PackageActionReport.shared.clear()
            Dog.shared.join(self, "download for \(missing.identity) is missing, not staging", level: .warning)
            return nil
        } catch let mismatch as ArchiveMismatch {
            // the file is whole and the listing is wrong: rejected before the
            // helper hears of it, and said out loud, since Retry cannot fix it
            PackageActionReport.shared.clear()
            PackageActionReport.shared.record(
                mismatch.report,
                alertTitle: String(localized: "Package Does Not Match Repository")
            )
            Dog.shared.join(self, "refusing to install: \(mismatch)", level: .error)
            return nil
        } catch {
            // this attempt's reason, not every attempt's
            PackageActionReport.shared.clear()
            PackageActionReport.shared.record(
                (error as? ResolutionFailure)?.message
                    ?? (error as? AdaptationFailure)?.report
                    ?? String(localized: "Unable to prepare the installation. Try again.")
            )
            Dog.shared.join(self, "Cannot prepare transaction: \(error)", level: .error)
            return nil
        }
    }

    /// Stages one local package without asking the resolver to choose or
    /// reject anything around it. The installer still validates the archive,
    /// adapts its architecture when supported and protects file ownership;
    /// package relationships are bypassed and maintainer-script failures are
    /// tolerated by the resulting transaction.
    func createRecoveryOperationPayload(package: Package) async -> OperationPayload? {
        guard package.localFileURL != nil,
              package.supports(anyOf: AptEnvironment.current.installableArchitectures)
        else {
            PackageActionReport.shared.clear()
            PackageActionReport.shared.record(
                String(localized: "This package cannot be installed in Recovery Mode on this system.")
            )
            return nil
        }
        do {
            let plan = try await Self.recoveryPlan(
                for: package,
                index: PackageCenter.default.index
            )
            return await createOperationPayload(plan: plan)
        } catch {
            PackageActionReport.shared.clear()
            PackageActionReport.shared.record(
                String(localized: "Unable to prepare the installation. Try again.")
            )
            Dog.shared.join(self, "Cannot prepare recovery transaction: \(error)", level: .error)
            return nil
        }
    }

    func createRecoveryRemovalPayload(identity: String) async -> OperationPayload? {
        do {
            let plan = try await Self.recoveryRemovalPlan(
                identity: identity,
                index: PackageCenter.default.index,
                allowSystemRemoval: PackageQueue.shared.allowSystemRemoval
            )
            return await createOperationPayload(plan: plan)
        } catch {
            PackageActionReport.shared.clear()
            if let failure = error as? ResolutionFailure {
                PackageActionReport.shared.record(failure.message, checks: failure.checks)
            } else {
                PackageActionReport.shared.record(String(localized: "Unable to prepare this operation. Try again."))
            }
            return nil
        }
    }

    @concurrent
    private nonisolated static func recoveryRemovalPlan(
        identity: String,
        index: PackageIndex,
        allowSystemRemoval: Bool
    ) async throws -> ResolutionPlan {
        try .recoveryRemoval(of: identity, in: index.resolutionSnapshot(), allowSystemRemoval: allowSystemRemoval)
    }

    /// A queued package whose file is not on disk: resumed, not diagnosed.
    private struct MissingDownload: Error {
        let identity: String
    }

    @concurrent
    private nonisolated static func stage(
        _ sources: [(Package, URL, PackageQueue.PatchedPackage?)],
        at location: URL
    ) async throws -> [InstallerJob.Transaction.Item] {
        try reset(location)
        var result: [InstallerJob.Transaction.Item] = []
        for (package, source, patched) in sources {
            let destination = location.appendingPathComponent(package.identity + ".deb")
            try FileManager.default.copyItem(at: source, to: destination)
            let digest = try package.validateArchive(at: destination)
            let prepared = location.appendingPathComponent(package.identity + ".contents")
            var manifestDigest: String
            if let patched {
                // Patch prepared and adapted this file already: its tree is
                // what installs, and the helper checks it against the digest.
                // A copy (a clone, on APFS), so the queue pruning its trees
                // cannot take this one from under the helper
                try FileManager.default.copyItem(at: patched.directory, to: prepared)
                manifestDigest = patched.manifestDigest
            } else {
                manifestDigest = try ArchiveStream.prepareDebianPackage(at: destination, in: prepared)
                // a package built for another bootstrap that Patch never saw
                // (Try Again's re-solved queue) is rewritten here, as mobile,
                // before the helper hears of it; the adapter's failure is
                // this attempt's reason and no transaction starts
                if let adapted = try PackageAdapters.installed.adapt(
                    preparedPackageAt: prepared,
                    on: PackagedArchitecture.architecture
                ) {
                    Dog.shared.join(
                        "Installer",
                        "adapted \(package.identity) for \(PackagedArchitecture.architecture)",
                        level: .info
                    )
                    manifestDigest = adapted
                }
            }
            result.append(.init(
                identity: package.identity,
                path: destination.path,
                sha256: digest,
                preparedPath: prepared.path,
                preparedSHA256: manifestDigest
            ))
        }
        return result
    }

    @concurrent
    private nonisolated static func recoveryPlan(
        for package: Package,
        index: PackageIndex
    ) async throws -> ResolutionPlan {
        try .recoveryInstallation(of: package, in: index.resolutionSnapshot())
    }

    /// Runs the whole transaction through `irisin-install` as root. The
    /// returned monitor publishes the helper's events as they arrive and the
    /// outcome once the installed list has been reloaded; the console binds
    /// to it. The helper holds the compatible database locks and installs
    /// the package files in a session of its own, so a package that replaces
    /// this app still installs to the end.
    func beginOperation(operation: OperationPayload) -> OperationMonitor {
        let monitor = OperationMonitor(operation: operation)
        guard !inProcessingQueue else {
            Dog.shared.join(self, "refusing to begin an operation while one runs", level: .warning)
            let reason = String(
                localized: "Another operation is already running. Wait for it to finish, then try again."
            )
            monitor.finish(.failed(reason))
            return monitor
        }
        inProcessingQueue = true
        PackageQueue.shared.operationBegan()
        Task {
            let outcome = await perform(operation, monitor: monitor)
            // released before the outcome is published: whoever awaits the
            // outcome may begin the next operation straight away, and the
            // queue is settled before anyone looks at it
            inProcessingQueue = false
            PackageQueue.shared.operationFinished(
                plan: operation.plan,
                succeeded: outcome.succeeded,
                dryRun: operation.transaction.dryRun
            )
            monitor.finish(outcome)
        }
        return monitor
    }

    private func perform(_ operation: OperationPayload, monitor: OperationMonitor) async -> OperationMonitor.Outcome {
        guard await (try? PackageQueue.currency(of: operation.plan, index: PackageCenter.default.index)) == .current
        else {
            return .failed(String(localized: "Packages changed. Review the changes and try again."))
        }

        Dog.shared.join(
            self,
            """
            beginning \(operation.transaction.dryRun ? "dry run" : "transaction")
                install: \(operation.transaction.install.map(\.identity).joined(separator: ", "))
                remove: \(operation.transaction.remove.joined(separator: ", "))
                requiresRestart: \(operation.transaction.touchesSelf)
            """,
            level: .info
        )

        if case .daemon = PrivilegedBackend.backend {
            // without one, the refusal that follows says it all
            monitor.append(PrivilegedBackend.localizedStatus)
        }
        let status = await PrivilegedBackend.run(.transaction(operation.transaction)) { event in
            await monitor.record(event)
        }

        // MARK: - FINISH UP

        // the staged copies served their purpose; the downloads themselves stay
        try? FileManager.default.removeItem(at: workingLocation.appendingPathComponent(operation.plan.id.uuidString))
        // the plan's packages the helper got as far as configuring become
        // origins of what dpkg now reports. `configuring` is announced once
        // the record is in dpkg's database at that version; `unpacking` is
        // announced before the attempt, and a reinstall that fails there
        // leaves the old file behind under the same version. A package the
        // run never reached, or a dry run, leaves the previous origin alone.
        let configured = Set(monitor.transcript.compactMap { event -> String? in
            guard case let .package(.configuring, identity, version) = event else { return nil }
            return identity + " " + version
        })
        let sources = operation.transaction.dryRun ? [] : operation.plan.install.filter {
            configured.contains($0.identity + " " + ($0.latestVersion ?? ""))
        }
        await PackageCenter.default.reloadLocalPackages(installedFrom: sources)

        return .init(status: status, failure: monitor.failure)
    }

    private nonisolated static func reset(_ location: URL) throws {
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }
        try FileManager.default.createDirectory(
            at: location,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
