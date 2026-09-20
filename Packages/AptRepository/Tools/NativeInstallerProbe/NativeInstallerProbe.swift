import AptRepository
import Foundation
import IrisinInstaller
import IrisinProtocol

/// Development-only driver: decode real .deb files with the app's libarchive
/// adapter and execute a closed transaction against a disposable test root.
@main enum NativeInstallerProbe {
    static func main() throws {
        let input = try JSONDecoder().decode(
            NativeProbeInput.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        var packages: [InstallerJob.Transaction.Item] = []
        for (identity, path) in input.archives.sorted(by: { $0.key < $1.key }) {
            let archive = URL(fileURLWithPath: path)
            let prepared = URL(fileURLWithPath: input.root).appendingPathComponent("prepared-" + identity)
            let manifestDigest = try ArchiveStream.prepareDebianPackage(at: archive, in: prepared)
            try packages.append(.init(
                identity: identity,
                path: path,
                sha256: Package.archiveDigest(at: archive),
                preparedPath: prepared.path,
                preparedSHA256: manifestDigest
            ))
        }
        let database = URL(fileURLWithPath: input.database)
        let status = try Data(contentsOf: database.appendingPathComponent("status"))
        let transaction = InstallerJob.Transaction(
            install: packages,
            remove: input.remove,
            stages: input.stages,
            statusDigest: ResolutionSnapshot.digest(status)
        )
        if CommandLine.arguments.contains("--prepare-only") {
            try print(String(decoding: InstallerJob.transaction(transaction).encoded(), as: UTF8.self))
            return
        }
        let installer = PackageInstaller(
            installRoot: input.root,
            layout: .init(kind: .none),
            databaseDirectory: database,
            scriptRoot: input.root
        ) { print($0) }
        try installer.run(transaction)
    }
}
