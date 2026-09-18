import Foundation

/// The two texts roothide's patcher edits with sed, edited the same way and
/// in the same order, so that a package comes out of `adapt` as it comes out
/// of `patch.sh`.
extension RootlessToRoothide {
    /// The control members the patcher treats as scripts. It matches them
    /// loosely, so that a payload file called `rm` is rewritten as well;
    /// that is its bug, and only these members of the control archive are
    /// rewritten here.
    static let maintainerScripts: Set<String> = ["preinst", "prerm", "postinst", "postrm", "extrainst_"]

    /// A maintainer script for roothide, where a script runs with the
    /// jailbreak root as its `/`: `/var/jb/x` is `/x`, and what was the
    /// system's is under `/rootfs`. The patcher parks every `/var/jb` out of
    /// the way first so that the system rules cannot touch it.
    static func maintainerScript(_ script: Data) -> Data {
        // one scalar per byte, as sed sees the file: no script is refused
        // or changed for the encoding it is in
        var text = String(String.UnicodeScalarView(script.map { Unicode.Scalar($0) }))
        func replace(_ old: String, _ new: String) {
            text = text.replacingOccurrences(of: old, with: new, options: .literal)
        }
        replace("iphoneos-arm64", "iphoneos-arm64e")
        replace("/var/jb/", "/-var/jb/-")
        replace("/var/jb", "/-var/jb-")
        for directory in ["Applications", "Library", "private", "System", "sbin", "bin", "etc", "lib", "usr", "var"] {
            replace(" /\(directory)/", " /rootfs/\(directory)/")
        }
        replace("DIR=\"/Library/", "DIR=\"/rootfs/Library/")
        // `#! /bin/sh` was caught by the rule for ` /bin/`; the interpreter is the bootstrap's
        if let shebang = text.range(of: "^#![ \\t]*/rootfs/", options: .regularExpression) {
            text.replaceSubrange(shebang, with: "#! /")
        }
        replace("/-var/jb/-", "/")
        replace("/-var/jb-", "/var/jb")
        return Data(text.unicodeScalars.map { UInt8($0.value) })
    }

    /// The control paragraph: blank lines dropped, the architecture renamed
    /// wherever it is spelled, a conflict with roothide defused, and
    /// `preDepends`, when there is one, put in front of the field, spelled
    /// as it was given.
    ///
    /// The resolver reads the package's own `Conflicts`, not this one, so a
    /// rootless package that conflicts with the bootstrap is refused a plan
    /// rather than offered one that removes it (`SolverPackage.protected`
    /// names `roothide`). Solving it as rewritten would mean teaching
    /// AptResolver this substitution, which it cannot see from here.
    static func control(_ control: String, preDepends: String?) -> String {
        var lines = control.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.replacingOccurrences(of: "iphoneos-arm64", with: "iphoneos-arm64e")
        }
        lines = lines.map {
            $0.hasPrefix("Conflicts: ") ? $0.replacingOccurrences(of: "roothide", with: "r-o-o-t-l-e-s-s-") : $0
        }
        guard let preDepends else {
            return lines.joined(separator: "\n") + (control.hasSuffix("\n") ? "\n" : "")
        }
        let field = "pre-depends:"
        guard lines.contains(where: { $0.lowercased().hasPrefix(field) }) else {
            return (lines + ["Pre-Depends: \(preDepends)"]).joined(separator: "\n") + "\n"
        }
        lines = lines.map {
            $0.lowercased().hasPrefix(field) ? "Pre-Depends: \(preDepends)," + $0.dropFirst(field.count) : $0
        }
        return lines.joined(separator: "\n") + (control.hasSuffix("\n") ? "\n" : "")
    }
}
