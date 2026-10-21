import Foundation
import Security

/// A paid repository's sign-in: the account token and the payment secret
/// the vendor handed back to the sign-in page.
public struct VendorCredentials: Sendable, Equatable {
    public let token: String
    public let secret: String

    public init(token: String, secret: String) {
        self.token = token
        self.secret = secret
    }
}

/// Where a vendor sign-in is kept: two generic passwords per repository,
/// stored without an access group, so the Keychain puts them in the first
/// of the program's `keychain-access-groups`. The app writes them and the
/// command line reads them; both find them only while both list the same
/// groups in the same order (`Scripts/check-cli-entitlements.py`), and
/// only through these names. root and mobile share the one Keychain.
public enum VendorKeychain {
    /// The two account names, as every release since 2021 has spelt them:
    /// `secert` is the stored spelling, and correcting it signs every
    /// existing user out.
    public static func accounts(for repository: URL) -> (token: String, secret: String) {
        (
            token: "KeyChain.[\(repository.absoluteString)].token",
            secret: "KeyChain.[\(repository.absoluteString)].secert"
        )
    }

    /// nil when either half is missing or not text.
    public static func credentials(for repository: URL) -> VendorCredentials? {
        let accounts = accounts(for: repository)
        guard let token = load(accounts.token).flatMap({ String(data: $0, encoding: .utf8) }),
              let secret = load(accounts.secret).flatMap({ String(data: $0, encoding: .utf8) })
        else { return nil }
        return VendorCredentials(token: token, secret: secret)
    }

    /// Both halves are written whatever the first answered; the accounts
    /// the Keychain refused, with its status, for the caller to say so.
    @discardableResult
    public static func store(_ credentials: VendorCredentials, for repository: URL) -> [(account: String, status: OSStatus)] {
        let accounts = accounts(for: repository)
        return [(accounts.token, credentials.token), (accounts.secret, credentials.secret)].compactMap { account, value in
            let status = save(account, Data(value.utf8))
            return status == errSecSuccess ? nil : (account, status)
        }
    }

    public static func remove(for repository: URL) {
        let accounts = accounts(for: repository)
        delete(accounts.token)
        delete(accounts.secret)
    }

    private static func save(_ account: String, _ data: Data) -> OSStatus {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ] as [String: Any]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete(_ account: String) {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: account,
        ] as [String: Any]
        SecItemDelete(query as CFDictionary)
    }

    private static func load(_ account: String) -> Data? {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as [String: Any]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
