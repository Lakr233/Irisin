// Copyright (c) 2026 OwnGoal Studio. MIT License; see LICENSE.
//
// The client side of irisind's external operations. System libraries only:
// this file and the CIrisinExternalXPC shim are all a client needs.
// Documentation/ExternalClients.md in the Irisin repository is the contract.

import CIrisinExternalXPC
import CryptoKit
import Darwin
import Dispatch
import Foundation
import XPC

/// `xpc_connection_create_mach_service` is not re-exported to Swift.
@_silgen_name("xpc_connection_create_mach_service")
private func irisinExternalCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ targetQueue: DispatchQueue?,
    _ flags: UInt64
) -> xpc_connection_t?

/// The wire, as the daemon reads it. Every request is an XPC dictionary with
/// `v` (the base protocol version, 3) and `op`; every reply carries `v` and
/// `code`, 0 for success.
public enum IrisinExternalWire {
    public static let serviceName = "wiki.qaq.irisin.service"
    public static let baseVersion: UInt64 = 3
    /// The external protocol version this client was written against.
    public static let externalVersion: UInt64 = 1
    /// The entitlement a client must carry, strictly `true`, beside
    /// `platform-application` and `com.apple.private.security.no-sandbox`.
    public static let clientEntitlement = "wiki.qaq.irisin.client"

    public enum Operation: UInt64, Sendable {
        case serviceInfo = 4
        case submitInstall = 5
        case transactionStatus = 6
        case transactionEvents = 7
        case removePackage = 8
        case respring = 9
    }

    public enum Key {
        public static let version = "v"
        public static let operation = "op"
        public static let code = "code"
        public static let errno = "errno"
        public static let installRoot = "root"
        public static let descriptor = "fd"
        public static let externalVersion = "xv"
        public static let capabilities = "caps"
        public static let transaction = "txid"
        public static let sha256 = "sha256"
        public static let packageIdentity = "package"
        public static let packageVersion = "pkgver"
        public static let kind = "kind"
        public static let state = "state"
        public static let duplicate = "dup"
        public static let exitStatus = "exit"
        public static let failure = "failure"
        public static let failureText = "failtext"
        public static let nextSequence = "next"
        public static let afterSequence = "after"
        public static let limit = "limit"
        public static let events = "events"
        public static let sequence = "seq"
        public static let text = "text"
        public static let phase = "phase"
        public static let step = "step"
        public static let completed = "done"
        public static let total = "total"
        public static let raw = "raw"
    }
}

/// Why a call did not answer.
public struct IrisinClientError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: Equatable, Sendable {
        // The daemon's reply codes.
        case invalidRequest // 1
        case notPermitted // 2
        case notFound // 3
        case operationFailed // 4
        case conflict // 5
        /// A reply code this client does not know.
        case unknownReply(Int64)
        /// The connection was refused or the service does not exist: Irisin
        /// is not installed, or its daemon did not admit this program.
        /// irisind is on-demand; a client keeps retrying for a while before
        /// it concludes either.
        case serviceUnavailable
        /// The connection dropped before the reply. The daemon exits when
        /// idle and may be replaced by an update; ask again.
        case connectionInterrupted
        /// The daemon answered `serviceInfo` as an unknown operation: an
        /// Irisin older than 4.7, with no external operations at all.
        case serviceTooOld
        /// The reply lacked a field the contract promises.
        case malformedReply
    }

    public var code: Code
    /// The daemon's `errno`, or 0.
    public var systemError: Int32

    public init(_ code: Code, systemError: Int32 = 0) {
        self.code = code
        self.systemError = systemError
    }

    public var description: String {
        systemError == 0 ? "\(code)" : "\(code) (errno \(systemError): \(String(cString: strerror(systemError))))"
    }
}

public struct IrisinServiceInfo: Equatable, Sendable {
    public var externalVersion: UInt64
    public var capabilities: Set<String>
    /// The install root the daemon derived from its own path.
    public var installRoot: String
}

public enum IrisinTransactionState: String, Sendable {
    case running, succeeded, failed, interrupted

    public var isFinished: Bool {
        self != .running
    }
}

public struct IrisinTransactionStatus: Equatable, Sendable {
    public var transaction: UUID
    /// `install`, `remove` or `respring`.
    public var kind: String
    public var state: IrisinTransactionState
    /// One more than the last event's sequence.
    public var nextSequence: UInt64
    public var exitStatus: Int64?
    public var packageIdentity: String?
    public var packageVersion: String?
    /// The last failure's problem name (`packageFailed`, ...), and its text.
    public var failure: String?
    public var failureText: String?
    /// True when a submission named an id already taken by the same
    /// request: nothing new was started, this is that transaction.
    public var duplicate: Bool
}

public struct IrisinTransactionEvent: Equatable, Sendable {
    public var sequence: UInt64
    public var kind: String
    public var text: String
    public var phase: String?
    public var step: String?
    public var packageIdentity: String?
    public var packageVersion: String?
    public var completed: Int64?
    public var total: Int64?
    public var exitStatus: Int64?
    /// For `warning` and `failure`, the problem's name.
    public var problem: String?
    /// Irisin's own JSON line for the event. Its shape is Irisin's and may
    /// change in any release; the fields above do not.
    public var raw: String
}

/// One connection to irisind. Every call is one request with an
/// asynchronous reply; a dropped connection is made again by the next call.
public final class IrisinExternalClient: @unchecked Sendable {
    private let serviceName: String
    private let queue = DispatchQueue(label: "wiki.qaq.irisin.external-client", qos: .userInitiated)
    private let lock = NSLock()
    private var connection: xpc_connection_t?

    public init(serviceName: String = IrisinExternalWire.serviceName) {
        self.serviceName = serviceName
    }

    deinit {
        if let connection {
            xpc_connection_cancel(connection)
        }
    }

    public func invalidate() {
        lock.lock()
        let existing = connection
        connection = nil
        lock.unlock()
        if let existing {
            xpc_connection_cancel(existing)
        }
    }

    // MARK: - Operations

    /// The handshake. `serviceTooOld` from an Irisin before 4.7.
    public func serviceInfo() async throws -> IrisinServiceInfo {
        let reply: xpc_object_t
        do {
            reply = try await send(.serviceInfo) { _ in }
        } catch let error as IrisinClientError where error.code == .invalidRequest {
            throw IrisinClientError(.serviceTooOld)
        }
        guard let root = string(reply, IrisinExternalWire.Key.installRoot),
              let capabilities = xpc_dictionary_get_value(reply, IrisinExternalWire.Key.capabilities),
              xpc_get_type(capabilities) == irisin_external_xpc_type_array()
        else {
            throw IrisinClientError(.malformedReply)
        }
        var names = Set<String>()
        for index in 0 ..< xpc_array_get_count(capabilities) {
            if let name = xpc_array_get_string(capabilities, index) {
                names.insert(String(cString: name))
            }
        }
        return IrisinServiceInfo(
            externalVersion: xpc_dictionary_get_uint64(reply, IrisinExternalWire.Key.externalVersion),
            capabilities: names,
            installRoot: root
        )
    }

    /// Installs the `.deb` open on `descriptor`, which must be a regular
    /// file whose contents hash to `sha256` (64 lowercase hex digits). The
    /// daemon's helper copies the file from offset 0 before reading it, and
    /// installs only the copy. The descriptor stays the caller's to close.
    /// Submitting the same `transaction` again returns that transaction,
    /// `duplicate` set, and installs nothing.
    public func submitInstall(transaction: UUID, packageDescriptor descriptor: Int32, sha256: String) async throws
        -> IrisinTransactionStatus
    {
        let reply = try await send(.submitInstall) { request in
            xpc_dictionary_set_string(request, IrisinExternalWire.Key.transaction, Self.spell(transaction))
            xpc_dictionary_set_string(request, IrisinExternalWire.Key.sha256, sha256)
            xpc_dictionary_set_fd(request, IrisinExternalWire.Key.descriptor, descriptor)
        }
        return try status(reply)
    }

    /// Removes one installed package by id. Nothing depending on it is
    /// removed with it; such a removal fails.
    public func removePackage(transaction: UUID, packageIdentity: String) async throws -> IrisinTransactionStatus {
        let reply = try await send(.removePackage) { request in
            xpc_dictionary_set_string(request, IrisinExternalWire.Key.transaction, Self.spell(transaction))
            xpc_dictionary_set_string(request, IrisinExternalWire.Key.packageIdentity, packageIdentity)
        }
        return try status(reply)
    }

    public func respring(transaction: UUID) async throws -> IrisinTransactionStatus {
        let reply = try await send(.respring) { request in
            xpc_dictionary_set_string(request, IrisinExternalWire.Key.transaction, Self.spell(transaction))
        }
        return try status(reply)
    }

    public func status(of transaction: UUID) async throws -> IrisinTransactionStatus {
        let reply = try await send(.transactionStatus) { request in
            xpc_dictionary_set_string(request, IrisinExternalWire.Key.transaction, Self.spell(transaction))
        }
        return try status(reply)
    }

    /// The transaction's state and its events after `after`, at most
    /// `limit` (0 or over 256 means 256).
    public func events(of transaction: UUID, after: UInt64, limit: Int = 256) async throws
        -> (status: IrisinTransactionStatus, events: [IrisinTransactionEvent])
    {
        let reply = try await send(.transactionEvents) { request in
            xpc_dictionary_set_string(request, IrisinExternalWire.Key.transaction, Self.spell(transaction))
            xpc_dictionary_set_uint64(request, IrisinExternalWire.Key.afterSequence, after)
            xpc_dictionary_set_uint64(request, IrisinExternalWire.Key.limit, UInt64(max(0, limit)))
        }
        guard let array = xpc_dictionary_get_value(reply, IrisinExternalWire.Key.events),
              xpc_get_type(array) == irisin_external_xpc_type_array()
        else {
            throw IrisinClientError(.malformedReply)
        }
        var events: [IrisinTransactionEvent] = []
        for index in 0 ..< xpc_array_get_count(array) {
            let item = xpc_array_get_value(array, index)
            guard xpc_get_type(item) == irisin_external_xpc_type_dictionary(),
                  let kind = string(item, IrisinExternalWire.Key.kind),
                  let text = string(item, IrisinExternalWire.Key.text)
            else {
                throw IrisinClientError(.malformedReply)
            }
            events.append(IrisinTransactionEvent(
                sequence: xpc_dictionary_get_uint64(item, IrisinExternalWire.Key.sequence),
                kind: kind,
                text: text,
                phase: string(item, IrisinExternalWire.Key.phase),
                step: string(item, IrisinExternalWire.Key.step),
                packageIdentity: string(item, IrisinExternalWire.Key.packageIdentity),
                packageVersion: string(item, IrisinExternalWire.Key.packageVersion),
                completed: integer(item, IrisinExternalWire.Key.completed),
                total: integer(item, IrisinExternalWire.Key.total),
                exitStatus: integer(item, IrisinExternalWire.Key.exitStatus),
                problem: string(item, IrisinExternalWire.Key.failure),
                raw: string(item, IrisinExternalWire.Key.raw) ?? ""
            ))
        }
        return (try status(reply), events)
    }

    /// Every event after `after`, as they are written, ending once the
    /// transaction has finished and its last event was delivered. Polls
    /// every `interval`; a dropped connection is retried, so a daemon
    /// replaced mid-run (Irisin updating itself) loses nothing.
    public func follow(
        _ transaction: UUID,
        after: UInt64 = 0,
        interval: TimeInterval = 0.25
    ) -> AsyncThrowingStream<IrisinTransactionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = after
                var retries = 0
                while !Task.isCancelled {
                    do {
                        let batch = try await self.events(of: transaction, after: cursor)
                        retries = 0
                        for event in batch.events {
                            continuation.yield(event)
                            cursor = event.sequence
                        }
                        if batch.status.state.isFinished, cursor + 1 >= batch.status.nextSequence {
                            continuation.finish()
                            return
                        }
                        if !batch.events.isEmpty, cursor + 1 < batch.status.nextSequence {
                            continue
                        }
                    } catch let error as IrisinClientError
                        where error.code == .connectionInterrupted || error.code == .serviceUnavailable
                    {
                        retries += 1
                        // about a minute of absence before giving up
                        if retries > Int(60 / max(interval, 0.05)) {
                            continuation.finish(throwing: error)
                            return
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.05) * 1_000_000_000))
                }
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// SHA-256 of a regular file's whole contents, read from offset 0 with
    /// `pread`, as the helper will hash its copy. Lowercase hex.
    public static func sha256(ofDescriptor descriptor: Int32) throws -> String {
        var hash = SHA256()
        var offset: off_t = 0
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = pread(descriptor, buffer, size, offset)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw IrisinClientError(.operationFailed, systemError: errno) }
            if count == 0 {
                break
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            offset += off_t(count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Transport

    /// The id as the daemon spells it: lowercase.
    static func spell(_ transaction: UUID) -> String {
        transaction.uuidString.lowercased()
    }

    private func send(
        _ operation: IrisinExternalWire.Operation,
        fill: (xpc_object_t) -> Void
    ) async throws -> xpc_object_t {
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(request, IrisinExternalWire.Key.version, IrisinExternalWire.baseVersion)
        xpc_dictionary_set_uint64(request, IrisinExternalWire.Key.operation, operation.rawValue)
        fill(request)
        let connection = try activeConnection()
        let reply: xpc_object_t = try await withCheckedThrowingContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, request, queue) { reply in
                if xpc_get_type(reply) == irisin_external_xpc_type_dictionary() {
                    continuation.resume(returning: reply)
                } else {
                    self.invalidate()
                    let code: IrisinClientError.Code = reply === irisin_external_xpc_error_connection_invalid()
                        ? .serviceUnavailable : .connectionInterrupted
                    continuation.resume(throwing: IrisinClientError(code))
                }
            }
        }
        let code = xpc_dictionary_get_int64(reply, IrisinExternalWire.Key.code)
        guard code == 0 else {
            let systemError = Int32(truncatingIfNeeded: xpc_dictionary_get_int64(reply, IrisinExternalWire.Key.errno))
            let mapped: IrisinClientError.Code = switch code {
            case 1: .invalidRequest
            case 2: .notPermitted
            case 3: .notFound
            case 4: .operationFailed
            case 5: .conflict
            default: .unknownReply(code)
            }
            throw IrisinClientError(mapped, systemError: systemError)
        }
        return reply
    }

    private func activeConnection() throws -> xpc_connection_t {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            return connection
        }
        guard let created = serviceName.withCString({ irisinExternalCreateMachServiceConnection($0, queue, 0) }) else {
            throw IrisinClientError(.serviceUnavailable)
        }
        xpc_connection_set_event_handler(created) { _ in }
        xpc_connection_activate(created)
        connection = created
        return created
    }

    private func status(_ reply: xpc_object_t) throws -> IrisinTransactionStatus {
        guard let text = string(reply, IrisinExternalWire.Key.transaction), let transaction = UUID(uuidString: text),
              let kind = string(reply, IrisinExternalWire.Key.kind),
              let state = string(reply, IrisinExternalWire.Key.state).flatMap(IrisinTransactionState.init(rawValue:))
        else {
            throw IrisinClientError(.malformedReply)
        }
        return IrisinTransactionStatus(
            transaction: transaction,
            kind: kind,
            state: state,
            nextSequence: xpc_dictionary_get_uint64(reply, IrisinExternalWire.Key.nextSequence),
            exitStatus: integer(reply, IrisinExternalWire.Key.exitStatus),
            packageIdentity: string(reply, IrisinExternalWire.Key.packageIdentity),
            packageVersion: string(reply, IrisinExternalWire.Key.packageVersion),
            failure: string(reply, IrisinExternalWire.Key.failure),
            failureText: string(reply, IrisinExternalWire.Key.failureText),
            duplicate: xpc_dictionary_get_bool(reply, IrisinExternalWire.Key.duplicate)
        )
    }

    private func string(_ dictionary: xpc_object_t, _ key: String) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }

    /// An int64 field, or nil when the dictionary has none.
    private func integer(_ dictionary: xpc_object_t, _ key: String) -> Int64? {
        xpc_dictionary_get_value(dictionary, key) == nil ? nil : xpc_dictionary_get_int64(dictionary, key)
    }
}
