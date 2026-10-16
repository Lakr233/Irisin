import Foundation
@testable import IrisinExternalClient
import IrisinProtocol
import XCTest

/// The client library is written apart from IrisinProtocol, so another
/// package's root process can take it without the rest of Irisin. This holds
/// the two spellings of the wire to each other.
final class ExternalContractTests: XCTestCase {
    func testTheConstantsAgree() {
        XCTAssertEqual(IrisinExternalWire.serviceName, IrisinWire.serviceName)
        XCTAssertEqual(IrisinExternalWire.baseVersion, IrisinWire.version)
        XCTAssertEqual(IrisinExternalWire.externalVersion, IrisinWire.externalVersion)
        XCTAssertEqual(IrisinExternalWire.clientEntitlement, IrisinWire.clientEntitlement)
        XCTAssertTrue(IrisinWire.requiredClientEntitlements.contains(IrisinExternalWire.clientEntitlement))
    }

    func testTheOperationsAgree() {
        let pairs: [(IrisinExternalWire.Operation, IrisinOperation)] = [
            (.serviceInfo, .serviceInfo), (.submitInstall, .submitInstall),
            (.transactionStatus, .transactionStatus), (.transactionEvents, .transactionEvents),
            (.removePackage, .removePackage), (.respring, .respring),
        ]
        for (client, daemon) in pairs {
            XCTAssertEqual(client.rawValue, daemon.rawValue, "\(daemon)")
        }
        XCTAssertEqual(Set(IrisinWire.externalCapabilities), Set(pairs.map(\.1.name)).subtracting(["serviceInfo"]))
    }

    func testTheKeysAgree() {
        typealias C = IrisinExternalWire.Key
        typealias D = IrisinWire.Key
        let pairs: [(String, String)] = [
            (C.version, D.version), (C.operation, D.operation), (C.code, D.code), (C.errno, D.errno),
            (C.installRoot, D.installRoot), (C.descriptor, D.descriptor), (C.externalVersion, D.externalVersion),
            (C.capabilities, D.capabilities), (C.transaction, D.transaction), (C.sha256, D.sha256),
            (C.packageIdentity, D.packageIdentity), (C.packageVersion, D.packageVersion), (C.kind, D.kind),
            (C.state, D.state), (C.duplicate, D.duplicate), (C.exitStatus, D.exitStatus), (C.failure, D.failure),
            (C.failureText, D.failureText), (C.nextSequence, D.nextSequence), (C.afterSequence, D.afterSequence),
            (C.limit, D.limit), (C.events, D.events), (C.sequence, D.sequence), (C.text, D.text),
            (C.phase, D.phase), (C.step, D.step), (C.completed, D.completed), (C.total, D.total), (C.raw, D.raw),
        ]
        for (client, daemon) in pairs {
            XCTAssertEqual(client, daemon)
        }
    }

    func testTheStatesAndCodesAgree() {
        for state in [ExternalTransaction.State.running, .succeeded, .failed, .interrupted] {
            XCTAssertNotNil(IrisinTransactionState(rawValue: state.rawValue))
        }
        XCTAssertEqual(IrisinReplyCode.conflict.rawValue, 5)
        XCTAssertEqual(IrisinReplyCode.operationFailed.rawValue, 4)
    }

    /// The client spells an id the way the daemon accepts it.
    func testTheClientSpellsIdentifiersTheDaemonAccepts() {
        for _ in 0 ..< 32 {
            XCTAssertTrue(ExternalTransaction.isIdentifier(IrisinExternalClient.spell(UUID())))
        }
    }

    /// With no daemon registered (a Mac), a call says the service is not
    /// there rather than hanging.
    func testNoServiceIsUnavailable() async {
        let client = IrisinExternalClient(serviceName: "wiki.qaq.irisin.service.absent-\(UUID().uuidString)")
        do {
            _ = try await client.serviceInfo()
            XCTFail("nothing should answer")
        } catch let error as IrisinClientError {
            XCTAssertTrue([.serviceUnavailable, .connectionInterrupted].contains(error.code))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTheDigestIsOfTheWholeFile() throws {
        let path = NSTemporaryDirectory() + "digest-\(UUID().uuidString)"
        try Data("abc".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let descriptor = open(path, O_RDONLY)
        defer { close(descriptor) }
        lseek(descriptor, 2, SEEK_SET)
        XCTAssertEqual(
            try IrisinExternalClient.sha256(ofDescriptor: descriptor),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
