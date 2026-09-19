@testable import AptRepository
import Foundation
import Testing

struct DpkgStatusTests {
    @Test(arguments: ["install ok installed", "hold ok installed", "deinstall ok installed", "install ok unpacked", "install ok half-configured", "install reinstreq half-installed"])
    func preservesPresentState(_ state: String) throws {
        let data = Data("Package: aa\nVersion: 1\nArchitecture: arm64\nStatus: \(state)\n".utf8)
        let packages = try DpkgStatus.packages(in: data)
        #expect(packages["aa"]?.latestMetadata?["status"] == state)
    }

    @Test(arguments: ["deinstall ok config-files", "purge ok not-installed"])
    func residualConfigurationIsNotInstalled(_ state: String) throws {
        #expect(try DpkgStatus.packages(in: Data("Package: aa\nStatus: \(state)\n".utf8)).isEmpty)
    }

    /// BigBoss ships MacRoman in a few fields: that line is read as what it
    /// is, and every other line stays UTF-8.
    @Test func aLineThatIsNotUTF8CostsNoOtherLine() throws {
        var data = Data("Package: aa\nVersion: 1\nStatus: install ok installed\nDescription: you".utf8)
        data.append(0xD5)
        data.append(Data("ll\n\nPackage: bb\nVersion: 1\nStatus: install ok installed\nName: 位置伪装\n".utf8))
        let packages = try DpkgStatus.packages(in: data)
        #expect(packages["aa"]?.latestMetadata?["description"] == "you’ll")
        #expect(packages["bb"]?.latestMetadata?["name"] == "位置伪装")
    }

    @Test func corruptStatusCannotBecomeAnEmptyInstallation() {
        #expect(throws: (any Error).self) { try DpkgStatus.packages(in: Data("Package: aa\nVersion: 1\n".utf8)) }
    }

    @Test func extendedStatesSkipsWhatItCannotRead() {
        let text = """
        Package: aa
        Architecture: iphoneos-arm64
        Auto-Installed: 1

        Package: BB
        Architecture: all
        Auto-Installed: 1

        Package: cc
        Auto-Installed: 0

        not a field

        Package: dd
        Auto-Installed: 1
        """
        #expect(PackageIndex.autoInstalled(in: Data(text.utf8)) == ["aa", "bb", "dd"])
        #expect(PackageIndex.autoInstalled(in: Data([0xFF, 0x00])).isEmpty)
    }

    @Test func catalogueRevisionChangesOnlyWithPackageRecords() throws {
        let db = TestEnvironment.database()
        let original = try db.resolutionCatalogue()
        let url = try #require(URL(string: "https://revision.invalid/"))
        db.replacePackages(of: url, with: ["aa": Package(identity: "aa", payload: ["1": ["package": "aa", "version": "1"], "2": ["package": "aa", "version": "2"]])])
        let changed = try db.resolutionCatalogue()
        #expect(changed.revision > original.revision)
        #expect(changed.packages.first?.payload.count == 2)
        db.deletePackages(of: url)
        #expect(try db.resolutionRevision() > changed.revision)
    }
}
