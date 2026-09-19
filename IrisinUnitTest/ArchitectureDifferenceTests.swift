@testable import irisin
import Testing

struct ArchitectureDifferenceTests {
    @Test
    func whatThePackageHasTooManyIsExtra() {
        #expect(ArchitectureDifference.runs(of: "iphoneos-arm64e", against: "iphoneos-arm64")
            == [.same("iphoneos-arm64"), .extra("e")])
    }

    @Test
    func whatThePackageLacksIsMissing() {
        #expect(ArchitectureDifference.runs(of: "iphoneos-arm64", against: "iphoneos-arm64e")
            == [.same("iphoneos-arm64"), .missing("e")])
        #expect(ArchitectureDifference.runs(of: "iphoneos-arm", against: "iphoneos-arm64")
            == [.same("iphoneos-arm"), .missing("64")])
    }

    @Test
    func theSameArchitectureIsOneRun() {
        #expect(ArchitectureDifference.runs(of: "iphoneos-arm64", against: "iphoneos-arm64")
            == [.same("iphoneos-arm64")])
    }
}
