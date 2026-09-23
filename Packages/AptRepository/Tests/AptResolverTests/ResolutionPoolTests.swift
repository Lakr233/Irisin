import AptRepository
@testable import AptResolver
import Foundation
import Testing

/// A pool read ahead answers only for the packages it was read from. Each
/// test reads one from a snapshot, moves one input, and solves the moved
/// snapshot with the old pool: the plan must be the moved snapshot's, never
/// the pool's.
struct ResolutionPoolTests {
    private let database = UUID()
    private let app = pkg("app", "1", ["depends": "library"])
    private let library = pkg("library", "1")
    private let newer = pkg("library", "2")

    private func snapshot(
        _ packages: [Package],
        installed: [Package] = [],
        revision: Int64 = 1,
        database: UUID? = nil,
        architecture: String = "arm64",
        installable: Set<String> = ["arm64"],
        origins: [String: URL] = [:],
        preview: ResolutionSnapshot.ManifestPreview? = nil
    ) -> ResolutionSnapshot {
        ResolutionSnapshot(
            packages: packages,
            installed: installed,
            architecture: architecture,
            installableArchitectures: installable,
            adaptedManifestPreview: preview,
            origins: origins,
            catalogueRevision: revision,
            catalogueIdentity: database ?? self.database
        )
    }

    private func versions(_ plan: ResolutionPlan) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plan.install.map { ($0.identity, $0.latestVersion ?? "") })
    }

    @Test func servesTheSnapshotItWasReadFrom() throws {
        let read = snapshot([app, library])
        let pool = try ResolutionPool(snapshot: read)
        #expect(pool.serves(read))
        let plan = try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: read, pool: pool)
        #expect(versions(plan) == ["app": "1", "library": "1"])
    }

    /// A refresh wrote the catalogue: a newer library is the one to install.
    @Test func aCatalogueWrittenSinceIsReadAgain() throws {
        let pool = try ResolutionPool(snapshot: snapshot([app, library]))
        let moved = snapshot([app, library, newer], revision: 2)
        #expect(!pool.serves(moved))
        let plan = try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: moved, pool: pool)
        #expect(versions(plan) == ["app": "1", "library": "2"])
    }

    /// Two databases can stand at the same revision.
    @Test func anotherDatabaseAtTheSameRevisionIsReadAgain() throws {
        let pool = try ResolutionPool(snapshot: snapshot([app, library]))
        let other = snapshot([app, newer], database: UUID())
        #expect(!pool.serves(other))
        let plan = try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: other, pool: pool)
        #expect(versions(plan) == ["app": "1", "library": "2"])
    }

    /// dpkg installed the library since: nothing to install but the app.
    @Test func anInstalledListThatMovedIsReadAgain() throws {
        let pool = try ResolutionPool(snapshot: snapshot([app, library]))
        let moved = snapshot([app, library], installed: [pkg("library", "1", installed: true)])
        #expect(!pool.serves(moved))
        let plan = try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: moved, pool: pool)
        #expect(versions(plan) == ["app": "1"])
    }

    /// An installed package that came from elsewhere keeps to its repository.
    @Test func originsThatMovedAreReadAgain() throws {
        let installed = pkg("library", "1", installed: true)
        let elsewhere = pkg("library", "2", source: "https://elsewhere.test/")
        let read = snapshot([library, elsewhere], installed: [installed])
        let pool = try ResolutionPool(snapshot: read)
        let update = ResolutionRequest(updateAll: true)
        #expect(try versions(PackageResolver.resolve(request: update, snapshot: read, pool: pool)) == ["library": "2"])
        let moved = try snapshot(
            [library, elsewhere],
            installed: [installed],
            origins: ["library": #require(URL(string: "https://example.test/"))]
        )
        #expect(!pool.serves(moved))
        #expect(try versions(PackageResolver.resolve(request: update, snapshot: moved, pool: pool)).isEmpty)
    }

    /// Patch wrote the control paragraph a package is solved with from then on.
    @Test func adaptedParagraphsThatMovedAreReadAgain() throws {
        let tweak = pkg("tweak", "1", ["architecture": "other"])
        let preview: ResolutionSnapshot.ManifestPreview = { fields in
            fields.merging(["pre-depends": "compat"]) { $1 }
        }
        var read = snapshot([tweak, pkg("compat")], installable: ["arm64", "other"], preview: preview)
        let pool = try ResolutionPool(snapshot: read)
        let request = ResolutionRequest(actions: [.install(tweak)])
        #expect(try versions(PackageResolver.resolve(request: request, snapshot: read, pool: pool)).keys.sorted() == ["compat", "tweak"])
        read.adaptedManifests = [tweak: tweak.latestMetadata ?? [:]]
        #expect(!pool.serves(read))
        #expect(try versions(PackageResolver.resolve(request: request, snapshot: read, pool: pool)).keys.sorted() == ["tweak"])
    }

    @Test func otherArchitecturesAreReadAgain() throws {
        let tweak = pkg("tweak", "1", ["architecture": "other"])
        let pool = try ResolutionPool(snapshot: snapshot([tweak]))
        let adapting = snapshot([tweak], installable: ["arm64", "other"])
        #expect(!pool.serves(adapting))
        let plan = try PackageResolver.resolve(request: .init(actions: [.install(tweak)]), snapshot: adapting, pool: pool)
        #expect(versions(plan) == ["tweak": "1"])
    }

    /// A snapshot made by hand names no database: nothing says two of them
    /// hold the same packages.
    @Test func aSnapshotMadeByHandIsNeverServed() throws {
        let made = ResolutionSnapshot(packages: [app, library], installed: [], architecture: "arm64")
        #expect(try !ResolutionPool(snapshot: made).serves(made))
    }

    /// A `.deb` on disk, or another repository's copy of an installed
    /// package, is not among the pool's candidates: the request is solved
    /// with it, and the pool is left as it was.
    @Test func aPackageThePoolDoesNotOfferIsSolvedWithIt() throws {
        let read = snapshot([app, library])
        let pool = try ResolutionPool(snapshot: read)
        let local = Package(identity: "library", payload: ["3": [
            "package": "library", "version": "3", "architecture": "arm64", "filename": "file:///tmp/library.deb",
        ]])
        #expect(!pool.offers(.init(actions: [.install(local)])))
        let plan = try PackageResolver.resolve(
            request: .init(actions: [.install(app), .install(local)]),
            snapshot: read,
            pool: pool
        )
        #expect(Set(plan.install) == [app, local])
        #expect(pool.offers(.init(actions: [.install(app)])))
        #expect(!pool.candidates.contains(local))
    }

    /// dpkg left the package unpacked and asked for a reinstall: the pool
    /// holds its record whatever the request, and each request is refused
    /// or let through as it would be without one.
    @Test func anUnfinishedInstallIsJudgedPerRequest() throws {
        let broken = pkg("library", "1", ["status": "install reinstreq half-installed"], installed: true)
        let read = snapshot([app, library], installed: [broken])
        let pool = try ResolutionPool(snapshot: read)
        #expect(throws: ResolutionFailure.self) {
            try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: read, pool: pool)
        }
        let repair = try PackageResolver.resolve(request: .init(actions: [.install(library)]), snapshot: read, pool: pool)
        #expect(repair.install == [library])
        #expect(throws: ResolutionFailure.self) {
            try PackageResolver.resolve(request: .init(actions: [.remove("library")]), snapshot: read, pool: pool)
        }
    }

    /// What the queue keeps between taps: a pool that serves stays, a
    /// stale one is read again for the next tap, and a request for a
    /// package outside the catalogue reads only its own.
    @Test func aKeptPoolIsReadAgainOnlyForTheCatalogue() throws {
        let read = snapshot([app, library])
        var kept: ResolutionPool? = try ResolutionPool(snapshot: read)
        _ = try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: read, keeping: &kept)
        #expect(kept?.snapshot.catalogueRevision == 1)

        let moved = snapshot([app, library, newer], revision: 2)
        let local = Package(identity: "library", payload: ["3": [
            "package": "library", "version": "3", "architecture": "arm64", "filename": "file:///tmp/library.deb",
        ]])
        let own = try PackageResolver.resolve(
            request: .init(actions: [.install(app), .install(local)]),
            snapshot: moved,
            keeping: &kept
        )
        #expect(Set(own.install) == [app, local])
        #expect(kept?.snapshot.catalogueRevision == 1)

        let plan = try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: moved, keeping: &kept)
        #expect(versions(plan) == ["app": "1", "library": "2"])
        #expect(kept?.serves(moved) == true)
    }

    @Test func aCancelledReadStops() async throws {
        let read = snapshot([app, library])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ResolutionPool(snapshot: read)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        // and so does a solve that has to read one: nobody waits for why
        let solve = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: read)
        }
        await #expect(throws: CancellationError.self) { try await solve.value }
    }
}
