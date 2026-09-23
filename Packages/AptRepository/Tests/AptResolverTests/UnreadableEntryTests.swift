import AptRepository
import AptResolver
import Foundation
import IrisinProtocol
import Testing

/// Paragraphs whose relations dpkg refuses, as two repositories publish
/// them (trimmed): `apt.cydiabc.top` ends a Depends with a comma, and
/// `zlw555.github.io/repo` names `mobile substrate`, two words. A roothide
/// device read the first two through the rootless adapter, the third as
/// its own, and every install on it listed all three under its plan.
struct UnreadableEntryTests {
    private static let index = """
    Package: com.cydiabc.wchidechatavatars-rootless
    Version: 1.1-1
    Section: 微信
    Maintainer: Nets
    Depends: mobilesubstrate,
    Architecture: iphoneos-arm64
    Filename: ./debs/11522.deb
    Name: WCHideChatAvatars微信聊天隐藏头像-Rootless

    Package: com.cydiabc.wctimelinemessagetail-rootless
    Version: 1.1-1
    Section: 微信
    Maintainer: Nets
    Depends: mobilesubstrate,
    Architecture: iphoneos-arm64
    Filename: ./debs/11566.deb
    Name: WCTimeLineMessageTail微信小尾巴-Rootless

    Package: wxipad
    Version: 1.1.4
    Architecture: iphoneos-arm64e
    Maintainer: z
    Depends: mobile substrate
    Filename: ./debs/roothide/wxipad_1.1.4_iphoneos-arm64e.deb
    Section: Tweaks
    Name: 微信iPad-roothide
    """

    private static let roothide = "iphoneos-arm64e"

    private static let broken: [Package] = index.components(separatedBy: "\n\n").map { paragraph in
        let fields = try! DebianControl.parse(paragraph)
        return Package(
            identity: fields["package"]!,
            payload: [fields["version"]!: fields],
            repoRef: URL(string: "https://repository.example.test/")
        )
    }

    private static func build(_ name: String, _ version: String, depends: String? = nil, installed: Bool = false) -> Package {
        var fields = ["package": name, "version": version, "architecture": roothide]
        fields["depends"] = depends
        if installed {
            fields["status"] = "install ok installed"
        } else {
            fields["filename"] = "debs/\(name)_\(version).deb"
        }
        return Package(identity: name, payload: [version: fields], repoRef: installed ? nil : URL(string: "https://example.test/"))
    }

    private func solve(_ packages: [Package], installed: [Package] = [], actions: [ResolutionAction], update: Bool = false) throws -> ResolutionPlan {
        let snapshot = ResolutionSnapshot(
            packages: Self.broken + packages,
            installed: installed,
            architecture: Self.roothide,
            installableArchitectures: [Self.roothide, "iphoneos-arm64"]
        )
        return try resolveBothWays(request: .init(actions: actions, updateAll: update), snapshot: snapshot)
    }

    /// dpkg refuses both spellings in a .deb and in its status file, so the
    /// packages stay out of every plan: installed, they would leave a
    /// status file no dpkg reads again.
    @Test func dpkgRefusesTheRelations() {
        #expect(PackageRequirementGroup(value: "mobilesubstrate,", type: .depends) == nil)
        #expect(PackageRequirementGroup(value: "mobile substrate", type: .depends) == nil)
    }

    @Test func anInstallThatNeverLooksAtThemDoesNotListThem() throws {
        let tweak = Self.build("com.example.noappthinning", "1.3", depends: "ellekit")
        let plan = try solve([tweak, Self.build("ellekit", "1.2-1")], actions: [.install(tweak)])
        #expect(Set(plan.install.map(\.identity)) == ["com.example.noappthinning", "ellekit"])
        #expect(plan.diagnostics.isEmpty)
    }

    @Test func aDependencyWhoseNewestIsUnreadableSaysWhy() throws {
        let tweak = Self.build("com.example.pad", "1", depends: "wxipad")
        let plan = try solve([tweak, Self.build("wxipad", "1.1.3")], actions: [.install(tweak)])
        #expect(plan.install.contains { $0.identity == "wxipad" && $0.latestVersion == "1.1.3" })
        #expect(plan.diagnostics == [.unreadableMetadata(package: "wxipad", version: "1.1.4")])
    }

    @Test func updatingEverythingSaysWhichUpdateItSkipped() throws {
        let installed = [Self.build("wxipad", "1.1.3", installed: true), Self.build("ellekit", "1.2-1", installed: true)]
        let plan = try solve([], installed: installed, actions: [], update: true)
        #expect(plan.install.isEmpty)
        #expect(plan.diagnostics == [.unreadableMetadata(package: "wxipad", version: "1.1.4")])
    }

    @Test func askingForOneByNameNamesWhatIsWrong() throws {
        let wanted = try #require(Self.broken.first { $0.identity == "com.cydiabc.wchidechatavatars-rootless" })
        do {
            _ = try solve([], actions: [.install(wanted)])
            Issue.record("A package whose relations do not parse installs nothing")
        } catch let failure as ResolutionFailure {
            #expect(failure.reason == .unreadableMetadata(package: wanted.identity, version: "1.1-1"))
        }
    }
}
