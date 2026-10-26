import CryptoKit
import Foundation

/// The six-digit code a server start shows, and the key both sides derive
/// from it and this start's salt. The code reaches the browser in the QR
/// code's URL fragment or typed by hand, never across the network; the key
/// never leaves either side.
public struct WebKey: Sendable {
    /// What both sides pass HKDF as `info`.
    static let info = Data("irisin-web/1 key".utf8)

    public let code: String
    public let salt: Data
    let key: SymmetricKey

    /// A fresh code and salt, as each server start makes.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.init(
            code: String(format: "%06d", Int.random(in: 0 ... 999_999, using: &generator)),
            salt: Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        )
    }

    init(code: String, salt: Data) {
        self.code = code
        self.salt = salt
        key = Self.derive(code: code, salt: salt)
    }

    /// HKDF-SHA256 to 32 bytes, the page's `hkdfSHA256`: the code stretched
    /// to a key's length, nothing more (Documentation/WebManagement.md).
    static func derive(code: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }
}
