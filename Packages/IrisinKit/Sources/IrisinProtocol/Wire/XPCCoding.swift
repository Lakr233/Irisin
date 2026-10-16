#if canImport(XPC)
    import Foundation
    import XPC

    // The one place the wire layout is written down; both ends compile this file.

    public extension IrisinFailure {
        func encode(into reply: xpc_object_t) {
            xpc_dictionary_set_int64(reply, IrisinWire.Key.code, code.rawValue)
            xpc_dictionary_set_int64(reply, IrisinWire.Key.errno, Int64(systemError))
            if let path {
                xpc_dictionary_set_string(reply, IrisinWire.Key.path, path)
            }
        }

        /// The failure a reply carries, or nil when it says `.success`.
        static func decode(_ reply: xpc_object_t) -> IrisinFailure? {
            let code = IrisinReplyCode(rawValue: xpc_dictionary_get_int64(reply, IrisinWire.Key.code))
                ?? .operationFailed
            guard code != .success else { return nil }
            return IrisinFailure(
                code: code,
                systemError: Int32(truncatingIfNeeded: xpc_dictionary_get_int64(reply, IrisinWire.Key.errno)),
                path: xpc_dictionary_get_string(reply, IrisinWire.Key.path).map { String(cString: $0) }
            )
        }
    }

    public extension InstallerJob {
        func encode(into request: xpc_object_t) throws {
            let data = try encoded()
            data.withUnsafeBytes {
                xpc_dictionary_set_data(request, IrisinWire.Key.job, $0.baseAddress!, $0.count)
            }
        }

        /// Decoded and validated, or a refusal. The size cap is checked before a
        /// byte is copied.
        static func decode(from request: xpc_object_t) throws -> InstallerJob {
            var count = 0
            guard let bytes = xpc_dictionary_get_data(request, IrisinWire.Key.job, &count),
                  count > 0, count <= IrisinWire.maximumJobByteCount
            else {
                throw IrisinFailure(code: .invalidRequest)
            }
            return try decode(Data(bytes: bytes, count: count))
        }
    }
    public extension ExternalTransaction.Record {
        /// A transaction's state into a reply: `txid`, `kind`, `state`,
        /// `next`, and `exit`, `package`, `pkgver`, `failure`, `failtext`
        /// when there is one.
        func encode(into reply: xpc_object_t) {
            xpc_dictionary_set_string(reply, IrisinWire.Key.transaction, transaction)
            xpc_dictionary_set_string(reply, IrisinWire.Key.kind, request.kind.rawValue)
            xpc_dictionary_set_string(reply, IrisinWire.Key.state, state.rawValue)
            xpc_dictionary_set_uint64(reply, IrisinWire.Key.nextSequence, nextSequence)
            if let exitStatus {
                xpc_dictionary_set_int64(reply, IrisinWire.Key.exitStatus, Int64(exitStatus))
            }
            if let identity = package?.identity ?? request.identity {
                xpc_dictionary_set_string(reply, IrisinWire.Key.packageIdentity, identity)
            }
            if let version = package?.version {
                xpc_dictionary_set_string(reply, IrisinWire.Key.packageVersion, version)
            }
            if let failure {
                if let problem = failure.problem {
                    xpc_dictionary_set_string(reply, IrisinWire.Key.failure, problem)
                }
                xpc_dictionary_set_string(reply, IrisinWire.Key.failureText, failure.text)
            }
        }
    }

    public extension ExternalTransaction.Event {
        /// One event as a dictionary: `seq`, `kind`, `text`, `raw`, and
        /// whichever of `phase`, `step`, `package`, `pkgver`, `done`,
        /// `total`, `exit` and `failure` (the problem) it has.
        func encoded() -> xpc_object_t {
            let event = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(event, IrisinWire.Key.sequence, sequence)
            xpc_dictionary_set_string(event, IrisinWire.Key.kind, kind)
            xpc_dictionary_set_string(event, IrisinWire.Key.text, text)
            xpc_dictionary_set_string(event, IrisinWire.Key.raw, raw)
            let strings: [(String, String?)] = [
                (IrisinWire.Key.phase, phase), (IrisinWire.Key.step, step),
                (IrisinWire.Key.packageIdentity, identity), (IrisinWire.Key.packageVersion, version),
                (IrisinWire.Key.failure, problem),
            ]
            for case let (key, value?) in strings {
                xpc_dictionary_set_string(event, key, value)
            }
            let numbers: [(String, Int64?)] = [
                (IrisinWire.Key.completed, completed), (IrisinWire.Key.total, total),
                (IrisinWire.Key.exitStatus, exitStatus),
            ]
            for case let (key, value?) in numbers {
                xpc_dictionary_set_int64(event, key, value)
            }
            return event
        }
    }
#endif
