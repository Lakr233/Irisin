import CoreFoundation
import Darwin
import XPC

// The XPC C API the daemon needs and Swift does not re-export. Declared here
// rather than through a bridging header so the target stays a plain Swift tool.

@_silgen_name("xpc_connection_get_audit_token")
func irisinXPCConnectionGetAuditToken(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

/// The value of entitlement `name` for the process behind `token`, as an
/// XPC object, or nil when it has none.
///
/// `xpc_copy_entitlement_for_token` is looked up, never linked: a strong
/// import of a symbol the running system lacks stops the daemon in dyld
/// before `main`, and nothing says whether iOS 15 has this one. Where it is
/// missing, Security's `SecTask` answers the same question from the same
/// token (looked up too: iOS has no header for it), a boolean as a boolean.
func irisinXPCCopyEntitlement(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<audit_token_t>
) -> xpc_object_t? {
    switch EntitlementLookup.resolved {
    case let .xpc(copy):
        guard let value = copy(name, token) else { return nil }
        guard let object = Unmanaged<AnyObject>.fromOpaque(value).takeRetainedValue() as? xpc_object_t else {
            log.fault("xpc_copy_entitlement_for_token answered with something that is not an XPC object")
            return nil
        }
        return object
    case let .secTask(create, copyValue):
        guard let task = create(nil, token.pointee) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(task).release() }
        let key = String(cString: name) as CFString
        guard let raw = copyValue(task, key, nil) else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeRetainedValue()
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return xpc_bool_create(CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)))
    case .none:
        return nil
    }
}

private enum EntitlementLookup {
    typealias XPCCopy = @convention(c) (
        UnsafePointer<CChar>, UnsafeMutablePointer<audit_token_t>
    ) -> UnsafeMutableRawPointer?
    typealias SecTaskCreate = @convention(c) (UnsafeRawPointer?, audit_token_t) -> UnsafeMutableRawPointer?
    typealias SecTaskCopyValue = @convention(c) (
        UnsafeMutableRawPointer, CFString, UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?

    case xpc(XPCCopy)
    case secTask(SecTaskCreate, SecTaskCopyValue)
    case none

    static let resolved: EntitlementLookup = {
        // each symbol from its own library, never the first image in load
        // order that happens to export the name
        let xpc = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY | RTLD_NOLOAD)
        if let copy: XPCCopy = symbol("xpc_copy_entitlement_for_token", in: xpc) {
            return .xpc(copy)
        }
        let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        if let create: SecTaskCreate = symbol("SecTaskCreateWithAuditToken", in: security),
           let copyValue: SecTaskCopyValue = symbol("SecTaskCopyValueForEntitlement", in: security)
        {
            log.notice("entitlements are read through SecTask: libxpc has no xpc_copy_entitlement_for_token")
            return .secTask(create, copyValue)
        }
        // every peer is refused from here on; say so once
        log.fault("no way to read a peer's entitlements; every client will be refused")
        return .none
    }()

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle else { return nil }
        return dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
}
