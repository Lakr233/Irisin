import CryptoKit
import Foundation
@testable import IrisinWeb
import JavaScriptCore
import Testing

/// The page's `cipher.js`, run in JavaScriptCore, against the RFCs' vectors
/// and byte for byte against CryptoKit, which the server uses: the two sides must agree on every byte or nothing opens.
@Suite(.serialized)
struct CipherTests {
    private let context: JSContext

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "cipher", withExtension: "js", subdirectory: "Page"))
        context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript: \(exception?.toString() ?? "?")")
        }
        try context.evaluateScript(String(contentsOf: url, encoding: .utf8))
    }

    private func bytes(_ data: Data) -> JSValue {
        context.evaluateScript("(function (a) { return new Uint8Array(a); })")!.call(withArguments: [Array(data)])!
    }

    private func call(_ function: String, _ arguments: [Any]) -> Data? {
        let value = context.evaluateScript("IrisinCipher.\(function)")!.call(withArguments: arguments)!
        guard !value.isNull, !value.isUndefined else { return nil }
        let array = context.evaluateScript("(function (u) { return Array.from(u); })")!.call(withArguments: [value])!
        return Data((array.toArray() as? [NSNumber] ?? []).map(\.uint8Value))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func random(_ count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
    }

    @Test func sha256MatchesTheStandardAndCryptoKit() throws {
        #expect(try Self.hex(#require(call("sha256", [bytes(Data("abc".utf8))])))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try Self.hex(#require(call("sha256", [bytes(Data())])))
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        for length in [1, 55, 56, 63, 64, 65, 119, 120, 1000] {
            let message = Self.random(length)
            #expect(call("sha256", [bytes(message)]) == Data(SHA256.hash(data: message)), "length \(length)")
        }
    }

    /// RFC 4231 test cases 1 and 2, then keys longer than a block.
    @Test func hmacMatchesRFC4231AndCryptoKit() throws {
        #expect(try Self.hex(#require(call("hmacSHA256", [bytes(Data(repeating: 0x0B, count: 20)), bytes(Data("Hi There".utf8))])))
            == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        #expect(try Self.hex(#require(call("hmacSHA256", [bytes(Data("Jefe".utf8)), bytes(Data("what do ya want for nothing?".utf8))])))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        for keyLength in [0, 16, 64, 65, 131] {
            let key = Self.random(keyLength)
            let message = Self.random(77)
            let expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
            #expect(call("hmacSHA256", [bytes(key), bytes(message)]) == expected, "key length \(keyLength)")
        }
    }

    /// RFC 5869 test case 1, then the server's own derivation.
    @Test func hkdfMatchesRFC5869AndCryptoKit() throws {
        let ikm = Data(repeating: 0x0B, count: 22)
        let salt = Data((0x00 ... 0x0C).map { UInt8($0) })
        let info = Data((0xF0 ... 0xF9).map { UInt8($0) })
        #expect(try Self.hex(#require(call("hkdfSHA256", [bytes(ikm), bytes(salt), bytes(info), 42])))
            == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        let serverSalt = Self.random(16)
        let expected = WebKey.derive(code: "042917", salt: serverSalt).withUnsafeBytes { Data($0) }
        #expect(call("hkdfSHA256", [bytes(Data("042917".utf8)), bytes(serverSalt), bytes(WebKey.info), 32]) == expected)
    }

    /// RFC 8439 2.8.2.
    @Test func chachaPolyMatchesRFC8439() throws {
        let key = Data((0x80 ... 0x9F).map { UInt8($0) })
        let nonce = Data([0x07, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47])
        let aad = Data([0x50, 0x51, 0x52, 0x53, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7])
        let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let sealed = try #require(call("seal", [bytes(key), bytes(nonce), bytes(plaintext), bytes(aad)]))
        #expect(Self.hex(sealed.suffix(16)) == "1ae10b594f09e26a7e902ecbd0600691")
        #expect(Self.hex(sealed.prefix(16)) == "d31a8d34648e60db7b86afbc53ef7ec2")
        #expect(call("open", [bytes(key), bytes(nonce), bytes(sealed), bytes(aad)]) == plaintext)
    }

    @Test func chachaPolyMatchesCryptoKitBothWays() throws {
        for length in [0, 1, 15, 16, 17, 63, 64, 65, 1000, 70000] {
            let key = Self.random(32)
            let nonce = Self.random(12)
            let aad = Self.random(length % 23)
            let plaintext = Self.random(length)
            let box = try ChaChaPoly.seal(
                plaintext, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad
            )
            let ours = try #require(call("seal", [bytes(key), bytes(nonce), bytes(plaintext), bytes(aad)]))
            #expect(ours == box.ciphertext + box.tag, "length \(length)")
            #expect(call("open", [bytes(key), bytes(nonce), bytes(box.ciphertext + box.tag), bytes(aad)]) == plaintext)
            var tampered = box.ciphertext + box.tag
            tampered[tampered.startIndex] ^= 1
            #expect(call("open", [bytes(key), bytes(nonce), bytes(tampered), bytes(aad)]) == nil)
            #expect(call("open", [bytes(key), bytes(nonce), bytes(box.ciphertext + box.tag), bytes(aad + Data([1]))]) == nil)
        }
    }

    @Test func utf8AndBase64RoundTrip() throws {
        let text = "Irisin 中文 🌱 é"
        let encoded = try #require(call("utf8Encode", [text]))
        #expect(encoded == Data(text.utf8))
        let decoded = try #require(context.evaluateScript("IrisinCipher.utf8Decode")?.call(withArguments: [bytes(encoded)])?.toString())
        #expect(decoded == text)
        for length in [0, 1, 2, 3, 4, 5, 100] {
            let data = Self.random(length)
            let base64 = try #require(context.evaluateScript("IrisinCipher.base64Encode")?.call(withArguments: [bytes(data)])?.toString())
            #expect(base64 == data.base64EncodedString())
            #expect(call("base64Decode", [data.base64EncodedString()]) == data)
        }
    }
}
