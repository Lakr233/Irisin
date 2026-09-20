import CryptoKit
import Darwin
import Foundation
import IrisinProtocol

/// Executes the resolver's closed stages without invoking apt or dpkg. Archive
/// decoding stays in the app; only verified blobs, scripts and metadata reach
/// this implementation. The standard dpkg database remains authoritative.
///
/// What it says while it works is an `InstallerEvent` per line: the phase it
/// is in, each package step with a running count, every script it starts and
/// every line one prints. The app draws a progress bar from the count and
/// spells the steps in its own language.
public final class PackageInstaller {
    private let root: URL
    private let layout: BootstrapLayout
    private let databaseDirectory: URL
    private let scriptRoot: String
    private let emit: (InstallerEvent) -> Void

    public init(
        installRoot: String,
        layout: BootstrapLayout,
        databaseDirectory: URL? = nil,
        scriptRoot: String = "",
        emit: @escaping (InstallerEvent) -> Void
    ) {
        root = URL(fileURLWithPath: installRoot.isEmpty ? "/" : installRoot).resolvingSymlinksInPath()
        self.layout = layout
        self.databaseDirectory = databaseDirectory
            ?? URL(fileURLWithPath: layout.resolve(layout.bootstrapPath("/Library/dpkg")))
        self.scriptRoot = scriptRoot
        self.emit = emit
    }

    public func run(_ transaction: InstallerJob.Transaction) throws {
        try InstallerJob.transaction(transaction).validate()
        emit(.phase(.preparing))
        // A bootstrap that has not written its database yet gets one; the
        // lock files below are created, not found.
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let frontend = try DpkgLock(path: databaseDirectory.appendingPathComponent("lock-frontend").path)
        defer { frontend.close() }
        let backend = try DpkgLock(path: databaseDirectory.appendingPathComponent("lock").path)
        defer { backend.close() }
        // Missing is empty: the app digests the same absence the same way.
        let status = (try? Data(contentsOf: databaseDirectory.appendingPathComponent("status"))) ?? Data()
        guard PackageArchive.sha256(status) == transaction.statusDigest else {
            throw PackageFailure("Installed state changed. Resolve and confirm the transaction again.")
        }
        emit(.notice(
            "Database \(databaseDirectory.path), "
                + "\(transaction.install.count) to install, \(transaction.remove.count) to remove"
        ))
        let work = try PackageTransaction(
            root: root,
            layout: layout,
            databaseDirectory: databaseDirectory,
            scriptRoot: scriptRoot,
            ignoreScriptFailures: transaction.ignoreScriptFailures || transaction.recoveryMode,
            recoveryMode: transaction.recoveryMode,
            emit: emit
        )
        if !transaction.dryRun {
            try work.filesystem.recover()
        }
        emit(.phase(.verifying))
        let archives = try work.prepare(transaction.install)
        if transaction.recoveryMode {
            try work.validateRecoveryRemoval(transaction)
        } else {
            try work.validateFinalState(transaction, archives: archives)
        }
        if transaction.dryRun {
            for stage in transaction.stages {
                emit(.notice("Dry run: \(Self.describe(stage))"))
            }
            return
        }
        try work.database.consolidate()
        emit(.phase(.applying))
        // a stage that fails leaves the ones before it done: their marks
        // are written all the same, still under the frontend lock
        defer { saveMarkings(transaction, records: work.database.records) }
        try work.execute(transaction.stages, archives: archives)
        let configured = transaction.install.map(\.identity) + transaction.configureExisting
        guard configured.allSatisfy({ work.database.records[$0]?["status"]?.hasSuffix(" installed") == true }) else {
            throw PackageFailure("Some packages still require configuration or trigger processing")
        }
    }

    /// apt's `extended_states`, where `apt autoremove` reads which packages
    /// only a dependency asked for. The paragraphs of the identities this
    /// transaction touched are rewritten from what the database now holds;
    /// every other paragraph, one this cannot read included, stays as it is.
    /// A mark that cannot be saved never fails the transaction.
    private func saveMarkings(_ transaction: InstallerJob.Transaction, records: [String: [String: String]]) {
        let installing = Set(transaction.install.map(\.identity))
        let touched = installing.union(transaction.remove)
        let url = root.appendingPathComponent("var/lib/apt/extended_states")
        do {
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                text = ""
            }
            let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let kept = paragraphs.filter { paragraph in
                guard let name = (try? DebianControl.parse(paragraph))?["package"]?.lowercased(),
                      touched.contains(name)
                else { return true }
                return !installing.contains(name) && PackageDatabase.isPresent(records[name])
            }
            let marked = transaction.autoInstalled.compactMap { identity -> String? in
                guard let fields = records[identity], PackageDatabase.isPresent(fields) else { return nil }
                return "Package: \(identity)\nArchitecture: \(fields["architecture"] ?? "all")\nAuto-Installed: 1"
            }
            guard kept.count != paragraphs.count || !marked.isEmpty else { return }
            let contents = kept + marked
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PackageDatabase.write(
                Data(contents.map { $0 + "\n" }.joined(separator: "\n").utf8),
                to: url
            )
        } catch {
            emit(.warning(.markingsNotSaved(detail: String(describing: error))))
        }
    }

    private static func describe(_ stage: InstallerStage) -> String {
        switch stage {
        case let .remove(identities): "remove " + identities.joined(separator: ", ")
        case let .unpack(identities): "unpack " + identities.joined(separator: ", ")
        case let .configure(identities): "configure " + identities.joined(separator: ", ")
        }
    }
}
