import Darwin
import Foundation
import IrisinProtocol
import XPC

/// The whole trust boundary.
///
/// `irisind` runs as root and starts a helper that runs dpkg, so the only
/// thing that keeps it from being a privilege-escalation service for every
/// process on the device is this check, and it runs before a single request
/// field is read.
///
/// The check is on the kernel's audit token, not on anything the peer told
/// us: the token is filled in by the kernel for the connection, so a caller
/// cannot forge its pid, its uid or its entitlements.
struct PeerAuthenticator {
    private static let mobileUserID: UInt32 = 501
    /// A sandboxed App Store app cannot obtain these, and the first is ours
    /// alone.
    private static let requiredEntitlements = [
        IrisinWire.clientEntitlement,
        "platform-application",
        "com.apple.private.security.no-sandbox",
    ]

    private let clientPaths: [String]

    init(installRoot: String) {
        clientPaths = IrisinWire.clientPaths.compactMap { ProcessPath.canonical(installRoot + $0) }
    }

    /// The peer's pid when it may be served, nil when the connection must be
    /// cancelled.
    func authenticate(_ connection: xpc_connection_t) -> Int32? {
        var token = audit_token_t()
        irisinXPCConnectionGetAuditToken(connection, &token)
        let pid = Int32(bitPattern: token.val.5)

        // Identity is the executable on disk, not the bundle id, and the file
        // at that path must be one no less privileged process could have
        // swapped out from under us.
        guard pid > 1,
              token.val.1 == 0 || token.val.1 == Self.mobileUserID,
              hasRequiredEntitlements(token: &token),
              let clientPath = ProcessPath.executable(of: pid),
              clientPaths.contains(clientPath),
              isTrustedExecutable(clientPath) else { return nil }
        return pid
    }

    private func hasRequiredEntitlements(token: inout audit_token_t) -> Bool {
        Self.requiredEntitlements.allSatisfy { entitlement in
            let value = entitlement.withCString { irisinXPCCopyEntitlement($0, &token) }
            return value.map { xpc_get_type($0) == IrisinXPC.typeBool && xpc_bool_get_value($0) } ?? false
        }
    }

    /// A regular, executable file owned by root and writable by nobody else.
    /// If the client binary were group- or world-writable, admitting it by
    /// path would admit whatever anyone chose to put there.
    private func isTrustedExecutable(_ path: String) -> Bool {
        var metadata = stat()
        guard stat(path, &metadata) == 0 else { return false }
        return metadata.st_uid == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode & S_IXUSR != 0
            && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
}
