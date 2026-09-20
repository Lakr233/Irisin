import Foundation
import IrisinProtocol

struct PackageFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// A maintainer script that could not be started or exited unsuccessfully.
struct ScriptFailure: Error, CustomStringConvertible {
    let identity: String
    let member: String
    let status: Int32?
    let detail: String

    init(identity: String, member: String, status: Int32) {
        self.identity = identity
        self.member = member
        self.status = status
        detail = "exited with status \(status)"
    }

    init(identity: String, member: String, underlying: any Error) {
        self.identity = identity
        self.member = member
        status = nil
        detail = String(describing: underlying)
    }

    var description: String {
        "\(identity).\(member) \(detail)"
    }
}

/// A failure that stopped the transaction at one package, so the app can
/// put it on that package's row.
struct PackageStepFailure: Error, CustomStringConvertible {
    let identity: String
    let step: InstallerEvent.PackageStep
    let underlying: any Error

    var description: String {
        String(describing: underlying)
    }

    /// What the app is told. A script is named only when it is the
    /// package's own: another package's script can fail inside this step,
    /// a replaced package's `postrm disappear` for one.
    var problem: InstallerEvent.Problem {
        if let script = underlying as? ScriptFailure, script.identity == identity, let status = script.status {
            return .scriptFailed(identity: identity, step: step, script: script.member, status: status)
        }
        return .packageFailed(identity: identity, step: step, detail: description)
    }

    /// Runs `body`, naming the package and the step in whatever it throws.
    static func attributing<T>(
        _ identity: String,
        _ step: InstallerEvent.PackageStep,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch {
            throw PackageStepFailure(identity: identity, step: step, underlying: error)
        }
    }
}
