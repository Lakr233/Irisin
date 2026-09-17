import Darwin
import XPC

// The XPC C API the daemon needs and Swift does not re-export. Declared here
// rather than through a bridging header so the target stays a plain Swift tool.

@_silgen_name("xpc_connection_get_audit_token")
func irisinXPCConnectionGetAuditToken(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

@_silgen_name("xpc_copy_entitlement_for_token")
func irisinXPCCopyEntitlement(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<audit_token_t>
) -> xpc_object_t?
