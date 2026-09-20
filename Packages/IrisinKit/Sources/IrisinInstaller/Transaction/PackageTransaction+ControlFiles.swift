import Darwin
import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// dpkg's `pkg_infodb_update`: every info file the old version had goes
    /// unless the new package ships it, and every control member the new
    /// package ships is installed under its own name, whatever it is called.
    /// The control file itself, a member named `list` and one with a dot in
    /// its name are the exceptions, as they are for dpkg.
    func installControlFiles(_ identity: String, archive: PackageArchive) throws {
        let incoming = archive.package.controlFiles.filter { name, _ in
            name != "control" && name != "list" && !name.contains(".")
        }
        for member in try database.infoMembers(identity) where member != "list" && incoming[member] == nil {
            let path = database.info(identity, member)
            try filesystem.backup(path)
            try FileManager.default.removeItem(at: path)
            try filesystem.noteRemoved(path)
        }
        for (member, blob) in incoming {
            let path = database.info(identity, member)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try filesystem.backup(path)
            try PackageDatabase.write(Data(contentsOf: archive.content(blob)), to: path)
            if ["preinst", "postinst", "prerm", "postrm", "config"].contains(member) {
                guard chmod(path.path, 0o755) == 0 else {
                    throw PackageFailure("Cannot set maintainer script permissions")
                }
            }
            try filesystem.noteWritten(path)
        }
    }
}
