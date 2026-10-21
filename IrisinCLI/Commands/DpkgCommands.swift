import ArgumentParser
import Darwin
import Foundation
import IrisinProtocol

/// What maintainer scripts ask dpkg most, answered from the status file and
/// the files lists the helper writes in dpkg's own format. Nothing here
/// changes anything; a request that would is refused. A subcommand, not a
/// `dpkg` in the package: that would clash with the bootstrap's own while
/// one is installed (Documentation/CommandLine.md, "dpkg-query").
struct DpkgQuery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dpkg-query",
        abstract: "Answer dpkg-query's read-only questions: -W [-f=format], -s, -L, -l.",
        discussion: "Arguments are dpkg-query's own; irisin-cli reads them as dpkg-query does."
    )

    @Argument(parsing: .captureForPassthrough, help: "dpkg-query's arguments.")
    var arguments: [String] = []

    func run() throws {
        let context = try DpkgDatabase.context()
        throw ExitCode(try DpkgDatabase(context).query(arguments, as: "dpkg-query"))
    }
}

struct Dpkg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dpkg",
        abstract: "Answer dpkg's read-only questions: --compare-versions, --print-architecture, -s, -L, -l.",
        discussion: "Arguments are dpkg's own. Anything that would change the system is refused: install with irisin-cli install."
    )

    @Argument(parsing: .captureForPassthrough, help: "dpkg's arguments.")
    var arguments: [String] = []

    func run() throws {
        guard let first = arguments.first else {
            throw DpkgDatabase.usage("dpkg", "need an action option")
        }
        switch first {
        case "--compare-versions":
            guard arguments.count == 4 else {
                throw DpkgDatabase.usage("dpkg", "--compare-versions takes three arguments: <version> <relation> <version>")
            }
            guard let result = DpkgDatabase.compare(arguments[1], arguments[2], arguments[3]) else {
                throw DpkgDatabase.usage("dpkg", "unknown relation '\(arguments[2])'")
            }
            throw ExitCode(result ? 0 : 1)
        case "--print-architecture":
            let context = try DpkgDatabase.context()
            print(context.architecture)
        default:
            let context = try DpkgDatabase.context()
            throw ExitCode(try DpkgDatabase(context).query(arguments, as: "dpkg"))
        }
    }
}

struct DpkgDatabase {
    struct Record {
        let paragraph: String
        let fields: [String: String]

        var name: String { fields["package"] ?? "" }
        var architecture: String { fields["architecture"] ?? "" }
    }

    let context: Context
    let records: [Record]

    static func context() throws -> Context {
        do {
            return try Context.load()
        } catch let failure as CommandFailure {
            FileHandle.standardError.write(Data("irisin-cli: \(failure.description)\n".utf8))
            throw failure.exitCode
        }
    }

    static func usage(_ tool: String, _ message: String) -> ExitCode {
        FileHandle.standardError.write(Data("\(tool): error: \(message)\n".utf8))
        return ExitCode(2)
    }

    init(_ context: Context) throws {
        self.context = context
        let data = (try? Data(contentsOf: URL(fileURLWithPath: context.statusFile))) ?? Data()
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        records = text.components(separatedBy: "\n\n").compactMap { paragraph in
            let trimmed = paragraph.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty, let fields = try? DebianControl.parse(trimmed) else { return nil }
            return Record(paragraph: trimmed, fields: fields)
        }
    }

    /// The status of the action `arguments` name, as dpkg-query exits.
    func query(_ arguments: [String], as tool: String) throws -> Int32 {
        var action: String?
        var format = "${binary:Package}\t${Version}\n"
        var names: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-W", "--show", "-s", "--status", "-L", "--listfiles", "-l", "--list":
                action = argument
            case "-f":
                index += 1
                guard index < arguments.count else { throw Self.usage(tool, "-f needs a format") }
                format = arguments[index]
            case let option where option.hasPrefix("-f="):
                format = String(option.dropFirst(3))
            case let option where option.hasPrefix("--showformat="):
                format = String(option.dropFirst("--showformat=".count))
            case let option where option.hasPrefix("--admindir=") || option.hasPrefix("--root="):
                break
            case let option where option.hasPrefix("-"):
                throw Self.usage(tool, "\(option) is not a question irisin-cli answers; it answers -W, -s, -L and -l")
            default:
                names.append(argument)
            }
            index += 1
        }
        switch action {
        case "-W", "--show": return show(names, format: format, tool: tool)
        case "-s", "--status": return status(names, tool: tool)
        case "-L", "--listfiles": return listFiles(names, tool: tool)
        case "-l", "--list": return list(names, tool: tool)
        default: throw Self.usage(tool, "need an action option")
        }
    }

    // MARK: - Actions

    private func show(_ patterns: [String], format: String, tool: String) -> Int32 {
        let matched = matching(patterns, tool: tool, includeNotInstalled: !patterns.isEmpty)
        for record in matched.records {
            FileHandle.standardOutput.write(Data(render(format, record).utf8))
        }
        return matched.missed ? 1 : 0
    }

    private func status(_ names: [String], tool: String) -> Int32 {
        var missed = false
        for name in names {
            guard let record = record(named: name) else {
                FileHandle.standardError.write(Data("\(tool): package '\(name)' is not installed and no information is available\n".utf8))
                missed = true
                continue
            }
            print(record.paragraph + "\n")
        }
        return missed ? 1 : 0
    }

    private func listFiles(_ names: [String], tool: String) -> Int32 {
        var missed = false
        for name in names {
            let info = context.path("/Library/dpkg/info")
            let base = name.split(separator: ":").first.map(String.init) ?? name
            let candidates = [base] + (record(named: name).map { ["\(base):\($0.architecture)"] } ?? [])
            guard let list = candidates.lazy.compactMap({ try? String(contentsOfFile: "\(info)/\($0).list", encoding: .utf8) }).first else {
                FileHandle.standardError.write(Data("\(tool): package '\(name)' is not installed\n".utf8))
                missed = true
                continue
            }
            for line in list.split(separator: "\n") where !line.isEmpty {
                print(line)
            }
        }
        return missed ? 1 : 0
    }

    private func list(_ patterns: [String], tool: String) -> Int32 {
        let matched = matching(patterns, tool: tool, includeNotInstalled: false)
        print("||/ Name                           Version                Architecture   Description")
        for record in matched.records {
            let summary = (record.fields["description"] ?? "").split(separator: "\n").first.map(String.init) ?? ""
            print(String(format: "%@ %-30@ %-22@ %-14@ %@",
                         abbreviation(record) as NSString, record.name as NSString,
                         (record.fields["version"] ?? "") as NSString, record.architecture as NSString, summary as NSString))
        }
        return matched.missed ? 1 : 0
    }

    // MARK: - Records

    private func record(named name: String) -> Record? {
        let base = name.split(separator: ":").first.map(String.init)?.lowercased() ?? name.lowercased()
        return records.first { $0.name == base }
    }

    /// Every record a pattern matches (fnmatch, as dpkg-query's globs); the
    /// patterns that matched nothing are said on standard error.
    private func matching(_ patterns: [String], tool: String, includeNotInstalled: Bool) -> (records: [Record], missed: Bool) {
        let present = records.filter { includeNotInstalled || !($0.fields["status"] ?? "").hasSuffix("not-installed") }
        guard !patterns.isEmpty else { return (present.sorted { $0.name < $1.name }, false) }
        var found: [Record] = []
        var missed = false
        for pattern in patterns {
            let base = pattern.split(separator: ":").first.map(String.init) ?? pattern
            let hits = present.filter { fnmatch(base, $0.name, 0) == 0 }
            if hits.isEmpty {
                FileHandle.standardError.write(Data("\(tool): no packages found matching \(pattern)\n".utf8))
                missed = true
            }
            found += hits.filter { hit in !found.contains { $0.name == hit.name } }
        }
        return (found, missed)
    }

    /// `ii ` and friends: what was wanted, where it stands, and the error flag.
    private func abbreviation(_ record: Record) -> String {
        let words = (record.fields["status"] ?? "unknown ok not-installed").split(separator: " ").map(String.init)
        let want = ["unknown": "u", "install": "i", "hold": "h", "deinstall": "r", "purge": "p"][words.first ?? ""] ?? "u"
        let state = ["not-installed": "n", "config-files": "c", "half-installed": "H", "unpacked": "U",
                     "half-configured": "F", "triggers-awaited": "W", "triggers-pending": "t", "installed": "i"][words.last ?? ""] ?? "n"
        let flag = words.count > 1 && words[1] == "reinstreq" ? "R" : " "
        return want + state + flag
    }

    /// dpkg-query's format: `${Field}`, `${Field;width}` (negative pads on
    /// the right), and the backslash escapes `\n`, `\t` and `\\`.
    private func render(_ format: String, _ record: Record) -> String {
        var result = ""
        let characters = Array(format)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                switch characters[index + 1] {
                case "n": result += "\n"
                case "t": result += "\t"
                case "\\": result += "\\"
                default: result.append(characters[index + 1])
                }
                index += 2
                continue
            }
            if character == "$", index + 1 < characters.count, characters[index + 1] == "{",
               let close = characters[(index + 2)...].firstIndex(of: "}")
            {
                let reference = String(characters[(index + 2) ..< close])
                let parts = reference.split(separator: ";", maxSplits: 1).map(String.init)
                var value = field(parts.first ?? "", of: record)
                if parts.count == 2, let width = Int(parts[1]) {
                    let padding = String(repeating: " ", count: max(0, abs(width) - value.count))
                    value = width < 0 ? value + padding : padding + value
                }
                result += value
                index = close + 1
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    private func field(_ name: String, of record: Record) -> String {
        let words = (record.fields["status"] ?? "").split(separator: " ").map(String.init)
        switch name.lowercased() {
        case "binary:package", "package": return record.name
        case "db:status-abbrev": return abbreviation(record)
        case "db:status-want": return words.first ?? ""
        case "db:status-status": return words.last ?? ""
        case "db:status-eflag": return words.count > 1 ? words[1] : ""
        case "binary:summary": return (record.fields["description"] ?? "").split(separator: "\n").first.map(String.init) ?? ""
        default: return record.fields[name.lowercased()] ?? ""
        }
    }

    // MARK: - Versions

    /// dpkg's `--compare-versions`; nil for a relation it does not know.
    /// An empty version is earlier than any other, or later with the `-nl`
    /// relations.
    static func compare(_ a: String, _ relation: String, _ b: String) -> Bool? {
        let laterWhenEmpty = relation.hasSuffix("-nl")
        let order: Int
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): order = 0
        case (true, false): order = laterWhenEmpty ? 1 : -1
        case (false, true): order = laterWhenEmpty ? -1 : 1
        case (false, false): order = DebianVersion.compare(a, b)
        }
        switch relation {
        case "lt", "lt-nl", "<<": return order < 0
        case "le", "le-nl", "<=", "<": return order <= 0
        case "eq", "=": return order == 0
        case "ne": return order != 0
        case "ge", "ge-nl", ">=", ">": return order >= 0
        case "gt", "gt-nl", ">>": return order > 0
        default: return nil
        }
    }
}
