import CryptoKit
import Darwin
import Foundation
import IrisinPreparation
import IrisinProtocol

/// An external client's transaction, as the helper carries it out.
///
/// The daemon made the transaction's directory (root's, 0700), wrote what
/// was asked and opened the journal as this process's standard output. For
/// an install it passed the client's descriptor through as descriptor 3:
/// the helper copies it into the directory, hashing as it goes, and only the
/// copy is read from then on, so nothing the client does to its own file
/// afterwards reaches the install. The copy must hash to the digest the
/// client named, which is the digest its own approval was bound to.
///
/// Then it is an ordinary transaction: the copy prepared into the
/// directory, captured and verified by `PackageTransaction` as an app's
/// package is, against the status file as it is now. There is no resolver
/// here: a package whose dependencies are not installed fails at
/// `verifying`, and a removal that would leave a dependent broken fails
/// before anything is written.
extension InstallerRunner {
    func runExternal(_ external: InstallerJob.External) -> Int32 {
        let directory = ExternalTransaction.directory(installRoot: installRoot, transaction: external.transaction)
        guard Self.isPrivateDirectory(directory) else {
            emit(.failure(.invalidJob))
            return 64
        }
        switch external.action {
        case let .install(sha256):
            return installExternal(sha256: sha256, directory: directory, transaction: external.transaction)
        case let .remove(identity):
            emit(.notice("Removing \(identity) for an external client"))
            do {
                return try runTransaction(
                    .init(install: [], remove: [identity], statusDigest: currentStatusDigest()),
                    client: .external,
                    clientTransaction: external.transaction
                )
            } catch {
                emit(.failure(.installationStopped(detail: String(describing: error))))
                return 1
            }
        }
    }

    private func installExternal(sha256: String, directory: String, transaction id: String) -> Int32 {
        let archive = URL(fileURLWithPath: directory + "/" + ExternalTransaction.File.archive)
        let prepared = URL(fileURLWithPath: directory + "/" + ExternalTransaction.File.prepared)
        // The run's journal and records stay; the package does not.
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: prepared)
        }
        let transaction: InstallerJob.Transaction
        do {
            let copied = try Self.copyPackage(from: externalPackageDescriptor, to: archive.path)
            guard copied == sha256 else {
                throw ExternalFailure("The package does not hash to the digest the client named")
            }
            emit(.notice("Received the package, SHA-256 \(copied)"))
            let digest = try DebianPreparation.prepare(at: archive, in: prepared)
            let manifest = try JSONDecoder().decode(
                PreparedPackage.self,
                from: Data(contentsOf: prepared.appendingPathComponent("manifest.json"))
            )
            let control = try DebianControl.parse(manifest.control)
            guard let identity = control["package"]?.lowercased(), InstallerJob.isPackageIdentity(identity),
                  let version = control["version"], let architecture = control["architecture"]
            else {
                throw ExternalFailure("The package's control file has no valid Package, Version or Architecture")
            }
            guard !ExternalTransaction.isReserved(identity) else {
                throw ExternalFailure("\(identity) is Irisin's own package")
            }
            guard architecture == "all" || nativeArchitecture.map({ $0 == architecture }) ?? true else {
                throw ExternalFailure("\(identity) is built for \(architecture), not this bootstrap")
            }
            let record = try JSONEncoder().encode(ExternalTransaction.Package(identity: identity, version: version))
            try record.write(to: URL(fileURLWithPath: directory + "/" + ExternalTransaction.File.package))
            transaction = try .init(
                install: [.init(
                    identity: identity,
                    path: archive.path,
                    sha256: copied,
                    preparedPath: prepared.path,
                    preparedSHA256: digest
                )],
                remove: [],
                statusDigest: currentStatusDigest()
            )
        } catch {
            emit(.failure(.installationStopped(detail: String(describing: error))))
            return 1
        }
        return runTransaction(transaction, client: .external, clientTransaction: id)
    }

    /// The architecture dpkg on this bootstrap installs, or nil where any
    /// goes (the harness).
    private var nativeArchitecture: String? {
        switch layout.kind {
        case .none: nil
        case .rootless: "iphoneos-arm64"
        case .roothide: "iphoneos-arm64e"
        }
    }

    /// The status file as it is now. `PackageInstaller` checks it again
    /// under the lock, so a transaction that lands in between is a refusal,
    /// never a stale plan.
    private func currentStatusDigest() throws -> String {
        let status = layout.resolve(layout.bootstrapPath("/Library/dpkg")) + "/status"
        let data = FileManager.default.contents(atPath: status) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The transaction's directory: really a directory, this process's own
    /// (root's on a device) and open to nobody else.
    static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }

    /// Copies a regular file's descriptor, from its start, into a new file
    /// at `path` (never one that exists, never through a link), and returns
    /// the SHA-256 of exactly what was written. Closes the descriptor.
    static func copyPackage(from descriptor: Int32, to path: String) throws -> String {
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ExternalFailure("The package descriptor is not a regular file")
        }
        guard info.st_size > 0, info.st_size <= IrisinWire.maximumPackageByteCount else {
            throw ExternalFailure("The package is empty or larger than Irisin accepts")
        }
        let output = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ExternalFailure("Cannot stage the package: \(String(cString: strerror(errno)))") }
        defer { close(output) }
        var hash = SHA256()
        var offset: off_t = 0
        var total: Int64 = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = pread(descriptor, buffer, 1 << 20, offset)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw ExternalFailure("Cannot read the package: \(String(cString: strerror(errno)))") }
            if count == 0 {
                break
            }
            total += Int64(count)
            guard total <= IrisinWire.maximumPackageByteCount else {
                throw ExternalFailure("The package grew past what Irisin accepts while it was read")
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var written = 0
            while written < count {
                let result = write(output, buffer + written, count - written)
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw ExternalFailure("Cannot stage the package: \(String(cString: strerror(errno)))")
                }
                written += result
            }
            offset += off_t(count)
        }
        guard fsync(output) == 0 else { throw ExternalFailure("Cannot stage the package: \(String(cString: strerror(errno)))") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ExternalFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
