import CryptoKit
import Foundation
import IrisinProtocol

/// rootless (`/var/jb`) to roothide: what roothide's own RootHidePatcher
/// (`patch.sh`, its Compat Layer mode) makes of a package, made here
/// without its tools. A package comes out of `adapt` as it comes out of the
/// script, and the conformance test holds the two together:
///
/// - `var/jb/x` is installed as `x`, under the jailbreak root;
/// - the package as it was shipped is kept beside it under
///   `var/mobile/Library/pkgmirror`, where rootless-compat looks it up;
/// - every Mach-O has its `/var/jb` load commands respelled and is signed
///   again (`MachOBinary`), a program with roothide's entitlements merged
///   into its own, and gets a `.roothidepatch` link beside it: the mark
///   rootless-compat loads `AutoPatches.dylib` for, which redirects the
///   `/var/jb` strings still in the code at run time;
/// - every property list is written as XML, and a daemon's and a libSandy
///   profile's paths are respelled in it; maintainer scripts and the control
///   paragraph are edited (`RootlessToRoothide+Text`), the control gaining
///   the Pre-Depends the resolver was told about when there is a Mach-O.
///   The compat layer is there for code, so a package with none (a theme)
///   goes without it and without `com.roothide.patchloader` behind it,
///   where the script adds it to every package: the one place the two part
///   ways;
/// - a hard link stays one where nothing was written anew: a name that
///   ldid or sed wrote is a file of its own, as the script leaves it.
///
/// An app is no case of its own, to the script or here: its bundle moves
/// like any directory and its programs are signed like any program.
///
/// What is left is refused rather than half converted: a package with
/// files outside `/var/jb`, a Mach-O that is not a library, a bundle or a
/// program, a Mach-O maintainer script, conffiles, a set-id mode, or a path
/// that lies beneath one of its own links. The script writes the system's
/// side of the device for the first and cannot build conffiles at all; the
/// rest are not converted here yet.
public struct RootlessToRoothide: PackageAdapter {
    public let source = BootstrapArchitecture.rootless
    public let target = BootstrapArchitecture.roothide

    /// roothide's runtime half, spelled the way its patcher writes it.
    private static let compatLayer = "rootless-compat(>= 0.9)"

    public var impliedPreDepends: String? {
        Self.compatLayer
    }

    public init() {}

    /// The patcher's own refusals: what is not a tweak, and the packages
    /// its authors know the compat layer cannot carry (matched anywhere in
    /// the name, as it matches them).
    public func canAttemptInstall(control: [String: String]) -> Bool {
        guard let package = control["package"] else { return false }
        // Irisin ships a native package for each bootstrap. Its daemon and
        // helper must never be installed through compatibility mode.
        return !["ellekit", "oldabi", "wiki.qaq.irisin"].contains(package)
            && control["maintainer"] != "Procursus Team <support@procurs.us>"
            && ![
                "xinam1ne", "xinamine", "legizmo", "vnodebypass", "voicechangerx-rootless", "appsyncunified",
                "choicy", "com.tigisoftware.filza", "sileo", "zebra", "com.opa334.ccsupport", "ws.hbang.common",
                "libsandy", "preferenceloader", "newterm3", "altlist",
            ].contains(where: package.contains)
    }

    public func adapt(preparedPackageAt directory: URL) throws -> String {
        let manifest = try PreparedPackage.read(from: directory)
        let fields = try DebianControl.parse(manifest.control, preservingLinesFor: ["description"])
        guard let package = fields["package"], !package.isEmpty, !package.contains("/"),
              try PreparedPackage.relativePath(package) == package
        else { throw CocoaError(.fileReadCorruptFile) }

        // `prepareDebianPackage` numbers the archive's own members as well,
        // so the next free number is the directory's, not the manifest's
        var sequence = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { $0.hasPrefix("blob-") ? Int($0.dropFirst(5)) : nil }.max() ?? 0
        func store(_ data: Data) throws -> PreparedFile {
            sequence += 1
            try data.write(to: directory.appendingPathComponent("blob-\(sequence)"))
            return PreparedFile(
                name: "blob-\(sequence)",
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                size: Int64(data.count)
            )
        }
        func contents(_ file: PreparedFile) throws -> Data {
            try Data(contentsOf: directory.appendingPathComponent(file.name))
        }
        /// `data` in place of `file`, which is kept when it holds that already.
        func store(_ data: Data, over file: PreparedFile) throws -> PreparedFile {
            try data == contents(file) ? file : store(data)
        }
        /// nil for what is not a Mach-O, or has a name the patcher never opens.
        func binary(_ file: PreparedFile, at path: String, reportedAs reported: String) throws -> MachOBinary? {
            guard file.size > 0, Self.patcherOpens(path) else { return nil }
            do {
                return try MachOBinary(contentsOf: directory.appendingPathComponent(file.name))
            } catch MachOFailure.notCode {
                throw AdaptationFailure.notSimple(package: package, path: reported)
            } catch is MachOFailure {
                throw AdaptationFailure.malformedBinary(package: package, path: reported)
            }
        }

        // a rootless package names its conffiles `/var/jb/...`; the patcher
        // leaves the list as it is and dpkg-deb then refuses to build it
        if let conffiles = manifest.controlFiles["conffiles"],
           try !Data(contentsOf: directory.appendingPathComponent(conffiles.name))
           .allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) })
        {
            throw AdaptationFailure.notSimple(package: package, path: "DEBIAN/conffiles")
        }

        let mirrorRoot = "var/mobile/Library/pkgmirror"
        // where a payload path must not land once `var/jb/` is gone: the
        // control directory the script builds from, the system as roothide
        // spells it, the compat layer's link, and the mirror written here
        let reserved = ["DEBIAN", "rootfs", "var/jb", mirrorRoot]
        // entries made up here get a time from the package, so that the
        // same package adapts to the same manifest every time
        let earliest = manifest.entries.map(\.modificationTime).min() ?? 0
        var tree = Tree(package: package)
        var mirror: [(entry: PreparedEntry, reported: String)] = []
        var rewritten: [String: PreparedFile] = [:]

        // tar unpacks a hard link as one file under every name, with the
        // mode and owner of the entry that brought it, and the patcher
        // walks each name on its own
        let named = Dictionary(manifest.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        func origin(of entry: PreparedEntry) throws -> PreparedEntry {
            var origin = entry
            var seen: Set<String> = []
            while origin.kind == .hardLink {
                guard seen.insert(origin.path).inserted, let target = origin.linkTarget, let next = named[target] else {
                    throw AdaptationFailure.notSimple(package: package, path: entry.path)
                }
                origin = next
            }
            guard entry.kind != .hardLink || origin.kind == .file else {
                throw AdaptationFailure.notSimple(package: package, path: entry.path)
            }
            return origin
        }
        // plutil writes a property list in place, so every name of a file
        // reads the XML once one of them is a list
        var converted: Set<String> = []
        for entry in manifest.entries where entry.path.hasPrefix("var/jb/") && [.file, .hardLink].contains(entry.kind) {
            let path = String(entry.path.dropFirst("var/jb/".count))
            let origin = try origin(of: entry)
            if let file = origin.file, file.size > 0, Self.patcherOpens(path), Self.isPropertyList((path as NSString).lastPathComponent) {
                converted.insert(origin.path)
            }
        }
        /// That XML, by the entry of the file.
        var lists: [String: PreparedFile] = [:]
        /// The names of each file that still share it, in the payload and in
        /// the mirror, by the entry of the file.
        var linked: [String: [String]] = [:]
        var mirrorLinked: [String: [String]] = [:]

        for entry in manifest.entries where (entry.path as NSString).lastPathComponent != ".DS_Store" {
            if entry.kind == .directory, entry.path == "var" || entry.path == "var/jb" {
                continue
            }
            let origin = try origin(of: entry)
            guard entry.path.hasPrefix("var/jb/"), origin.mode & 0o6000 == 0 else {
                throw AdaptationFailure.notSimple(package: package, path: entry.path)
            }
            let path = String(entry.path.dropFirst("var/jb/".count))
            guard !reserved.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                throw AdaptationFailure.notSimple(package: package, path: entry.path)
            }
            mirror.append((origin.moved(to: "\(mirrorRoot)/\(path)", owner: 501, mode: 0o755), entry.path))
            guard let file = origin.file else {
                try tree.add(entry.moved(to: path), reportedAs: entry.path)
                continue
            }
            mirrorLinked[origin.path, default: []].append("\(mirrorRoot)/\(path)")
            let name = (path as NSString).lastPathComponent

            if let binary = try binary(file, at: path, reportedAs: entry.path) {
                // ldid signs a file under its name and writes it anew, so
                // one blob behind two names, a hard link's or not, is two files
                let signed: PreparedFile
                do {
                    signed = try rewritten["\(file.name)/\(name)"] ?? store(binary.rewritten(identifier: name))
                } catch is MachOFailure {
                    throw AdaptationFailure.malformedBinary(package: package, path: entry.path)
                }
                rewritten["\(file.name)/\(name)"] = signed
                try tree.add(origin.moved(to: path, file: signed), reportedAs: entry.path)
                try tree.add(PreparedEntry(
                    path: path + ".roothidepatch", kind: .symbolicLink,
                    linkTarget: "/usr/lib/DynamicPatches/AutoPatches.dylib",
                    mode: 0o755, uid: 0, gid: 0, modificationTime: entry.modificationTime
                ), reportedAs: entry.path + ".roothidepatch")
                continue
            }

            let walked = file.size > 0 && Self.patcherOpens(path)
            var edited: Data?
            if walked, Self.isScript(name) {
                // sed would read the file or plutil's XML of it, whichever
                // name `find` happens to walk first
                guard !converted.contains(origin.path) else {
                    throw AdaptationFailure.notSimple(package: package, path: entry.path)
                }
                edited = try Self.maintainerScript(contents(file))
            } else if walked, Self.isPropertyList(name), let rule = Self.propertyListRule(at: path) {
                guard let list = try Self.propertyList(contents(file), rule) else {
                    throw AdaptationFailure.notSimple(package: package, path: entry.path)
                }
                edited = list
            }
            if let edited {
                // sed writes the file anew: this name leaves its hard link
                try tree.add(origin.moved(to: path, file: store(edited, over: file)), reportedAs: entry.path)
                continue
            }
            var shared = file
            if converted.contains(origin.path) {
                shared = try lists[origin.path] ?? store(Self.xml(contents(file)), over: file)
                lists[origin.path] = shared
            }
            try tree.add(origin.moved(to: path, file: shared), reportedAs: entry.path)
            linked[origin.path, default: []].append(path)
        }

        var controlFiles = manifest.controlFiles.filter { $0.key != ".DS_Store" }
        try tree.add(
            PreparedEntry(path: mirrorRoot, kind: .directory, mode: 0o755, uid: 501, gid: 501, modificationTime: earliest),
            reportedAs: "var/jb/\(mirrorRoot)"
        )
        for (name, file) in controlFiles.sorted(by: { $0.key < $1.key }) {
            guard try binary(file, at: name, reportedAs: "DEBIAN/\(name)") == nil else {
                throw AdaptationFailure.notSimple(package: package, path: "DEBIAN/\(name)")
            }
            try tree.add(PreparedEntry(
                path: "\(mirrorRoot)/DEBIAN.\(package)/\(name)", kind: .file, file: file,
                mode: 0o755, uid: 501, gid: 501, modificationTime: earliest
            ), parents: 501, reportedAs: "DEBIAN/\(name)")
            // the patcher walks the control directory like the rest
            guard file.size > 0, Self.patcherOpens(name) else { continue }
            let member = try contents(file)
            controlFiles[name] = try store(
                Self.isScript(name) ? Self.maintainerScript(member) : Self.isPropertyList(name) ? Self.xml(member) : member,
                over: file
            )
        }
        for (entry, reported) in mirror {
            try tree.add(entry, parents: 501, reportedAs: reported)
        }
        // `dpkg-deb -b` stores the first name of a file it walks to as the
        // file and the others as hard links to it. `cp -a` kept them all in
        // the mirror, where nothing is written anew.
        for names in Array(linked.values) + Array(mirrorLinked.values) where names.count > 1 {
            let names = names.sorted(by: Self.walksBefore)
            for name in names.dropFirst() {
                tree.link(name, to: names[0])
            }
        }

        let control = Self.control(manifest.control, preDepends: rewritten.isEmpty ? nil : Self.compatLayer)
        controlFiles["control"] = try store(Data(control.utf8))
        return try PreparedPackage(control: control, controlFiles: controlFiles, entries: tree.entries).write(to: directory)
    }

    /// The names the patcher's `find` passes over before it asks what a
    /// file is: a Mach-O called `icon.png` is left as it was, by both.
    private static func patcherOpens(_ path: String) -> Bool {
        if path.hasSuffix(".lua") {
            return (path as NSString).lastPathComponent == "EQE.lua"
        }
        return !path.contains(".lproj/") && ![
            ".png", ".gif", ".jpg", ".jpeg", ".svg", ".strings", ".js", ".py", ".h", ".json", ".txt", ".xml",
        ].contains(where: path.hasSuffix)
    }

    /// The order `dpkg-deb -b` walks a tree in: depth first, each
    /// directory's names sorted bytewise, so `a/b` comes before `a-c`.
    private static func walksBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.split(separator: "/").lexicographicallyPrecedes(rhs.split(separator: "/")) {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }
}

/// The entries of the adapted package, in the order they are added, every
/// path once. The script unpacks to a directory and packs it again, so every
/// directory on the way to a file is an entry of its result even where the
/// package never listed it; the same is made up here.
private struct Tree {
    /// Named in a refusal.
    let package: String
    private(set) var entries: [PreparedEntry] = []
    private var kinds: [String: PreparedEntryKind] = [:]
    /// Where each directory made up for a path below it is in `entries`.
    private var madeUp: [String: Int] = [:]

    /// `kinds` and `madeUp` are private, so the implicit memberwise
    /// initializer is private to `Tree` itself and the adaptation above
    /// cannot call it. Xcode 26 says so and Xcode 27 does not, which is how
    /// this passed here and failed on CI. A tree is filled by `add` in any
    /// case; the package name is the whole of its state at birth.
    init(package: String) {
        self.package = package
    }

    /// A path below anything but a directory (a link, a file) is refused:
    /// what installs there depends on what the link points at. `reported`
    /// is the entry as the archive spells it, for the refusal.
    mutating func add(_ entry: PreparedEntry, parents owner: UInt32 = 0, reportedAs reported: String) throws {
        let refusal = AdaptationFailure.notSimple(package: package, path: reported)
        var missing: [String] = []
        var path = entry.path
        while let slash = path.lastIndex(of: "/") {
            path = String(path[..<slash])
            if let kind = kinds[path] {
                guard kind == .directory else { throw refusal }
                break
            }
            missing.append(path)
        }
        for path in missing.reversed() {
            kinds[path] = .directory
            madeUp[path] = entries.count
            entries.append(PreparedEntry(
                path: path, kind: .directory, mode: 0o755, uid: owner, gid: owner, modificationTime: entry.modificationTime
            ))
        }
        if let kind = kinds[entry.path] {
            // anything but two directories is two things in one place
            guard kind == .directory, entry.kind == .directory else { throw refusal }
            // the archive listed the directory after its contents: its own
            // entry is the one unpacking leaves; one the mirror needs as well
            // (`var/mobile/Library`) stays the package's
            if let index = madeUp.removeValue(forKey: entry.path) {
                entries[index] = entry
            }
            return
        }
        kinds[entry.path] = entry.kind
        entries.append(entry)
    }

    /// The file at `path` as a hard link to `target`, which holds the same.
    mutating func link(_ path: String, to target: String) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        let entry = entries[index]
        entries[index] = PreparedEntry(
            path: path, kind: .hardLink, linkTarget: target,
            mode: entry.mode, uid: entry.uid, gid: entry.gid, modificationTime: entry.modificationTime
        )
        kinds[path] = .hardLink
    }
}

private extension PreparedEntry {
    func moved(to path: String, file: PreparedFile? = nil, owner: UInt32? = nil, mode: UInt32? = nil) -> PreparedEntry {
        PreparedEntry(
            path: path, kind: kind, file: file ?? self.file, linkTarget: linkTarget,
            mode: mode ?? self.mode, uid: owner ?? uid, gid: owner ?? gid, modificationTime: modificationTime
        )
    }
}
