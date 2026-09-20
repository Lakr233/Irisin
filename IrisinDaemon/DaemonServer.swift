import Darwin
import Dispatch
import Foundation
import IrisinProtocol

// XPC's object types carry no Sendable annotation; they are reference-counted
// kernel handles that are safe to pass between queues.
@preconcurrency import XPC

/// The Mach service listener and the one thing it does: start
/// `irisin-install` for an authenticated peer.
///
/// `irisind` is an on-demand LaunchDaemon: launchd starts it when the app
/// looks the service up and it exits once the last client is gone. It keeps
/// no job state, reads no package and waits for nothing: the helper it starts
/// is in its own session, writes into a pipe the app holds the other end of,
/// and outlives this process on purpose, because the package being installed
/// may replace this daemon. `ExecutableWatch` then ends this old image; the
/// package's helper bootstraps and starts the new one.
///
/// Every mutable field is touched only on `controlQueue`: the listener and
/// each peer connection deliver their events there, and the idle timer is
/// scheduled there. That queue confinement is what `@unchecked Sendable`
/// stands for.
final class DaemonServer: @unchecked Sendable {
    private static let idleExitDelay: DispatchTimeInterval = .seconds(3)

    private let controlQueue = DispatchQueue(
        label: "wiki.qaq.irisin.daemon.control",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let installRoot: String
    private let helperPath: String
    private let authenticator: PeerAuthenticator
    /// Keeps the activated listener alive; nothing reads it.
    private var listener: xpc_connection_t?
    private var peers = Set<ObjectIdentifier>()
    private var idleGeneration: UInt64 = 0
    private var nextJobIdentifier: UInt64 = 1

    init(installRoot: String) {
        self.installRoot = installRoot
        helperPath = installRoot + IrisinWire.helperPath
        authenticator = PeerAuthenticator(installRoot: installRoot)
    }

    /// False when the Mach service could not be registered.
    func start() -> Bool {
        controlQueue.sync {
            guard let listener = IrisinWire.serviceName.withCString({
                irisinCreateMachServiceConnection($0, controlQueue, IrisinXPC.Flag.listener)
            }) else {
                return false
            }
            self.listener = listener

            // The helper is started and forgotten; the kernel reaps it. Nothing
            // here ever waits on a child.
            signal(SIGCHLD, SIG_IGN)

            xpc_connection_set_event_handler(listener) { [weak self] event in
                autoreleasepool { self?.accept(event) }
            }
            xpc_connection_activate(listener)
            // A lookup is not a connection: something that resolves the name and
            // then thinks better of it must not leave a resident daemon behind.
            scheduleIdleExit()
            return true
        }
    }

    private func accept(_ event: xpc_object_t) {
        guard xpc_get_type(event) == IrisinXPC.typeConnection else { return }
        guard let pid = authenticator.authenticate(event) else {
            log.warning("peer rejected")
            xpc_connection_cancel(event)
            scheduleIdleExit()
            return
        }
        log.info("peer accepted pid \(pid)")
        let key = ObjectIdentifier(event as AnyObject)
        peers.insert(key)
        xpc_connection_set_target_queue(event, controlQueue)
        xpc_connection_set_event_handler(event) { [weak self] message in
            autoreleasepool { self?.handle(message, connection: event, key: key) }
        }
        xpc_connection_activate(event)
    }

    private func handle(_ message: xpc_object_t, connection: xpc_connection_t, key: ObjectIdentifier) {
        guard peers.contains(key) else { return }
        guard xpc_get_type(message) == IrisinXPC.typeDictionary else {
            // The connection errors arrive here.
            peerInvalidated(key)
            return
        }
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_uint64(reply, IrisinWire.Key.version, IrisinWire.version)

        let operation = IrisinOperation(rawValue: xpc_dictionary_get_uint64(message, IrisinWire.Key.operation))
        do {
            guard xpc_dictionary_get_uint64(message, IrisinWire.Key.version) == IrisinWire.version,
                  let operation
            else {
                throw IrisinFailure(code: .invalidRequest)
            }
            try perform(operation, message: message, into: reply)
            xpc_dictionary_set_int64(reply, IrisinWire.Key.code, IrisinReplyCode.success.rawValue)
        } catch let failure as IrisinFailure {
            failure.encode(into: reply)
            log.warning(
                "\(operation?.name ?? "?", privacy: .public) refused: \(failure.code.rawValue) errno \(failure.systemError)"
            )
        } catch {
            xpc_dictionary_set_int64(reply, IrisinWire.Key.code, IrisinReplyCode.operationFailed.rawValue)
            log.error(
                "\(operation?.name ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
        xpc_connection_send_message(connection, reply)

        if operation == .goodbye {
            xpc_connection_cancel(connection)
            peerInvalidated(key)
        }
    }

    private func perform(_ operation: IrisinOperation, message: xpc_object_t, into reply: xpc_object_t) throws {
        switch operation {
        case .hello:
            xpc_dictionary_set_string(reply, IrisinWire.Key.installRoot, installRoot)
        case .run:
            let job = try InstallerJob.decode(from: message)
            let resolved = try resolve(job)
            let descriptor = try Self.startHelper(at: helperPath, job: resolved)
            let identifier = nextJobIdentifier
            nextJobIdentifier &+= 1
            defer { close(descriptor) }
            log.info("job \(identifier) \(resolved.name, privacy: .public) started")
            xpc_dictionary_set_fd(reply, IrisinWire.Key.descriptor, descriptor)
            xpc_dictionary_set_uint64(reply, IrisinWire.Key.jobIdentifier, identifier)
        case .goodbye:
            break
        }
    }

    /// Every package file the job names, canonicalised and required to be a
    /// regular file. Prepared contents are a directory; the helper captures
    /// and verifies them before executing the transaction.
    private func resolve(_ job: InstallerJob) throws -> InstallerJob {
        guard case var .transaction(transaction) = job else { return job }
        transaction.install = try transaction.install.map { package in
            var info = stat()
            guard let path = ProcessPath.canonical(package.path),
                  stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG
            else {
                throw IrisinFailure(code: .notFound, systemError: ENOENT, path: package.path)
            }
            guard let prepared = package.preparedPath, let preparedPath = ProcessPath.canonical(prepared),
                  stat(preparedPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
            else {
                throw IrisinFailure(code: .invalidRequest)
            }
            var resolvedPackage = package
            resolvedPackage.path = path
            resolvedPackage.preparedPath = preparedPath
            return resolvedPackage
        }
        let resolved = InstallerJob.transaction(transaction)
        try resolved.validate()
        return resolved
    }

    // MARK: - Lifetime

    private func peerInvalidated(_ key: ObjectIdentifier) {
        peers.remove(key)
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        idleGeneration &+= 1
        let scheduled = idleGeneration
        controlQueue.asyncAfter(deadline: .now() + Self.idleExitDelay) { [weak self] in
            guard let self, idleGeneration == scheduled, peers.isEmpty else { return }
            exit(EXIT_SUCCESS)
        }
    }
}
