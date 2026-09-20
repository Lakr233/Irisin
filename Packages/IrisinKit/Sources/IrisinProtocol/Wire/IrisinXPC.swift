#if canImport(XPC)
    import CIrisinXPC
    import Dispatch
    import XPC

    /// `xpc_connection_create_mach_service` is not re-exported to Swift, and both
    /// sides need it: the daemon to listen, the app to connect.
    @_silgen_name("xpc_connection_create_mach_service")
    public func irisinCreateMachServiceConnection(
        _ name: UnsafePointer<CChar>,
        _ targetQueue: DispatchQueue?,
        _ flags: UInt64
    ) -> xpc_connection_t?

    /// The XPC constants, read through C rather than through Swift's XPC overlay.
    ///
    /// Naming the SDK's XPC type or connection-error macros in Swift links
    /// `/usr/lib/swift/libswiftXPC.dylib` as a required library, and iOS 15 does
    /// not have it. Through `CIrisinXPC` they are the libSystem globals they
    /// have always been, and the same binary runs on iOS 15 and iOS 26. No Swift
    /// file in this project may spell them directly; `make check` fails on one.
    public enum IrisinXPC {
        /// What `irisinCreateMachServiceConnection` takes as `flags`.
        public enum Flag {
            public static let client: UInt64 = 0
            public static let listener: UInt64 = 1 // XPC_CONNECTION_MACH_SERVICE_LISTENER
        }

        public static var typeBool: xpc_type_t {
            irisin_xpc_type_bool()
        }

        public static var typeConnection: xpc_type_t {
            irisin_xpc_type_connection()
        }

        public static var typeDictionary: xpc_type_t {
            irisin_xpc_type_dictionary()
        }

        public static var errorConnectionInterrupted: xpc_object_t {
            irisin_xpc_error_connection_interrupted()
        }

        public static var errorConnectionInvalid: xpc_object_t {
            irisin_xpc_error_connection_invalid()
        }
    }
#endif
