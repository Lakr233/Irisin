import AptRepository
@testable import AptResolver
import IrisinProtocol
import Testing

struct ResolutionDiagnosticTests {
    @Test func architectureEvidenceSummarizesRepositoryVersionHistory() throws {
        let app = pkg("app", "1", ["architecture": "iphoneos-arm64", "depends": "library"])
        let versions = (1 ... 40).map { pkg("library", String($0), ["architecture": "iphoneos-arm"]) }
        let snapshot = ResolutionSnapshot(packages: [app] + versions, installed: [], architecture: "iphoneos-arm64")
        do {
            _ = try resolveBothWays(request: .init(actions: [.install(app)]), snapshot: snapshot)
            Issue.record("A different architecture cannot satisfy the request")
        } catch let failure as ResolutionFailure {
            let check = try #require(failure.checks.first { $0.requirement == "library" })
            #expect(check.outcome == .incompatibleArchitecture)
            #expect(check.candidates.count == 1)
            #expect(check.candidates.first?.contains("library 40") == true)
        }
    }

    @Test func matchingDependenciesDoNotHideGlobalConflict() throws {
        let app = pkg("app", "1", ["depends": "library, other"])
        let library = pkg("library", "1", ["conflicts": "other"])
        do {
            _ = try solve([app, library, pkg("other")], actions: [.install(app)])
            Issue.record("Individually available dependencies must still form a compatible plan")
        } catch let failure as ResolutionFailure {
            #expect(failure.checks.contains { $0.requirement == "library" && $0.outcome == .matched })
            #expect(failure.checks.contains { $0.requirement == "other" && $0.outcome == .matched })
            #expect(failure.checks.contains { $0.outcome == .conflictingRequirements })
            #expect(!failure.checks.contains { $0.requirement.contains("irisin-record:") })
        }
    }

    @Test func legacyImplicitVersionAndUppercaseReferenceMatchDpkg() throws {
        let package = pkg("com.example.theme", "4.1", ["replaces": "com.Example.Theme (3.3)"])
        let result = try solve([package], installed: [pkg("com.example.theme", "3.3", installed: true)], actions: [.install(package)])
        #expect(result.install.first?.latestVersion == "4.1")
        let relation = try #require(PackageRequirementGroup(value: "com.Example.Theme (3.3)", type: .replaces))
        let element = try #require(relation.requirements.first?.elements.first)
        #expect(element.representPackage == "com.example.theme")
        #expect(element.doesThisVersionMatchesRequirement(version: "3.3"))
        #expect(!element.doesThisVersionMatchesRequirement(version: "3.4"))
    }

    @Test func rootfulProviderIsExplainedWithoutBecomingRootlessCandidate() throws {
        let app = pkg("example.app", "1", ["architecture": "iphoneos-arm64", "depends": "mobilesubstrate (>= 0.9.5000), firmware (>= 13)"])
        let substrate = pkg("mobilesubstrate", "0.9.7113", ["architecture": "iphoneos-arm"])
        let firmware = pkg("firmware", "26.6.1", ["architecture": "all"], installed: true)
        let snapshot = ResolutionSnapshot(packages: [app, substrate], installed: [firmware], architecture: "iphoneos-arm64")
        do {
            _ = try resolveBothWays(request: .init(actions: [.install(app)]), snapshot: snapshot)
            Issue.record("A rootful provider must not satisfy a rootless install")
        } catch let failure as ResolutionFailure {
            #expect(failure.checks.contains { $0.requirement == "mobilesubstrate (>= 0.9.5000)" && $0.outcome == .incompatibleArchitecture })
            #expect(failure.checks.contains { $0.requirement == "firmware (>= 13)" && $0.outcome == .matched })
            #expect(failure.reason == .requirementsUnmatched)
            #expect(!failure.checks.contains { $0.requirement.contains("missing:") })
        }
    }

    @Test func removingAProtectedPackageSaysTheSystemRequiresIt() throws {
        let installed = [pkg("apt", installed: true), pkg("app", installed: true)]
        do {
            _ = try solve([], installed: installed, actions: [.remove("apt")])
            Issue.record("The system keeps apt")
        } catch let failure as ResolutionFailure {
            #expect(failure.reason == .requiredBySystem(package: "apt"))
        }
    }

    @Test func removingWhatTheSystemNeedsNamesThePackagesThatNeedIt() throws {
        let installed = [
            pkg("base", "1", ["essential": "yes", "depends": "shell"], installed: true),
            pkg("shell", "1", ["depends": "library"], installed: true),
            pkg("library", installed: true),
        ]
        do {
            _ = try solve([], installed: installed, actions: [.remove("library")])
            Issue.record("The system keeps what an essential package needs")
        } catch let failure as ResolutionFailure {
            #expect(failure.reason == .neededBySystem(package: "library", dependents: ["base"]))
            #expect(failure.checks.contains {
                $0.package == "library" && $0.requirement == "base" && $0.outcome == .requiredBySystem
            })
        }
    }

    @Test func allowingSystemRemovalLetsProtectedPackagesGoButNeverTheFirmware() throws {
        let installed = [
            pkg("base", "1", ["essential": "yes", "depends": "library"], installed: true),
            pkg("library", installed: true),
            pkg("apt", installed: true),
            pkg("firmware", installed: true),
            pkg("cy+os.ios", "1", ["essential": "yes"], installed: true),
            pkg("gsc.arm64", "1", ["essential": "yes"], installed: true),
        ]
        let plan = try solve(
            [], installed: installed, actions: [.remove("apt"), .remove("library")],
            auto: ["base"], allowSystemRemoval: true
        )
        #expect(Set(plan.remove.map(\.identity)) == ["apt", "base", "library"])
        // the switch lets them be removed; it never offers them for cleanup
        let untouched = try solve([], installed: installed, actions: [.remove("apt")], auto: ["base"], allowSystemRemoval: true)
        #expect(untouched.unneeded["base"] == nil)
        // the device's own records: no repository offers them again
        for name in ["firmware", "cy+os.ios", "gsc.arm64"] {
            do {
                _ = try solve([], installed: installed, actions: [.remove(name)], allowSystemRemoval: true)
                Issue.record("\(name) stands for the device and never leaves")
            } catch let failure as ResolutionFailure {
                #expect(failure.reason == .requiredBySystem(package: name))
            }
        }
    }

    @Test func missingPackageAndUnsuitableVersionAreDistinct() throws {
        let app = pkg("app", "1", ["depends": "absent, library (>= 3), present"])
        do {
            _ = try solve([app, pkg("library", "2"), pkg("present")], actions: [.install(app)])
            Issue.record("Unsatisfied requirements must fail")
        } catch let failure as ResolutionFailure {
            #expect(failure.checks.contains { $0.requirement == "absent" && $0.outcome == .missing })
            #expect(failure.checks.contains { $0.requirement == "library (>= 3)" && $0.outcome == .noMatchingVersion })
            #expect(failure.checks.contains { $0.requirement == "present" && $0.outcome == .matched })
        }
    }

    @Test func availableUnversionedProviderStillCannotSatisfyVersionedDependency() throws {
        let app = pkg("app", "1", ["depends": "virtual (>= 2)"])
        let provider = pkg("provider", "99", ["provides": "virtual"])
        do {
            _ = try solve([app, provider], actions: [.install(app)])
            Issue.record("Provider package version must not invent a Provides version")
        } catch let failure as ResolutionFailure {
            #expect(failure.checks.contains { $0.requirement == "virtual (>= 2)" && $0.outcome == .noMatchingVersion })
        }
    }
}
