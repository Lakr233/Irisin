import Foundation
import IrisinProtocol

/// dpkg-compatible paragraphs and info files. Writes leave a standard updates/
/// record before replacing status, so either implementation can recover a crash.
///
/// Package names are case-insensitive, as they are to dpkg: its
/// `pkg_hash_find_set` lowercases every name it is asked for and stores that
/// spelling, so the status file and the info files it writes are lowercase
/// whatever the control file said. `records` is keyed the same way, a record's
/// `package` field is its key, and an info file is named after it.
///
/// Every record committed here is settled the way dpkg's `modstatdb_note`
/// settles one before writing it, because dpkg's reader treats a stanza it
/// would not have written as a fatal error (`pkg_parse_verify`): pending
/// triggers only on a package whose state is triggers-pending or
/// triggers-awaited, awaited triggers only on one past config-files,
/// Config-Version never on installed, triggers-pending or not-installed,
/// and a package with nothing pending taken out of every other package's
/// Triggers-Awaited.
final class PackageDatabase {
    let directory: URL
    var records: [String: [String: String]] = [:]
    /// Each record's field names as its stanza or its control file spelled
    /// them, in that order: how `paragraph` writes the fields dpkg does not
    /// know, which dpkg keeps as it read them (`SileoDepiction`).
    private(set) var fieldNames: [String: [String]] = [:]

    init(directory: URL) throws {
        self.directory = directory
        // A fresh bootstrap may not have written a status file yet; that is
        // an empty database, and the first commit creates the file.
        let status = directory.appendingPathComponent("status")
        if FileManager.default.fileExists(atPath: status.path) {
            try load(status)
        }
        for record in try updateRecords() {
            try load(record, replacing: true)
        }
    }

    /// The four-digit records under updates/, in order; none when the
    /// directory is missing.
    private func updateRecords() throws -> [URL] {
        let updates = directory.appendingPathComponent("updates")
        guard FileManager.default.fileExists(atPath: updates.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: updates.path).sorted()
            .filter { $0.count == 4 && $0.allSatisfy(\.isNumber) }
            .map { updates.appendingPathComponent($0) }
    }

    private func load(_ url: URL, replacing: Bool = false) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for paragraph in text.components(separatedBy: "\n\n")
            where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            var fields = try DebianControl.parse(paragraph, preservingLinesFor: ["conffiles", "description"])
            // iOS firmware synthesizes GraphicsServices identities containing
            // underscores. Preserve these records without relaxing new wire jobs.
            guard let identity = fields["package"]?.lowercased(),
                  InstallerJob.isPackageIdentity(identity.replacingOccurrences(of: "_", with: "-"))
            else { throw PackageFailure("Invalid installed package record") }
            guard replacing || records[identity] == nil else {
                throw PackageFailure("Duplicate package identity in installed database: \(identity)")
            }
            fields["package"] = identity
            records[identity] = fields
            fieldNames[identity] = DebianControl.fieldNames(paragraph)
        }
    }

    /// The new version's control file decides how its fields are spelled
    /// from the unpack on, as the record dpkg takes from it does.
    func noteFieldNames(_ identity: String, control: String) {
        fieldNames[identity.lowercased()] = DebianControl.fieldNames(control)
    }

    // MARK: - Status words

    static func state(of fields: [String: String]?) -> String {
        fields?["status"]?.split(separator: " ").last.map(String.init) ?? "not-installed"
    }

    /// dpkg's `enum pkgstatus`, in its order, so a state can be compared
    /// against another the way dpkg compares them.
    static let states = [
        "not-installed", "config-files", "half-installed", "unpacked",
        "half-configured", "triggers-awaited", "triggers-pending", "installed",
    ]

    static func rank(_ state: String) -> Int {
        states.firstIndex(of: state) ?? 0
    }

    /// The status word becomes `state`. A package leaving installed or
    /// triggers-pending keeps the version it was configured at in
    /// Config-Version, which dpkg writes for every lower state: a postinst
    /// that fails next hears `configure <version>` again, not a first
    /// install.
    static func setState(_ state: String, in fields: inout [String: String]) {
        fields["config-version"] = configuredVersion(fields)
        let selection = fields["status"]?.split(separator: " ").first.map(String.init) ?? "install"
        fields["status"] = selection + " ok " + state
    }

    /// The state a configured package is in, given its trigger fields:
    /// dpkg's `post_postinst_tasks`.
    static func configuredState(_ fields: [String: String]) -> String {
        if fields["triggers-awaited"] != nil {
            return "triggers-awaited"
        }
        if fields["triggers-pending"] != nil {
            return "triggers-pending"
        }
        return "installed"
    }

    static func isPresent(_ fields: [String: String]?) -> Bool {
        rank(state(of: fields)) > rank("config-files")
    }

    static func isConfigured(_ fields: [String: String]) -> Bool {
        rank(state(of: fields)) >= rank("triggers-awaited")
    }

    /// The version the package's postinst last configured, as dpkg keeps
    /// it: the version itself while installed or triggers-pending, the
    /// Config-Version field otherwise, nothing when it never was configured.
    static func configuredVersion(_ fields: [String: String]) -> String? {
        switch state(of: fields) {
        case "installed", "triggers-pending": fields["version"]
        default: fields["config-version"]
        }
    }

    /// The records a Pre-Depends may be satisfied by, as dpkg's `depisok`
    /// with `allowunconfigd` accepts them: configured packages, and an
    /// unpacked or half-configured one that has been configured before. For
    /// the latter `PackageRelations.matches` checks the configured
    /// version as well as the unpacked one.
    var predependencyWitnesses: [[String: String]] {
        records.values.filter { fields in
            switch Self.state(of: fields) {
            case "installed", "triggers-pending": true
            case "triggers-awaited", "unpacked", "half-configured": fields["config-version"] != nil
            default: false
            }
        }
    }

    // MARK: - Info files

    func info(_ name: String, _ member: String) -> URL {
        directory.appendingPathComponent("info").appendingPathComponent(name.lowercased() + "." + member)
    }

    /// Every info file the package has, by member name.
    func infoMembers(_ identity: String) throws -> [String] {
        let prefix = identity.lowercased() + "."
        let info = directory.appendingPathComponent("info")
        guard FileManager.default.fileExists(atPath: info.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: info.path)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.isEmpty && !$0.contains(".") }
    }

    func files(_ identity: String) throws -> [String] {
        let url = info(identity, "list")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0 != "/" && $0 != "/." && !$0.isEmpty }
    }

    func writeInfo(_ identity: String, member: String, text: String) throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("info"),
            withIntermediateDirectories: true
        )
        let contents: String = if member == "list" {
            // dpkg rejects a blank line and a bare `/` in any .list file,
            // even when it is operating on an unrelated package. The root
            // it writes itself is `/.`, first in every list: the archive's
            // own `./` entry, and what a removal always leaves over.
            "/.\n" + text.split(separator: "\n").filter { $0 != "/" && $0 != "/." }.map { $0 + "\n" }.joined()
        } else {
            text
        }
        try Self.write(Data(contents.utf8), to: info(identity, member))
    }

    // MARK: - Records

    func commit(_ identity: String, _ fields: [String: String]) throws {
        let identity = identity.lowercased()
        var value = fields
        value["package"] = identity
        Self.settle(&value)
        try write(identity, value)
        if value["triggers-pending"] == nil {
            try clearAwaiters(of: identity)
        }
    }

    /// The record is gone, as after dpkg purges a package: its stanza is
    /// no longer informative and is not written.
    func remove(_ identity: String) throws {
        let identity = identity.lowercased()
        try write(identity, nil)
        try clearAwaiters(of: identity)
    }

    private func write(_ identity: String, _ value: [String: String]?) throws {
        let updates = directory.appendingPathComponent("updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        let update = updates.appendingPathComponent("0000")
        // Incorporate earlier interrupted updates before reusing the record name.
        try consolidate()
        if let value {
            try Self.write(Data(Self.paragraph(value, names: fieldNames[identity] ?? []).utf8), to: update)
        }
        records[identity] = value
        try consolidate()
    }

    /// dpkg's `modstatdb_note`: the trigger fields a state may carry, the
    /// state the trigger fields imply, and Config-Version only where the
    /// reader allows it.
    static func settle(_ fields: inout [String: String]) {
        var state = state(of: fields)
        if state != "triggers-pending", state != "triggers-awaited" {
            fields.removeValue(forKey: "triggers-pending")
        }
        if rank(state) <= rank("config-files") {
            fields.removeValue(forKey: "triggers-awaited")
        }
        if fields["triggers-pending"]?.isEmpty == true {
            fields.removeValue(forKey: "triggers-pending")
        }
        if fields["triggers-awaited"]?.isEmpty == true {
            fields.removeValue(forKey: "triggers-awaited")
        }
        if state == "triggers-pending" || state == "triggers-awaited"
            || (state == "installed" && fields["triggers-awaited"] != nil)
        {
            state = configuredState(fields)
            setState(state, in: &fields)
        }
        if ["installed", "triggers-pending", "not-installed"].contains(state) {
            fields.removeValue(forKey: "config-version")
        }
    }

    /// dpkg's `trig_clear_awaiters`: a package with no pending triggers is
    /// not awaited by anyone; an awaiter left with nothing to await is
    /// installed, or triggers-pending when it has triggers of its own.
    private func clearAwaiters(of identity: String) throws {
        for other in records.keys.sorted() {
            guard var fields = records[other], let awaited = fields["triggers-awaited"] else { continue }
            let names = awaited.split(separator: " ").map(String.init)
            guard names.contains(identity) else { continue }
            let remaining = names.filter { $0 != identity }
            fields["triggers-awaited"] = remaining.isEmpty ? nil : remaining.joined(separator: " ")
            if remaining.isEmpty, Self.state(of: fields) == "triggers-awaited" {
                Self.setState(Self.configuredState(fields), in: &fields)
            }
            Self.settle(&fields)
            try write(other, fields)
        }
    }

    func consolidate() throws {
        let status = directory.appendingPathComponent("status")
        let data = Data(
            records.keys.sorted()
                .map { Self.paragraph(records[$0]!, names: fieldNames[$0] ?? []) }
                .joined(separator: "\n").utf8
        )
        if let previous = try? Data(contentsOf: status) {
            try Self.write(previous, to: directory.appendingPathComponent("status-old"))
        }
        try Self.write(data, to: status)
        for record in try updateRecords() {
            try FileManager.default.removeItem(at: record)
        }
    }

    /// dpkg's `fieldinfos` order; a field it does not know follows them,
    /// as dpkg writes its arbitrary fields after the known ones.
    static let fieldOrder = [
        "package", "essential", "protected", "status", "priority", "section", "installed-size",
        "origin", "maintainer", "bugs", "architecture", "multi-arch", "source", "version",
        "config-version", "replaces", "provides", "depends", "pre-depends", "recommends",
        "suggests", "breaks", "conflicts", "enhances", "conffiles", "description",
        "triggers-pending", "triggers-awaited",
    ]

    /// Fields dpkg only writes to its available file, or maps away as
    /// obsolete: a control file's copy of them never reaches the status file.
    static let archiveOnlyFields: Set<String> = [
        "filename", "msdos-filename", "size", "md5sum",
        "recommended", "optional", "class", "revision", "package-revision", "package_revision",
    ]

    /// `names` is the stanza's own spelling of its fields, in its order: a
    /// field dpkg does not know is written under that name and in that
    /// place among the others, as dpkg's `arbitraryfield` list keeps it.
    /// One `names` does not cover follows them, capitalised by word.
    static func paragraph(_ fields: [String: String], names: [String] = []) -> String {
        let known = fieldOrder.filter { fields[$0] != nil }
        var spelling: [String: String] = [:]
        var arbitrary: [String] = []
        for name in names {
            let key = name.lowercased()
            if !fieldOrder.contains(key), fields[key] != nil, spelling[key] == nil {
                spelling[key] = name
                arbitrary.append(key)
            }
        }
        arbitrary += fields.keys.filter { !fieldOrder.contains($0) && spelling[$0] == nil }.sorted()
        return (known + arbitrary).map { key in
            let title = spelling[key] ?? key.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
            let value = fields[key]!
            // dpkg's lines end at a newline byte: `String` takes `\r\n` for a
            // character of its own, and a field would end inside the value
            let lines = value.utf8.split(separator: 0x0A, omittingEmptySubsequences: key == "conffiles")
                .map { String(decoding: $0, as: UTF8.self) }
            if key == "conffiles" {
                return title + ":\n" + lines.map { " " + $0 }.joined(separator: "\n")
            }
            if lines.count > 1 {
                return title + ": " + lines[0] + lines.dropFirst().map { "\n " + $0 }.joined()
            }
            return title + ": " + value
        }.joined(separator: "\n") + "\n"
    }

    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("irisin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o644]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 {
            _ = fsync(parent); close(parent)
        }
    }
}
