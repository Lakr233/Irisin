import AptRepository
import Foundation

struct PoolPackage {
    typealias Group = PackageRequirementGroup
    typealias Element = Group.Clause.Term

    let package: Package
    let version: String
    let installed: Bool
    let fields: [String: String]
    let relations: [Group.Kind: [Group.Clause]]
    /// What the solver is told: an adapted package arrives as the
    /// bootstrap's own architecture, and libsolv drops any other.
    let architecture: String

    /// An installed record dpkg left unfinished refuses every plan but the
    /// one whose `action` repairs it: installing it again, the repair the
    /// helper tells the user to make, or removing it, which dpkg refuses
    /// only while the record needs a reinstall.
    ///
    /// A package an adapter rewrites is read as it will be once rewritten:
    /// the snapshot's architecture, and the control paragraph the adapter
    /// wrote, or its preview of one while the file is not adapted yet.
    init(_ package: Package, installed: Bool, action: ResolutionAction? = nil, in snapshot: ResolutionSnapshot) throws {
        guard package.payload.count == 1, let version = package.latestVersion,
              DebianVersion.isValid(version), var fields = package.latestMetadata
        else {
            throw ResolutionFailure(.unreadableVersion(package: package.identity))
        }
        let adapted = !installed && snapshot.adapts(package)
        if adapted {
            fields = snapshot.adaptedManifests[package] ?? snapshot.adaptedManifestPreview?(fields) ?? fields
        }
        // the field is a list to dpkg and to the catalogue; libsolv takes one
        // name and drops a package whose name is not the bootstrap's or `all`
        let listed = Package.architectures(in: fields)
        architecture = if adapted || listed.contains(snapshot.architecture) {
            snapshot.architecture
        } else if listed.contains("all") {
            "all"
        } else {
            fields["architecture"] ?? "all"
        }
        var relations: [Group.Kind: [Group.Clause]] = [:]
        for type in Group.Kind.allCases {
            guard let value = fields[type.rawValue],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            guard let group = Group(value: value, type: type) else {
                throw ResolutionFailure(.unreadableMetadata(package: package.identity, version: version))
            }
            relations[type] = group.requirements
        }
        if installed {
            let state = (fields["status"] ?? "install ok installed").split(separator: " ")
            let ok = state.count == 3 && state[1] == "ok"
            let allowed = switch action {
            case .install: true
            case .remove: ok
            case nil: ok && state[2] != "half-installed"
            }
            guard allowed else { throw ResolutionFailure(.unfinishedInstall(package: package.identity)) }
        }
        self.package = package
        self.version = version
        self.installed = installed
        self.fields = fields
        self.relations = relations
    }

    var name: String {
        package.identity
    }

    var configured: Bool {
        !installed || fields["status"]?.hasSuffix(" installed") != false
    }

    var held: Bool {
        fields["status"]?.hasPrefix("hold ") == true
    }

    var protected: Bool {
        fields["essential"] == "yes" || fields["protected"] == "yes" ||
            [
                "apt", "dpkg", "essential", "firmware", "bash", "coreutils",
                "base", "base-files", "base-passwd", "libroot", "roothide",
            ].contains(name)
    }

    /// Only single-architecture transactions are supported. :any requires the
    /// provider's explicit Multi-Arch permission, even on the native architecture.
    func satisfies(_ element: Element, architecture: String) -> Bool {
        if let qualifier = element.architectureQualifier {
            if qualifier == "any" {
                guard fields["multi-arch"] == "allowed" || fields["multi-arch"] == "foreign" else { return false }
            } else if qualifier != "native", qualifier != architecture {
                return false
            }
        }
        if name == element.representPackage, element.doesThisVersionMatchesRequirement(version: version) {
            return true
        }
        for provided in (relations[.provides] ?? []).flatMap(\.elements)
            where provided.representPackage == element.representPackage
        {
            if element.versionType == .noneSpecific {
                return true
            }
            if provided.versionType == .equal,
               element.doesThisVersionMatchesRequirement(version: provided.versionValue)
            {
                return true
            }
        }
        return false
    }

    /// Recommends and Suggests. The solver never sees them; only the
    /// autoremove mark follows them, as apt does by default. One that does
    /// not parse is ignored rather than failing the plan.
    var weakDependencies: [Group.Clause] {
        ["recommends", "suggests"].flatMap { key in
            fields[key].flatMap { Group(value: $0, type: .depends) }?.requirements ?? []
        }
    }

    var capabilities: Set<String> {
        Set([name] + (relations[.provides] ?? []).flatMap(\.elements).map(\.representPackage))
    }

    static func solvVersion(_ version: String) -> String {
        version.contains("-") ? version : version + "-0"
    }
}
