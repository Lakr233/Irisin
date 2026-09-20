import Darwin
import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// dpkg's `deferred_configure`: the package is half-configured while
    /// its postinst runs, which takes its pending triggers with it (a
    /// configure counts as having processed them), then installed, or
    /// triggers-awaited while it still waits on another package.
    func configure(_ identity: String) throws {
        guard var fields = database.records[identity] else {
            throw PackageFailure("Cannot configure absent package: \(identity)")
        }
        guard fields["status"]?.contains("reinstreq") != true else {
            throw PackageFailure("Package must be unpacked again before configuration: \(identity)")
        }
        switch PackageDatabase.state(of: fields) {
        case "unpacked", "half-configured": break
        // dpkg refuses to configure these; a plan that lists one has
        // nothing to do for it, and refusing would stop the rest
        case "installed", "triggers-awaited", "triggers-pending": return
        default: throw PackageFailure("Package is not ready for configuration: \(identity)")
        }
        emit(.package(.configuring, identity: identity, version: fields["version"] ?? ""))
        try triggers.changed(identity, paths: [])
        let configuredVersion = fields["config-version"] ?? ""
        PackageDatabase.setState("half-configured", in: &fields)
        try database.commit(identity, fields)
        fields = database.records[identity] ?? fields
        try scripts.run("postinst", identity: identity, arguments: ["configure", configuredVersion])
        fields["config-version"] = fields["version"]
        PackageDatabase.setState(PackageDatabase.configuredState(fields), in: &fields)
        try database.commit(identity, fields)
    }
}
