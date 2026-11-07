import Darwin
import Foundation
import IrisinProtocol

extension InstallerRunner {
    /// One installed package rebuilt into the file the client passed
    /// (`PackageRepacker`). The transcript's log is appended to like any other
    /// job's that changes nothing: the install being investigated stays in it.
    func repack(_ identity: String) -> Int32 {
        defer { close(repackDescriptor) }
        emit(.phase(.preparing))
        do {
            let repacker = try PackageRepacker(
                root: URL(fileURLWithPath: installRoot.isEmpty ? "/" : installRoot).resolvingSymlinksInPath(),
                layout: layout,
                databaseDirectory: URL(fileURLWithPath: layout.resolve(layout.bootstrapPath("/Library/dpkg"))),
                output: repackDescriptor,
                emit: emit
            )
            try emit(.repacked(repacker.run(identity)))
            return 0
        } catch {
            emit(.failure(.repackFailed(identity: identity, detail: String(describing: error))))
            return 1
        }
    }
}
