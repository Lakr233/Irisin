import CryptoKit
import Foundation

/// What every call, answer and stream frame travels in: `{"n": nonce,
/// "c": ciphertext and tag}`, both base64, ChaCha20-Poly1305 under the
/// start's key. The associated data names what the bytes are (`call`,
/// `answer` to one call's nonce, a `frame` of one stream with its index), so
/// an answer cannot be replayed as another, nor a frame moved.
public struct SealedEnvelope: Codable, Sendable, Equatable {
    public var n: String
    public var c: String

    public enum Purpose: Sendable {
        case call
        case stream
        case answer(to: String)
        case frame(of: String, index: Int)

        var associatedData: Data {
            switch self {
            case .call: Data("irisin-web/1 call".utf8)
            case .stream: Data("irisin-web/1 stream".utf8)
            case let .answer(nonce): Data("irisin-web/1 answer \(nonce)".utf8)
            case let .frame(nonce, index): Data("irisin-web/1 frame \(nonce) \(index)".utf8)
            }
        }
    }

    public static func seal(_ plaintext: Data, for purpose: Purpose, with key: WebKey) throws -> SealedEnvelope {
        let box = try ChaChaPoly.seal(plaintext, using: key.key, nonce: ChaChaPoly.Nonce(), authenticating: purpose.associatedData)
        return SealedEnvelope(
            n: Data(box.nonce).base64EncodedString(),
            c: (box.ciphertext + box.tag).base64EncodedString()
        )
    }

    /// The plaintext, or nil when it does not open under this key and
    /// purpose.
    public func open(for purpose: Purpose, with key: WebKey) -> Data? {
        guard let nonceBytes = Data(base64Encoded: n), let sealed = Data(base64Encoded: c), sealed.count >= 16,
              let nonce = try? ChaChaPoly.Nonce(data: nonceBytes),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        else {
            return nil
        }
        return try? ChaChaPoly.open(box, using: key.key, authenticating: purpose.associatedData)
    }
}
