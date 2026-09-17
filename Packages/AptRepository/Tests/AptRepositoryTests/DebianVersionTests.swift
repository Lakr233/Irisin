@testable import AptRepository
import Foundation
import XCTest

/// Debian Policy §5.6.12 by the book, then thousands of recorded verdicts
/// from the real `dpkg --compare-versions`.
final class DebianVersionTests: XCTestCase {
    // MARK: - Validity

    func testValidVersions() {
        for version in [
            "1", "1.0", "1.0-1", "1:1.0", "1:1.0-1", "0:0", "1.0~beta1", "1.0+dfsg-1",
            "2.30-1ubuntu1", "1.2.3~rc1-0+deb10u1", "1.0-1-1", "0.0.0.1", "1:2:3-4",
            "abc", "a-1", "~", "1.0.0~", "99999999999999",
        ] {
            XCTAssertTrue(DebianVersion.isValid(version), version)
        }
    }

    func testInvalidVersions() {
        for version in [
            "", " ", "1 0", "1:", ":1", "a:1", "-1:1", "1-", "1.0-", "1.0-a-", "1:-1", "1 :0", "1.0-1:2",
        ] {
            XCTAssertFalse(DebianVersion.isValid(version), version.debugDescription)
        }
        // leading and trailing whitespace is dpkg's one indulgence
        XCTAssertTrue(DebianVersion.isValid(" 1.0\n"))
    }

    // MARK: - Ordering

    private func assertLess(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(DebianVersion.compare(a, b), 0, "\(a) < \(b)", file: file, line: line)
        XCTAssertGreaterThan(DebianVersion.compare(b, a), 0, "\(b) > \(a)", file: file, line: line)
    }

    private func assertEqual(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(DebianVersion.compare(a, b), 0, "\(a) == \(b)", file: file, line: line)
        XCTAssertEqual(DebianVersion.compare(b, a), 0, "\(b) == \(a)", file: file, line: line)
    }

    func testEpoch() {
        assertLess("1.0", "1:0.1")
        assertLess("1:9.9", "2:0.1")
        assertEqual("0:1.0", "1.0")
        assertLess("1:1.0-1", "2:1.0-1")
    }

    func testNumericRuns() {
        assertLess("1.9", "1.10")
        assertLess("1.09", "1.10")
        assertEqual("1.09", "1.9")
        assertEqual("1.0", "1.00")
        assertLess("1.0", "1.0.0")
        assertLess("1", "1.0")
        assertLess("2", "10")
        assertLess("1.1", "1.1.1")
        assertLess("0.9.9", "1")
        assertLess("99999999999999999999", "100000000000000000000")
    }

    func testTilde() {
        assertLess("1.0~", "1.0")
        assertLess("1.0~~", "1.0~")
        assertLess("1.0~beta", "1.0")
        assertLess("1.0~beta1", "1.0~beta2")
        assertLess("1.0~rc1", "1.0~rc1+1")
        assertLess("1.0~rc1", "1.0")
        assertLess("1.0~~a", "1.0~a")
        assertLess("1.0~a", "1.0")
        assertLess("1.0-1~bpo1", "1.0-1")
    }

    func testLettersBeforeNonLetters() {
        // letters sort before every non-letter, non-letters by code point
        assertLess("1.0a", "1.0+")
        assertLess("1.0a", "1.0.")
        assertLess("1.0", "1.0a")
        assertLess("1.0a", "1.0b")
        assertLess("1.0Z", "1.0a")
        assertLess("1.0+", "1.0.")
        // a colon in the upstream part is only legal behind an epoch
        assertLess("1:1.0.", "1:1.0:")
        assertLess("0~2022", "0~bzr2014")
    }

    func testRevision() {
        assertLess("1.0-1", "1.0-2")
        assertLess("1.0-1", "1.0-1.1")
        assertLess("1.0", "1.0-1")
        assertLess("1.0-9", "1.0-10")
        // only the last hyphen splits the revision
        assertLess("1.0-1-1", "1.0-1-2")
        assertLess("1.0-1-1", "1.0-2-0")
        assertEqual("1.0-0", "1.0-00")
        assertLess("1.0-1~", "1.0-1")
    }

    func testMixedRuns() {
        assertLess("1.2.3", "1.2.3a")
        assertLess("1.2.3a", "1.2.3b")
        assertLess("1.2.3a", "1.2.4")
        assertLess("1.2a3", "1.2a10")
        assertLess("1.2a10", "1.2b1")
        assertLess("2.0+git20200101", "2.0+git20200102")
        assertLess("2.0+git", "2.0+git1")
        assertLess("1.0+dfsg", "1.0+dfsg1")
        assertLess("1.0-1+deb9u1", "1.0-1+deb10u1")
    }

    func testIdentity() {
        for version in ["1", "1.0-1", "1:2.3~4+5-6", "a", "1.0~~"] {
            assertEqual(version, version)
        }
    }

    func testInvalidPairsCompareEqual() {
        XCTAssertEqual(DebianVersion.compare("", "1"), 0)
        XCTAssertEqual(DebianVersion.compare("1 0", "1"), 0)
    }

    func testTotalOrderOnSample() {
        let ascending = [
            "0.9~", "0.9", "1~~", "1~", "1~a", "1", "1a", "1+", "1.0~beta1", "1.0~beta2", "1.0~rc1", "1.0",
            "1.0-1~bpo1", "1.0-1", "1.0-1+deb9u1", "1.0-1+deb10u1", "1.0-2", "1.0.1", "1.1", "1.9", "1.10",
            "2", "10", "1:0", "1:1.0", "2:0",
        ]
        for i in ascending.indices {
            for j in ascending.indices {
                let result = DebianVersion.compare(ascending[i], ascending[j])
                if i < j {
                    XCTAssertLessThan(result, 0, "\(ascending[i]) < \(ascending[j])")
                } else if i > j {
                    XCTAssertGreaterThan(result, 0, "\(ascending[i]) > \(ascending[j])")
                } else {
                    XCTAssertEqual(result, 0, ascending[i])
                }
            }
        }
    }

    // MARK: - dpkg as the oracle

    /// `Fixtures/dpkg-pairs.txt` records what `dpkg --compare-versions`
    /// said about 1500 random strings from its own alphabet, epochs and
    /// revisions included, malformed ones welcome, plus a curated cross
    /// product: `lt`, `eq`, `gt`, or `invalid` when dpkg refused to parse a
    /// side. Every pair must agree on whether it parses and on its order.
    /// Recorded once, so the test spawns nothing and needs no dpkg.
    func testAgreesWithDpkgOnRecordedPairs() throws {
        var compared = 0
        var disagreements = [String]()
        for line in try TestEnvironment.fixture("dpkg-pairs").split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let (a, b, verdict) = (fields[0], fields[1], fields[2])
            let valid = DebianVersion.isValid(a) && DebianVersion.isValid(b)
            if verdict == "invalid" || !valid {
                if (verdict == "invalid") == valid {
                    disagreements.append("validity of \(a.debugDescription) / \(b.debugDescription): dpkg \(verdict == "invalid" ? "rejects" : "accepts"), we \(valid ? "accept" : "reject")")
                }
                continue
            }
            compared += 1
            let result = DebianVersion.compare(a, b)
            let actual = result < 0 ? "lt" : (result > 0 ? "gt" : "eq")
            if actual != verdict {
                disagreements.append("\(a.debugDescription) vs \(b.debugDescription): dpkg \(verdict), we \(actual)")
            }
        }
        XCTAssertGreaterThan(compared, 2000, "too few valid pairs to mean anything")
        XCTAssertTrue(disagreements.isEmpty, disagreements.prefix(20).joined(separator: "\n"))
    }
}

/// A seeded generator so a failing pair can be reproduced.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
