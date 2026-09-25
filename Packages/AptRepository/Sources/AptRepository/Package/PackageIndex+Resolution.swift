import Foundation

public extension PackageIndex {
    /// The catalogue and dpkg's status as they are now. The catalogue is
    /// the expensive half, every package of every repository decoded:
    /// `previous`'s is taken instead when the database has not been written
    /// since it was read, which the revision says in one query.
    /// `evenIfWritten` takes it when the database has been written too: a
    /// refresh writes one repository after another, and a catalogue read
    /// in the middle is out of date before the read ends. The snapshot
    /// then says the revision it was read at, and `changes(since:)` what
    /// moved after it.
    func resolutionSnapshot(
        reusingCatalogueOf previous: ResolutionSnapshot? = nil,
        evenIfWritten: Bool = false
    ) throws -> ResolutionSnapshot {
        let environment = AptEnvironment.current
        let statusURL = URL(fileURLWithPath: environment.dpkgStatusLocation)
        let status = try Self.statusContents(at: statusURL)
        var unchanged: (packages: [Package], revision: Int64)?
        if let previous, previous.catalogueIdentity == db.identity,
           try evenIfWritten || db.resolutionRevision() == previous.catalogueRevision
        {
            unchanged = (previous.packages, previous.catalogueRevision)
        }
        let catalogue = try unchanged ?? db.resolutionCatalogue()
        guard try status == Self.statusContents(at: statusURL) else {
            throw CocoaError(.fileReadUnknown)
        }
        var installed = try Array(DpkgStatus.packages(in: status).values)
        if !installed.contains(where: { $0.identity == "firmware" }) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            installed.append(Package(identity: "firmware", payload: [version: [
                "package": "firmware", "version": version, "architecture": "all",
                "status": "install ok installed", "essential": "yes",
            ]]))
        }
        return ResolutionSnapshot(
            packages: catalogue.packages,
            installed: installed,
            architecture: environment.deviceArchitecture,
            installableArchitectures: environment.installableArchitectures,
            adaptedManifestPreview: environment.adaptedManifestPreview,
            blockedUpdates: Set(blockedUpdateTable),
            offersAdaptedUpdates: offersAdaptedUpdates,
            origins: db.installOrigins(),
            autoInstalled: environment.aptExtendedStatesLocation
                .flatMap { FileManager.default.contents(atPath: $0) }
                .map(Self.autoInstalled(in:)) ?? [],
            statusDigest: ResolutionSnapshot.digest(status),
            catalogueRevision: catalogue.revision,
            catalogueIdentity: db.identity
        )
    }

    func isCurrent(_ snapshot: ResolutionSnapshot) throws -> Bool {
        try changes(since: snapshot).isEmpty
    }

    /// What moved since `snapshot` was read; empty when nothing did.
    func changes(since snapshot: ResolutionSnapshot) throws -> ResolutionSnapshot.Changes {
        var changes: ResolutionSnapshot.Changes = []
        let revision = try db.resolutionRevision()
        if snapshot.catalogueIdentity != db.identity || snapshot.catalogueRevision != revision {
            changes.insert(.catalogue)
        }
        if snapshot.architecture != AptEnvironment.current.deviceArchitecture
            || snapshot.installableArchitectures != AptEnvironment.current.installableArchitectures
            || snapshot.blockedUpdates != Set(blockedUpdateTable)
            || snapshot.offersAdaptedUpdates != offersAdaptedUpdates
        {
            changes.insert(.settings)
        }
        let status = try Self.statusContents(at: URL(fileURLWithPath: AptEnvironment.current.dpkgStatusLocation))
        if snapshot.statusDigest != ResolutionSnapshot.digest(status) {
            changes.insert(.installed)
        }
        return changes
    }

    /// The packages of `packages` their repository no longer offers as
    /// they are here: gone from it, or listed with other fields (a new
    /// file, a new hash). One with no repository, a file the user opened,
    /// is never withdrawn, and neither is the install origin of what is
    /// installed: a reinstall needs no repository to still list it.
    func withdrawn(_ packages: [Package]) -> [Package] {
        packages.filter { package in
            guard let repository = package.repoRef, package.localFileURL == nil else { return false }
            let records = [
                db.package(identity: package.identity, repo: repository),
                db.installOrigin(identity: package.identity),
            ].compactMap(\.self).filter { $0.repoRef == repository }
            return package.payload.contains { version, metadata in
                !records.contains { $0.payload[version] == metadata }
            }
        }
    }

    /// The names `extended_states` marks `Auto-Installed: 1`. The marks only
    /// offer a package for cleanup, so an unreadable paragraph is skipped
    /// rather than failing the plan; Architecture is ignored, one install
    /// per name is all a transaction handles.
    internal static func autoInstalled(in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var result = Set<String>()
        for paragraph in text.components(separatedBy: "\n\n") {
            guard let fields = try? DebianControl.parse(paragraph),
                  fields["auto-installed"] == "1",
                  let name = fields["package"]
            else { continue }
            result.insert(name.lowercased())
        }
        return result
    }

    /// The status file's bytes, or none: a bootstrap that has not written
    /// one yet has nothing installed, and the helper digests that absence
    /// the same way, so a plan made against it still matches. Any other
    /// reason the file cannot be read is a real error: a plan against an
    /// empty system would remove nothing and install everything twice.
    private static func statusContents(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Data()
        }
    }
}
