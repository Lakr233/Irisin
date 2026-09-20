import Foundation

/// The texts roothide's patcher edits with sed and plutil, edited the same
/// way and in the same order, so that a package comes out of `adapt` as it
/// comes out of `patch.sh`.
extension RootlessToRoothide {
    /// The directories the patcher moves under `/rootfs` wherever a path to
    /// one starts, in its order.
    private static let systemDirectories = ["Applications", "Library", "private", "System", "sbin", "bin", "etc", "lib", "usr", "var"]

    /// Whether the patcher edits a file of this name as a maintainer script.
    /// It asks `[[ {preinst,prerm,postinst,postrm,extrainst_} =~ "$fname" ]]`,
    /// which with the name quoted is a test for a substring: a payload file
    /// called `inst` or `rm` is a script to it, and so it is here.
    static func isScript(_ name: String) -> Bool {
        !skipsText(name) && "{preinst,prerm,postinst,postrm,extrainst_}".range(of: name, options: .literal) != nil
    }

    /// Whether the patcher converts a file of this name to XML: its
    /// extension, `${fname##*.}`, is `plist`, which a name with no dot is
    /// its own extension for.
    static func isPropertyList(_ name: String) -> Bool {
        fileExtension(name) == "plist"
    }

    /// The names neither edit touches, tested as loosely: an extension that
    /// is part of `{png,strings}` (`s`, `in`, an empty one).
    private static func skipsText(_ name: String) -> Bool {
        let suffix = fileExtension(name)
        return suffix.isEmpty || "{png,strings}".range(of: suffix, options: .literal) != nil
    }

    /// `${fname##*.}`: what follows the last dot, a byte, or the whole name
    /// where there is none. `String` finds a dot by character, and not one
    /// that a character in front of it has taken into its own.
    private static func fileExtension(_ name: String) -> String {
        name.utf8.lastIndex(of: UInt8(ascii: ".")).map { String(decoding: name.utf8[name.utf8.index(after: $0)...], as: UTF8.self) } ?? name
    }

    /// What `plutil -convert xml1` leaves of a file: Foundation's XML, which
    /// is plutil's to the byte since both are CoreFoundation's, or the file
    /// as it was when it is no property list (plutil says so and goes on).
    static func xml(_ data: Data) -> Data {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        else { return data }
        return xml
    }

    /// The property lists the patcher edits after converting them: a daemon
    /// and a libSandy profile.
    enum PropertyListRule {
        /// `/var/jb/x` is `/x`, where launchd on roothide finds it.
        case daemon
        /// A path is spelled as a script's is (`maintainerScript`), but only
        /// where a string starts, and `/` itself is the system's.
        case sandbox
    }

    /// The rule for a property list at `path`, from the package root. The
    /// patcher tests its directory, `/` and all, as a pattern against
    /// `{/Library/LaunchDaemons}` and then `{/Library/libSandy}`, so a
    /// list at the top or directly in `/Library` is a daemon's as well.
    ///
    /// bash's `=~` is POSIX's extended `regcomp`, which is called here: ICU
    /// reads `(?i)` or `\Q` where POSIX does not, and the other way round.
    /// A directory with a character that is not ASCII matches only where
    /// the device's locale says, unless it is no pattern at all: then it is
    /// text neither of the two holds.
    static func propertyListRule(at path: String) throws -> PropertyListRule? {
        let directory = "/" + (path as NSString).deletingLastPathComponent
        if !directory.utf8.allSatisfy({ $0 < 0x80 }) {
            guard directory.utf8.contains(where: #"\^$.|?*+()[]{}"#.utf8.contains) else { return nil }
            throw LocaleDependent()
        }
        var pattern = regex_t()
        // a directory that is no pattern (`Fixture (1)` is one; `[` is not)
        // matches nothing, as bash's `=~` fails it
        guard regcomp(&pattern, directory, REG_EXTENDED | REG_NOSUB) == 0 else { return nil }
        defer { regfree(&pattern) }
        func matches(_ text: String) -> Bool {
            regexec(&pattern, text, 0, nil, 0) == 0
        }
        return matches("{/Library/LaunchDaemons}") ? .daemon : matches("{/Library/libSandy}") ? .sandbox : nil
    }

    /// A text the patcher's tools read by the locale of the device they run
    /// on, which this cannot know: refused.
    struct LocaleDependent: Error {}

    /// A daemon's or a libSandy profile's property list with its paths
    /// respelled: every key and string, depth first, through `path`, and
    /// the list written as plutil writes it. nil where the patcher, which
    /// runs sed over that XML, would come out otherwise or not at all: a
    /// file that is no property list, a path in the base64 of some data, two
    /// keys made one, or keys that no longer sort as they did (sed edits
    /// them where plutil put them).
    static func propertyList(_ data: Data, _ rule: PropertyListRule) -> Data? {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let edited = respell(list, rule)
        else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0)
    }

    /// `value` with its keys and strings through `path`. Containers are
    /// Foundation's, whose keys are equal only to the same UTF-16, and a
    /// leaf that is not changed is the object that was read.
    private static func respell(_ value: Any, _ rule: PropertyListRule) -> Any? {
        func respelled(_ string: String) -> String? {
            let new = path(string, rule)
            return new.utf16.elementsEqual(string.utf16) ? nil : new
        }
        switch value {
        case let dictionary as NSDictionary:
            let edited = NSMutableDictionary()
            var keys: [(old: String, new: String)] = []
            for (key, value) in dictionary {
                guard let old = key as? String, let value = respell(value, rule) else { return nil }
                let new = respelled(old)
                if let new {
                    edited[new] = value
                } else {
                    edited[key] = value
                }
                keys.append((old, new ?? old))
            }
            // CoreFoundation writes keys in UTF-16 order
            keys.sort { $0.old.utf16.lexicographicallyPrecedes($1.old.utf16) }
            guard edited.count == keys.count,
                  zip(keys, keys.dropFirst()).allSatisfy({ $0.new.utf16.lexicographicallyPrecedes($1.new.utf16) })
            else { return nil }
            return edited
        case let array as NSArray:
            let edited = NSMutableArray()
            for element in array {
                guard let element = respell(element, rule) else { return nil }
                edited.add(element)
            }
            return edited
        case let string as String:
            return respelled(string) ?? value
        case let data as Data:
            // the only other text in the XML that sed could match
            return data.base64EncodedString().contains("/var/jb/") ? nil : value
        default:
            return value
        }
    }

    /// One key or string of a daemon's or a libSandy profile's list, as the
    /// patcher's sed lines leave it in the XML: for a profile, `>/` is where
    /// a string starts and `>/<` a string that is `/`.
    static func path(_ string: String, _ rule: PropertyListRule) -> String {
        var text = string
        switch rule {
        case .daemon:
            text.replace("/var/jb/", "/")
        case .sandbox:
            text.replace("/var/jb/", "/-var/jb/-")
            text.replace("/var/jb", "/-var/jb-")
            // at most one applies: what one writes starts with `/rootfs/`
            if text == "/" || systemDirectories.contains(where: { text.utf8.starts(with: "/\($0)/".utf8) }) {
                text = "/rootfs" + text
            }
            text.replace("/-var/jb/-", "/")
            text.replace("/-var/jb-", "/var/jb")
        }
        return text
    }

    /// A maintainer script for roothide, where a script runs with the
    /// jailbreak root as its `/`: `/var/jb/x` is `/x`, and what was the
    /// system's is under `/rootfs`. The patcher parks every `/var/jb` out of
    /// the way first so that the system rules cannot touch it.
    /// `LocaleDependent` for a shebang sed reads by the locale.
    static func maintainerScript(_ script: Data) throws -> Data {
        try sed(script) { text in
            text.replace("iphoneos-arm64", "iphoneos-arm64e")
            text.replace("/var/jb/", "/-var/jb/-")
            text.replace("/var/jb", "/-var/jb-")
            for directory in systemDirectories {
                text.replace(" /\(directory)/", " /rootfs/\(directory)/")
            }
            text.replace("DIR=\"/Library/", "DIR=\"/rootfs/Library/")
            // `#! /bin/sh` was caught by the rule for ` /bin/`; the
            // interpreter is the bootstrap's. sed's `\s` is whatever the
            // locale calls a space, and only one in ASCII surely is.
            if let shebang = text.range(of: #"^#![ \t\x0B\f\r\x{80}-\x{FF}]*/rootfs/"#, options: .regularExpression) {
                guard text[shebang].unicodeScalars.allSatisfy(\.isASCII) else { throw LocaleDependent() }
                text.replaceSubrange(shebang, with: "#! /")
            }
            text.replace("/-var/jb/-", "/")
            text.replace("/-var/jb-", "/var/jb")
        }
    }

    /// `data` through `edit` one scalar per byte, as sed sees a file: nothing
    /// is refused or changed for the encoding it is in.
    private static func sed(_ data: Data, _ edit: (inout String) throws -> Void) rethrows -> Data {
        var text = String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
        try edit(&text)
        return Data(text.unicodeScalars.map { UInt8($0.value) })
    }

    /// The control paragraph: blank lines dropped, the architecture renamed
    /// wherever it is spelled, a conflict with roothide defused, and
    /// `preDepends`, when there is one, put in front of the field, spelled
    /// as it was given.
    ///
    /// The resolver reads the package's own `Conflicts`, not this one, so a
    /// rootless package that conflicts with the bootstrap is refused a plan
    /// rather than offered one that removes it (`PoolPackage.protected`
    /// names `roothide`). Solving it as rewritten would mean teaching
    /// AptResolver this substitution, which it cannot see from here.
    static func control(_ control: String, preDepends: String?) -> String {
        // sed's lines end at a newline byte, `\r\n` or not
        var lines = control.utf8.split(separator: 0x0A).map {
            String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "iphoneos-arm64", with: "iphoneos-arm64e", options: .literal)
        }
        lines = lines.map {
            $0.utf8.starts(with: "Conflicts: ".utf8) ? $0.replacingOccurrences(of: "roothide", with: "r-o-o-t-l-e-s-s-", options: .literal) : $0
        }
        let end = control.utf8.last == 0x0A ? "\n" : ""
        guard let preDepends else {
            return lines.joined(separator: "\n") + end
        }
        let field = "pre-depends:"
        guard lines.contains(where: { $0.lowercased().hasPrefix(field) }) else {
            return (lines + ["Pre-Depends: \(preDepends)"]).joined(separator: "\n") + "\n"
        }
        lines = lines.map {
            $0.lowercased().hasPrefix(field) ? "Pre-Depends: \(preDepends)," + $0.dropFirst(field.count) : $0
        }
        return lines.joined(separator: "\n") + end
    }
}

private extension String {
    /// One `s|old|new|g`.
    mutating func replace(_ old: String, _ new: String) {
        self = replacingOccurrences(of: old, with: new, options: .literal)
    }
}
