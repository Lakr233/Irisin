import Foundation

public extension PackageIndex {
    /// The catalogue and dpkg's status as they are now. The catalogue is
    /// the expensive half, every package of every repository decoded:
    /// `previous`'s is taken instead when the database has not been written
    /// since it was read, which the revision says in one query.
    func resolutionSnapshot(reusingCatalogueOf previous: ResolutionSnapshot? = nil) throws -> ResolutionSnapshot {
        let environment = AptEnvironment.current
        let statusURL = URL(fileURLWithPath: environment.dpkgStatusLocation)
        let status = try Self.statusContents(at: statusURL)
        var unchanged: (packages: [Package], revision: Int64)?
        if let previous, previous.catalogueIdentity == db.identity {
            let revision = try db.resolutionRevision()
            if revision == previous.catalogueRevision {
                unchanged = (previous.packages, revision)
            }
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
        guard try snapshot.catalogueRevision == (db.resolutionRevision()),
              snapshot.architecture == AptEnvironment.current.deviceArchitecture,
              snapshot.installableArchitectures == AptEnvironment.current.installableArchitectures,
              snapshot.blockedUpdates == Set(blockedUpdateTable),
              snapshot.offersAdaptedUpdates == offersAdaptedUpdates else { return false }
        let status = try Self.statusContents(at: URL(fileURLWithPath: AptEnvironment.current.dpkgStatusLocation))
        return snapshot.statusDigest == ResolutionSnapshot.digest(status)
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
