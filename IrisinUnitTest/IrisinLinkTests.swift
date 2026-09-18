import AptRepository
import Foundation
@testable import irisin
import Testing

struct IrisinLinkTests {
    private func link(_ text: String) -> IrisinLink? {
        guard let url = URL(string: text) else { return nil }
        return IrisinLink(url)
    }

    private func sources(_ text: String) -> [RepositorySource]? {
        guard case let .addRepositories(sources) = link(text) else { return nil }
        return sources
    }

    // MARK: - REPOSITORIES

    @Test func oneAddressIsOneFlatRepository() throws {
        #expect(try sources("irisin://repository/add?url=https://apt.procurs.us") == [
            RepositorySource(url: #require(URL(string: "https://apt.procurs.us"))),
        ])
    }

    /// The trailing slash apt writes and a browser keeps is not part of the
    /// address the center stores.
    @Test func aTrailingSlashIsNotPartOfTheAddress() throws {
        #expect(try sources("irisin://repository/add?url=https://apt.procurs.us/") == [
            RepositorySource(url: #require(URL(string: "https://apt.procurs.us"))),
        ])
    }

    @Test func aSuiteAndItsComponentsDescribeOneRepository() throws {
        #expect(
            try sources("irisin://repository/add?url=https://apt.procurs.us&suite=2000&component=main&component=contrib")
                == [
                    RepositorySource(
                        url: #require(URL(string: "https://apt.procurs.us")),
                        distribution: "2000",
                        components: ["main", "contrib"]
                    ),
                ]
        )
    }

    @Test func severalAddressesAreSeveralFlatRepositories() throws {
        #expect(try sources("irisin://repository/add?url=https://one.example.com&url=http://two.example.com") == [
            RepositorySource(url: #require(URL(string: "https://one.example.com"))),
            RepositorySource(url: #require(URL(string: "http://two.example.com"))),
        ])
    }

    @Test func theSameAddressTwiceIsOneRepository() {
        #expect(sources("irisin://repository/add?url=https://one.example.com&url=https://one.example.com")?.count == 1)
    }

    /// A suite belongs to one repository; spread over several it would say
    /// something about addresses it was never written for.
    @Test func aSuiteRefusesMoreThanOneAddress() {
        #expect(link("irisin://repository/add?url=https://one.example.com&url=https://two.example.com&suite=2000/") == nil)
    }

    @Test func aSecondSuiteIsRefused() {
        #expect(link("irisin://repository/add?url=https://one.example.com&suite=2000&suite=stable&component=main") == nil)
    }

    /// A suite with no component is not a source apt would accept, and a
    /// component with no suite belongs to nothing.
    @Test func anIncompleteDistributionIsRefused() {
        #expect(link("irisin://repository/add?url=https://one.example.com&suite=stable") == nil)
        #expect(link("irisin://repository/add?url=https://one.example.com&component=main") == nil)
    }

    /// The link carries a complete address. Nothing is filled in and nothing
    /// is repaired, so the old `https//` mangling is simply refused.
    @Test func anAddressWithoutItsOwnSchemeIsRefused() {
        #expect(link("irisin://repository/add?url=apt.procurs.us") == nil)
        #expect(link("irisin://repository/add?url=https//apt.procurs.us") == nil)
        #expect(link("irisin://repository/add?url=ftp://apt.procurs.us") == nil)
    }

    @Test func anAddressWithNoHostIsRefused() {
        #expect(link("irisin://repository/add?url=https://") == nil)
    }

    @Test func anEmptyOrUnknownQueryIsRefused() {
        #expect(link("irisin://repository/add") == nil)
        #expect(link("irisin://repository/add?url=") == nil)
        #expect(link("irisin://repository/add?address=https://apt.procurs.us") == nil)
    }

    // MARK: - PACKAGES

    @Test func aPackageLinkIsOneIdentity() {
        #expect(link("irisin://package/wget") == .package(identity: "wget"))
    }

    @Test func aPercentEncodedIdentityIsSpelledOut() {
        #expect(link("irisin://package/libc%2B%2B6") == .package(identity: "libc++6"))
    }

    /// dpkg's own rule, and the one the helper checks a job against.
    @Test func anIdentityDpkgWouldRefuseIsRefused() {
        #expect(link("irisin://package/Has.Upper") == nil)
        #expect(link("irisin://package/..%2F..%2Fetc") == nil)
        #expect(link("irisin://package/a") == nil)
        #expect(link("irisin://package/") == nil)
    }

    @Test func aPackagePathIsExactlyOneSegment() {
        #expect(link("irisin://package/wget/depiction") == nil)
    }

    // MARK: - NEITHER

    @Test func anotherSchemeOrHostIsRefused() {
        #expect(link("apt-repo://https://apt.procurs.us") == nil)
        #expect(link("irisin://https://apt.procurs.us") == nil)
        #expect(link("irisin://repository/remove?url=https://apt.procurs.us") == nil)
        #expect(link("irisin://packages/wget") == nil)
        #expect(link("https://irisin/package/wget") == nil)
    }
}
