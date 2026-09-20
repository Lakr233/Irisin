import CryptoKit
import Foundation
@testable import IrisinInstaller
import IrisinProtocol

/// Real files and scripts under one disposable root, with no device database.
final class NativeInstallFixture {
    let root: URL
    let database: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native installer " + UUID().uuidString).resolvingSymlinksInPath()
        database = root.appendingPathComponent("Library/dpkg")
        try FileManager.default.createDirectory(at: database.appendingPathComponent("info"), withIntermediateDirectories: true)
        try Data().write(to: database.appendingPathComponent("status"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// `spelledAs` is the name the control file carries when it differs from
    /// the identity the transaction uses, as a mixed-case `Package:` does.
    func package(_ identity: String = "example.package", spelledAs: String? = nil, version: String = "1", files: [String: String] = [:], controls: [String: String] = [:], fields: [String: String] = [:], links: [PreparedEntry] = []) throws -> InstallerJob.Transaction.Item {
        let staging = root.appendingPathComponent("staging " + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var count = 0
        func blob(_ text: String) throws -> PreparedFile {
            let data = Data(text.utf8)
            let name = "blob-\(count)"
            count += 1
            try data.write(to: staging.appendingPathComponent(name))
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return PreparedFile(name: name, sha256: PackageArchive.sha256(data), md5: md5, size: Int64(data.count))
        }
        var metadata = fields
        metadata["package"] = spelledAs ?? identity
        metadata["version"] = version
        metadata["architecture"] = fields["architecture"] ?? "all"
        metadata["description"] = "Synthetic test package"
        var controlFiles: [String: PreparedFile] = [:]
        for (name, text) in controls {
            controlFiles[name] = try blob(text)
        }
        var entries = links
        for (path, text) in files {
            try entries.append(PreparedEntry(path: path, kind: .file, file: blob(text), mode: 0o644, uid: 0, gid: 0, modificationTime: 0))
        }
        let manifest = PreparedPackage(control: PackageDatabase.paragraph(metadata), controlFiles: controlFiles, entries: entries)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: staging.appendingPathComponent("manifest.json"))
        let deb = staging.appendingPathComponent("package.deb")
        try Data().write(to: deb)
        return .init(identity: identity, path: deb.path, preparedPath: staging.path, preparedSHA256: PackageArchive.sha256(data))
    }

    func run(install: [InstallerJob.Transaction.Item] = [], remove: [String] = [], autoInstalled: [String] = [], dryRun: Bool = false, allowSystemRemoval: Bool = false, ignoreScriptFailures: Bool = false, recoveryMode: Bool = false, layout: BootstrapLayout = .init(kind: .none), emit: @escaping (InstallerEvent) -> Void = { _ in }) throws {
        let status = (try? Data(contentsOf: database.appendingPathComponent("status"))) ?? Data()
        let transaction = InstallerJob.Transaction(install: install, remove: remove, dryRun: dryRun, autoInstalled: autoInstalled, statusDigest: PackageArchive.sha256(status), allowSystemRemoval: allowSystemRemoval, ignoreScriptFailures: ignoreScriptFailures, recoveryMode: recoveryMode)
        let installer = PackageInstaller(installRoot: root.path, layout: layout, databaseDirectory: database, scriptRoot: root.path, emit: emit)
        try installer.run(transaction)
    }

    func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// apt's extended_states under the root, or nil when nothing wrote it.
    func markings() -> String? {
        try? text("var/lib/apt/extended_states")
    }

    func status(_ identity: String = "example.package") throws -> String? {
        try PackageDatabase(directory: database).records[identity]?["status"]
    }
}
