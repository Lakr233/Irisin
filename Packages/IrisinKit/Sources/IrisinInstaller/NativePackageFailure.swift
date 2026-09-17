import Foundation
import IrisinProtocol

struct NativePackageFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// A maintainer script that exited with a status other than 0.
struct ScriptFailure: Error, CustomStringConvertible {
    let identity: String
    let member: String
    let status: Int32

    var description: String {
        "\(identity).\(member) exited with status \(status)"
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
        if let script = underlying as? ScriptFailure, script.identity == identity {
            return .scriptFailed(identity: identity, step: step, script: script.member, status: script.status)
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
