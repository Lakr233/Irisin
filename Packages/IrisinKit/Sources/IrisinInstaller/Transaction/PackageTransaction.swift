import Foundation
import IrisinProtocol

/// Resources held for one closed transaction. Stage implementations share the
/// same database and filesystem journal; neither is recreated between stages.
final class PackageTransaction {
    let database: PackageDatabase
    let filesystem: PackageFilesystem
    let scripts: MaintainerScripts
    let triggers: Triggers
    let recoveryMode: Bool
    var overrides: PackageOverrides
    let emit: (InstallerEvent) -> Void
    private let preparedDirectory: URL

    init(
        root: URL,
        layout: BootstrapLayout,
        databaseDirectory: URL,
        scriptRoot: String,
        ignoreScriptFailures: Bool,
        recoveryMode: Bool,
        emit: @escaping (InstallerEvent) -> Void
    ) throws {
        database = try PackageDatabase(directory: databaseDirectory)
        filesystem = try PackageFilesystem(root: root, layout: layout, database: databaseDirectory)
        scripts = MaintainerScripts(
            layout: layout,
            database: database,
            scriptRoot: scriptRoot,
            emit: emit,
            ignoreScriptFailures: ignoreScriptFailures,
            forgetPaths: { [filesystem] in filesystem.forgetPaths() }
        )
        triggers = Triggers(database: database, scripts: scripts)
        self.recoveryMode = recoveryMode
        overrides = try PackageOverrides(directory: databaseDirectory)
        self.emit = emit
        preparedDirectory = databaseDirectory.appendingPathComponent("irisin-prepared-" + UUID().uuidString)
    }

    deinit { try? FileManager.default.removeItem(at: preparedDirectory) }

    func writeInfo(_ identity: String, member: String, text: String) throws {
        let path = database.info(identity, member)
        try filesystem.backup(path)
        try database.writeInfo(identity, member: member, text: text)
        try filesystem.noteWritten(path)
    }

    func prepare(_ packages: [InstallerJob.Transaction.Item]) throws -> [String: PackageArchive] {
        var archives: [String: PackageArchive] = [:]
        for item in packages {
            emit(.package(.verifying, identity: item.identity, version: ""))
            archives[item.identity] = try PackageStepFailure.attributing(item.identity, .verifying) { try capture(item) }
        }
        return archives
    }

    private func capture(_ item: InstallerJob.Transaction.Item) throws -> PackageArchive {
        guard try PackageArchive.digest(URL(fileURLWithPath: item.path), md5: false) == item.sha256 else {
            throw PackageFailure("Archive changed: \(item.identity)")
        }
        guard let preparedPath = item.preparedPath, let preparedSHA256 = item.preparedSHA256 else {
            throw PackageFailure("Package has not been prepared: \(item.identity)")
        }
        // Capture app-owned input in the helper's private directory before
        // verifying it. Later script/file reads cannot race changes by mobile.
        // The clone below keeps the app's ownership, so these 0700 are what
        // says the copy is the helper's: mobile still owns the blobs and
        // cannot reach them.
        try FileManager.default.createDirectory(
            at: preparedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let source = URL(fileURLWithPath: preparedPath)
        let captured = preparedDirectory.appendingPathComponent(item.identity)
        let sourceValues = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw PackageFailure("Prepared package is not a directory: \(item.identity)")
        }
        // one call for the whole tree, and its blocks are the app's until
        // either side writes: a theme's four thousand blobs were copied
        // byte for byte before a single one had been verified
        try PackageFilesystem.clone(source, to: captured)
        let archive = try PackageArchive(directory: captured, digest: preparedSHA256, identity: item.identity)
        emit(.notice("Verified \(item.identity) \(archive.version), \(archive.package.entries.count) entries"))
        _ = try Conffiles.declarations(archive.controlText("conffiles"))
        _ = try Triggers.directives(archive.controlText("triggers") ?? "")
        for entry in archive.package.entries {
            if entry.kind == .directory, filesystem.isScaffolding("/" + entry.path) {
                continue
            }
            _ = try filesystem.location(
                overrides.path("/" + entry.path, owner: item.identity),
                for: entry
            )
        }
        return archive
    }

    /// Every stage in order, with a running count of package steps so the
    /// console can show how far along the transaction is.
    func execute(_ stages: [InstallerStage], archives: [String: PackageArchive]) throws {
        let total = stages.reduce(0) { $0 + $1.identities.count }
        var completed = 0
        emit(.progress(completed: completed, total: total))
        func advance() {
            completed += 1
            emit(.progress(completed: completed, total: total))
        }
        for stage in stages {
            switch stage {
            case let .remove(identities):
                for identity in identities {
                    try PackageStepFailure.attributing(identity, .removing) { try remove(identity) }
                    advance()
                }
            case let .unpack(identities):
                for identity in identities {
                    try PackageStepFailure.attributing(identity, .unpacking) {
                        guard let archive = archives[identity] else {
                            throw PackageFailure("Missing prepared package: \(identity)")
                        }
                        try unpack(identity, archive: archive)
                    }
                    advance()
                }
            case let .configure(identities):
                for identity in identities {
                    try PackageStepFailure.attributing(identity, .configuring) { try configure(identity) }
                    advance()
                }
            }
        }
        emit(.phase(.processingTriggers))
        do {
            try triggers.process()
        } catch let failure as ScriptFailure {
            // a postinst that heard `triggered` stops at its own package
            throw PackageStepFailure(identity: failure.identity, step: .triggering, underlying: failure)
        }
        try filesystem.finish()
    }
}
