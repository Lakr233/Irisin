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
#endif
