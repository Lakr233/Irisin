import Darwin
import Foundation
import IrisinProtocol
import XPC

/// The whole trust boundary.
///
/// `irisind` runs as root and starts a helper that installs packages, so the
/// only thing that keeps it from being a privilege-escalation service for
/// every process on the device is this check, and it runs before a single
/// request field is read.
///
/// The check is on the kernel's audit token, not on anything the peer told
/// us: the token is filled in by the kernel for the connection, so a caller
/// cannot forge its pid, its uid or its entitlements. In order:
///
/// 1. pid above 1, euid root or mobile;
/// 2. `IrisinWire.requiredClientEntitlements`, each strictly `true`;
/// 3. the executable `proc_pidpath` names, canonicalised, admitted by
///    `ExecutableAdmission` (inside the install root or on the system
///    volume, in directories and a file no one but root could have changed),
///    or Irisin's own app at its exact path, root-owned, as before 4.7;
/// 4. euid root for every program but Irisin's own app. A client that
///    mobile could run would install as root for whoever runs it; raising
///    privilege is the user's to do (`sudo`), never this service's.
///
/// This trusts every installed package whose root-owned program carries the
/// entitlements, not Irisin alone: `Documentation/ExternalClients.md`.
struct PeerAuthenticator {
    private static let mobileUserID: UInt32 = 501

    /// A peer that may be served.
    struct Peer {
        let pid: Int32
        let executable: String
    }

    private let clientPaths: [String]
    private let admission: ExecutableAdmission

    init(installRoot: String) {
        clientPaths = IrisinWire.clientPaths.compactMap { ProcessPath.canonical(installRoot + $0) }
        admission = ExecutableAdmission(installRoot: installRoot, trustsSystemVolume: true)
    }

    /// The peer when it may be served, nil when the connection must be
    /// cancelled.
    func authenticate(_ connection: xpc_connection_t) -> Peer? {
        var token = audit_token_t()
        irisinXPCConnectionGetAuditToken(connection, &token)
        let pid = Int32(bitPattern: token.val.5)

        guard pid > 1, token.val.1 == 0 || token.val.1 == Self.mobileUserID else {
            log.warning("peer rejected: pid \(pid) euid \(token.val.1)")
            return nil
        }
        guard hasRequiredEntitlements(token: &token) else {
            log.warning("peer rejected: pid \(pid) lacks a client entitlement")
            return nil
        }
        // Identity is the executable on disk, not the bundle id, and the file
        // at that path must be one no less privileged process could have
        // swapped out from under us.
        guard let clientPath = ProcessPath.executable(of: pid) else {
            log.warning("peer rejected: pid \(pid) has no executable path")
            return nil
        }
        if clientPaths.contains(clientPath), isTrustedExecutable(clientPath) {
            return Peer(pid: pid, executable: clientPath)
        }
        switch admission.admit(clientPath) {
        case let .success(admitted):
            guard token.val.1 == 0 else {
                log.warning("peer rejected: \(admitted, privacy: .public) euid \(token.val.1), not root")
                return nil
            }
            return Peer(pid: pid, executable: admitted)
        case let .failure(refusal):
            log.warning(
                "peer rejected: \(clientPath, privacy: .public) \(String(describing: refusal), privacy: .public)"
            )
            return nil
        }
    }

    private func hasRequiredEntitlements(token: inout audit_token_t) -> Bool {
        IrisinWire.requiredClientEntitlements.allSatisfy { entitlement in
            let value = entitlement.withCString { irisinXPCCopyEntitlement($0, &token) }
            return value.map { xpc_get_type($0) == IrisinXPC.typeBool && xpc_bool_get_value($0) } ?? false
        }
    }

    /// Irisin's own app, by the rule it has always had: a regular,
    /// executable file owned by root and writable by nobody else.
    private func isTrustedExecutable(_ path: String) -> Bool {
        var metadata = stat()
        guard stat(path, &metadata) == 0 else { return false }
        return metadata.st_uid == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode & S_IXUSR != 0
            && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
}
