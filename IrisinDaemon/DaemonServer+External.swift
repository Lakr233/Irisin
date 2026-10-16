import Darwin
import Foundation
import IrisinProtocol

// XPC's object types carry no Sendable annotation; see DaemonServer.
@preconcurrency import XPC

/// The external-client operations: another package's program installs a
/// package by descriptor, removes one by id or resprings, each under a
/// transaction id it chose, and reads the transaction back by that id.
///
/// The daemon still keeps nothing in memory. A transaction is a directory
/// under `IrisinWire.transactionsPath`, root's and open to nobody else:
/// what was asked (`request.json`), the helper's journal, which is the
/// helper's standard output and carries the daemon's exclusive `flock` into
/// the helper, and what an install turned out to be (`package.json`). A
/// daemon restarted mid-run, or a client that reconnects, reads the same
/// directory. `mkdir` is what makes an id taken, so the same id twice is the
/// first transaction's answer and never a second run.
/// `Documentation/ExternalClients.md` is the contract.
extension DaemonServer {
    /// A finished transaction's record is kept this long, then removed the
    /// next time one starts.
    private static let recordLifetime: TimeInterval = 7 * 24 * 60 * 60

    func performExternal(
        _ operation: IrisinOperation,
        message: xpc_object_t,
        into reply: xpc_object_t,
        client: String
    ) throws {
        switch operation {
        case .serviceInfo:
            xpc_dictionary_set_uint64(reply, IrisinWire.Key.externalVersion, IrisinWire.externalVersion)
            xpc_dictionary_set_string(reply, IrisinWire.Key.installRoot, installRoot)
            let capabilities = xpc_array_create(nil, 0)
            for capability in IrisinWire.externalCapabilities {
                xpc_array_append_value(capabilities, xpc_string_create(capability))
            }
            xpc_dictionary_set_value(reply, IrisinWire.Key.capabilities, capabilities)

        case .submitInstall:
            let transaction = try Self.transactionIdentifier(in: message)
            guard let sha256 = xpc_dictionary_get_string(message, IrisinWire.Key.sha256).map({ String(cString: $0) }),
                  InstallerJob.isSHA256Hex(sha256)
            else {
                throw IrisinFailure(code: .invalidRequest)
            }
            let package = xpc_dictionary_dup_fd(message, IrisinWire.Key.descriptor)
            guard package >= 0 else { throw IrisinFailure(code: .invalidRequest) }
            defer { close(package) }
            var info = stat()
            guard fstat(package, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= IrisinWire.maximumPackageByteCount
            else {
                throw IrisinFailure(code: .invalidRequest)
            }
            try begin(
                transaction,
                request: .init(kind: .install, sha256: sha256, created: Date().timeIntervalSince1970, client: client),
                job: .external(.init(transaction: transaction, action: .install(sha256: sha256))),
                package: package,
                into: reply
            )

        case .removePackage:
            let transaction = try Self.transactionIdentifier(in: message)
            guard let identity = xpc_dictionary_get_string(message, IrisinWire.Key.packageIdentity)
                .map({ String(cString: $0) }),
                InstallerJob.isPackageIdentity(identity), !ExternalTransaction.isReserved(identity)
            else {
                throw IrisinFailure(code: .invalidRequest)
            }
            try begin(
                transaction,
                request: .init(kind: .remove, identity: identity, created: Date().timeIntervalSince1970, client: client),
                job: .external(.init(transaction: transaction, action: .remove(identity: identity))),
                package: nil,
                into: reply
            )

        case .respring:
            let transaction = try Self.transactionIdentifier(in: message)
            try begin(
                transaction,
                request: .init(kind: .respring, created: Date().timeIntervalSince1970, client: client),
                job: .respring,
                package: nil,
                into: reply
            )

        case .transactionStatus:
            let transaction = try Self.transactionIdentifier(in: message)
            try record(of: transaction).encode(into: reply)

        case .transactionEvents:
            let transaction = try Self.transactionIdentifier(in: message)
            let record = try record(of: transaction)
            let after = xpc_dictionary_get_uint64(message, IrisinWire.Key.afterSequence)
            let asked = Int(clamping: xpc_dictionary_get_uint64(message, IrisinWire.Key.limit))
            let limit = asked == 0 ? IrisinWire.maximumEventsPerReply : min(asked, IrisinWire.maximumEventsPerReply)
            record.encode(into: reply)
            let events = xpc_array_create(nil, 0)
            for event in record.events(after: after, limit: limit) {
                xpc_array_append_value(events, event.encoded())
            }
            xpc_dictionary_set_value(reply, IrisinWire.Key.events, events)

        case .hello, .run, .goodbye:
            throw IrisinFailure(code: .invalidRequest)
        }
    }

    private static func transactionIdentifier(in message: xpc_object_t) throws -> String {
        guard let text = xpc_dictionary_get_string(message, IrisinWire.Key.transaction).map({ String(cString: $0) }),
              ExternalTransaction.isIdentifier(text)
        else {
            throw IrisinFailure(code: .invalidRequest)
        }
        return text
    }

    private func record(of transaction: String) throws -> ExternalTransaction.Record {
        let directory = ExternalTransaction.directory(installRoot: installRoot, transaction: transaction)
        return try ExternalTransaction.Record.load(directory: directory, transaction: transaction)
    }

    /// Takes the id, writes the request, opens the journal under an
    /// exclusive lock and starts the helper on it. An id already taken
    /// answers with that transaction, marked `dup`, when it asked the same
    /// thing, and `conflict` when it did not.
    private func begin(
        _ transaction: String,
        request: ExternalTransaction.Request,
        job: InstallerJob,
        package: Int32?,
        into reply: xpc_object_t
    ) throws {
        let base = try transactionsDirectory()
        pruneRecords(in: base)
        let directory = base + "/" + transaction
        guard mkdir(directory, 0o700) == 0 else {
            guard errno == EEXIST else { throw IrisinFailure(errno: errno) }
            guard let existing = try? record(of: transaction) else {
                // taken, and its request never written: a daemon that died
                // in between. The id cannot be trusted to mean anything.
                throw IrisinFailure(code: .conflict)
            }
            guard existing.request.isSameRequest(as: request) else { throw IrisinFailure(code: .conflict) }
            existing.encode(into: reply)
            xpc_dictionary_set_bool(reply, IrisinWire.Key.duplicate, true)
            log.info("transaction \(transaction, privacy: .public) submitted again; answered from its record")
            return
        }
        let requestData = try JSONEncoder().encode(request)
        try Self.writeNew(directory + "/" + ExternalTransaction.File.request, requestData)

        let journal = open(
            directory + "/" + ExternalTransaction.File.journal,
            O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard journal >= 0 else { throw IrisinFailure(errno: errno) }
        defer { close(journal) }
        // The helper inherits the open file and with it this lock, and holds
        // it until it exits: a reader that can take the lock knows the
        // helper is gone.
        guard flock(journal, LOCK_EX | LOCK_NB) == 0 else { throw IrisinFailure(errno: errno) }
        do {
            try Self.spawnHelper(at: helperPath, job: job, standardOutput: journal, package: package)
        } catch {
            // The record must end, or it reads as interrupted forever.
            for event in [InstallerEvent.failure(.helperUnreachable), .exit(EX_UNAVAILABLE)] {
                let line = Data((InstallerOutput.encode(event) + "\n").utf8)
                _ = line.withUnsafeBytes { write(journal, $0.baseAddress, $0.count) }
            }
            throw error
        }
        log.info(
            "transaction \(transaction, privacy: .public) \(request.kind.rawValue, privacy: .public) started for \(request.client, privacy: .public)"
        )
        try record(of: transaction).encode(into: reply)
        xpc_dictionary_set_bool(reply, IrisinWire.Key.duplicate, false)
    }

    /// `<root>/var/lib/irisin/transactions`, made where missing: `irisin`
    /// and `transactions` root's and 0700, every level a real directory and
    /// root's, never followed through a link. `<root>/var` itself may be a
    /// link (roothide keeps it in an app group container), so it is resolved
    /// first and only the levels below it are walked.
    private func transactionsDirectory() throws -> String {
        guard let variable = ProcessPath.canonical(installRoot + "/var") else {
            throw IrisinFailure(code: .notFound, systemError: ENOENT, path: installRoot + "/var")
        }
        var path = variable
        for (name, mode) in [("lib", mode_t(0o755)), ("irisin", 0o700), ("transactions", 0o700)] {
            path += "/" + name
            if mkdir(path, mode) != 0, errno != EEXIST {
                throw IrisinFailure(errno: errno, path: path)
            }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
                  info.st_mode & (mode == 0o700 ? 0o077 : 0o022) == 0
            else {
                throw IrisinFailure(code: .notPermitted, systemError: EPERM, path: path)
            }
        }
        return path
    }

    /// Records a week past their last event go. A run the helper did not
    /// finish (the device restarted) leaves its package copy behind; that
    /// goes at once.
    private func pruneRecords(in base: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return }
        let now = Date()
        for name in names where ExternalTransaction.isIdentifier(name) {
            let directory = base + "/" + name
            let journal = directory + "/" + ExternalTransaction.File.journal
            guard !ExternalTransaction.Record.isHeld(journal) else { continue }
            var info = stat()
            let lastWritten = lstat(journal, &info) == 0
                ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                : Date(timeIntervalSince1970: 0)
            if now.timeIntervalSince(lastWritten) > Self.recordLifetime {
                try? FileManager.default.removeItem(atPath: directory)
                continue
            }
            for leftover in [ExternalTransaction.File.archive, ExternalTransaction.File.prepared] {
                try? FileManager.default.removeItem(atPath: directory + "/" + leftover)
            }
        }
    }

    private static func writeNew(_ path: String, _ data: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw IrisinFailure(errno: errno, path: path) }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw IrisinFailure(errno: errno, path: path) }
    }
}
