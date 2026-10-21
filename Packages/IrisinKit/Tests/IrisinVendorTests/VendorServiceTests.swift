import Foundation
@testable import IrisinVendor
import XCTest

/// What the app and the command line send a vendor, and the Keychain
/// names both read. A change here is a change to both, and to every
/// sign-in a user already has.
final class VendorServiceTests: XCTestCase {
    private let repository = URL(string: "https://repo.example.com/")!
    private let endpoint = URL(string: "https://pay.example.com/api/")!
    private let credentials = VendorCredentials(token: "t0k", secret: "s3c")
    private let device = VendorDevice(udid: "0000FE01-5B47A4F6BF8A9C0C", machine: "iPhone18,4", firmware: "26.6.2")

    func testKeychainAccountsKeepTheirSpelling() {
        let accounts = VendorKeychain.accounts(for: repository)
        XCTAssertEqual(accounts.token, "KeyChain.[https://repo.example.com/].token")
        // the stored spelling, typo and all: a sign-in made by any release
        // since 2021 is found under it
        XCTAssertEqual(accounts.secret, "KeyChain.[https://repo.example.com/].secert")
    }

    func testSignInURLPutsTheDeviceBeforeTheModel() throws {
        let url = VendorService.signInURL(endpoint: endpoint, device: device)
        XCTAssertEqual(url.absoluteString, "https://pay.example.com/api/authenticate?udid=0000FE01-5B47A4F6BF8A9C0C&model=iPhone18,4")
    }

    func testPackageEndpoints() {
        XCTAssertEqual(
            VendorService.package("com.example.tweak", "authorize_download", at: endpoint).absoluteString,
            "https://pay.example.com/api/package/com.example.tweak/authorize_download"
        )
    }

    func testRequestCarriesTheAccountAndTheDevice() throws {
        let request = VendorService.request(endpoint, credentials, device, [
            "version": "1.0",
            "architecture": "iphoneos-arm64e",
            "skipped": nil,
        ])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, [
            "version": "1.0",
            "architecture": "iphoneos-arm64e",
            "token": "t0k",
            "udid": "0000FE01-5B47A4F6BF8A9C0C",
            "device": "iPhone18,4",
        ])
    }

    func testPayloadKeepsItsOwnValueOverTheAccountsKeys() throws {
        let request = VendorService.request(endpoint, credentials, device, ["device": "kept"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(payload["device"], "kept")
    }

    func testAnAnswerThatIsNoObjectIsAFailure() {
        XCTAssertThrowsError(try VendorService.object(from: Data("<html>".utf8))) { error in
            XCTAssertEqual(error as? VendorService.Failure, .notAnObject(bytes: 6))
        }
        XCTAssertThrowsError(try VendorService.object(from: Data("[1]".utf8)))
        XCTAssertEqual(try VendorService.object(from: Data(#"{"url":"x"}"#.utf8))["url"] as? String, "x")
    }

    func testFailuresSpellWhatTheLogSaid() {
        XCTAssertEqual(VendorService.Failure.status(500).description, "answered HTTP 500")
        XCTAssertEqual(
            VendorService.Failure.notAnObject(bytes: 12).description,
            "did not answer with a JSON object, 12 bytes"
        )
    }
}
