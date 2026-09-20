import Foundation
import IrisinProtocol

/// Runs package-owned scripts with paths interpreted by the bootstrap shell.
/// The kernel executable and the paths read by that shell are different on
/// roothide. BootstrapLayout owns both conversions.
struct MaintainerScripts {
    let layout: BootstrapLayout
    let database: PackageDatabase
    /// Empty on a device: the bootstrap shell already sees its normal root.
    /// An isolated harness can supply a root for scripts that use DPKG_ROOT.
    let scriptRoot: String
    let emit: (InstallerEvent) -> Void
    /// An explicit recovery policy carried by the closed transaction. It
    /// never skips a script; it only decides whether a script's own failure
    /// stops the package step after that attempt.
    let ignoreScriptFailures: Bool
    /// Called once a script has been started, whatever it did: what the
    /// installer remembers of the tree's shape is that script's to change.
    /// ElleKit's postinst replacing `Library/MobileSubstrate/DynamicLibraries`
    /// with a link is the case (`Documentation/InstallerCaseStudies.md`), and
    /// it is here rather than at the seventeen places that run a script.
    let forgetPaths: () -> Void

    func run(
        _ member: String,
        identity: String,
        architecture: String? = nil,
        arguments: [String],
        source: URL? = nil
    ) throws {
        do {
            let script = source ?? database.info(identity, member)
            guard FileManager.default.fileExists(atPath: script.path) else { return }
            defer { forgetPaths() }
            #if targetEnvironment(simulator)
                // A simulator process is a Mac process: a package's script would
                // run on the host, as the person at the keyboard, against the
                // host's files. Announced, kept in the database, never started;
                // an interpreter line a device would refuse is refused here too.
                _ = try interpreter(in: script)
                emit(.script(identity: identity, member: member, arguments: arguments))
                emit(.notice("Simulator: \(identity).\(member) was not run"))
            #else
                let interpreter = try interpreter(in: script)
                let executable = layout.interpreterPath(interpreter.path)
                let argv = [executable] + interpreter.arguments + [layout.scriptPath(script.path)] + arguments
                let environment = environment(member: member, identity: identity, architecture: architecture)

                emit(.script(identity: identity, member: member, arguments: arguments))
                let status = try ToolSpawn.run(
                    executable: executable,
                    arguments: argv,
                    environment: environment,
                    workingDirectory: layout.tool("/")
                ) { emit(.output($0)) }
                guard status == 0 else {
                    throw ScriptFailure(identity: identity, member: member, status: status)
                }
            #endif
        } catch {
            let failure = error as? ScriptFailure
                ?? ScriptFailure(identity: identity, member: member, underlying: error)
            if ignoreScriptFailures {
                emit(.warning(.scriptFailureIgnored(
                    identity: identity,
                    script: member,
                    detail: failure.detail
                )))
                return
            }
            throw failure
        }
    }

    private func interpreter(in script: URL) throws -> (path: String, arguments: [String]) {
        let file = try FileHandle(forReadingFrom: script)
        defer { try? file.close() }
        let prefix = try file.read(upToCount: 512) ?? Data()
        let firstLine = String(decoding: prefix, as: UTF8.self).split(separator: "\n").first ?? ""
        // dpkg runs a script through execvp, which hands a file with no
        // interpreter line to /bin/sh; a script that starts with a comment
        // or a command runs the same way here.
        guard firstLine.hasPrefix("#!") else {
            return ("/bin/sh", [])
        }
        let words = firstLine.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let path = words.first, path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw PackageFailure("Invalid maintainer script interpreter")
        }
        return (path, Array(words.dropFirst()))
    }

    private func environment(member: String, identity: String, architecture: String?) -> [String: String] {
        layout.rootEnvironment.merging([
            "DPKG_ROOT": scriptRoot,
            "DPKG_ADMINDIR": layout.scriptPath(database.directory.path),
            "DPKG_MAINTSCRIPT_PACKAGE": identity,
            "DPKG_MAINTSCRIPT_NAME": member,
            "DPKG_MAINTSCRIPT_ARCH": architecture ?? database.records[identity]?["architecture"] ?? "all",
        ]) { _, script in script }
    }
}
