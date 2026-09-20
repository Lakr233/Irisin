import Foundation

/// A program's entitlements as `ldid -M -S<file>` treats them: read from
/// the XML the old signature carries, merged with roothide's, and written
/// back as the XML and DER blobs of the new signature.
///
/// ldid reads and writes that XML with libplist, whose dictionary keeps
/// its keys in the order they arrived and replaces a value where it
/// stands, and whose reader keeps every byte of a string as it was:
/// Foundation sorts the keys, and `XMLParser` folds line ends and reads
/// entities its own way. So both directions are written here, the writer
/// held to Foundation in everything but the order (`xml()`), as is the
/// DER, which is ldid's own, and held to the device's ldid by the fixtures.
struct LdidEntitlements: Equatable {
    enum Value: Equatable {
        case boolean(Bool)
        /// Positive: ldid's DER cannot spell zero, and libplist writes a
        /// negative one differently.
        case integer(Int64)
        case string(String)
        case data(Data)
        case array([Value])
        case dictionary([Entry])
    }

    struct Entry: Equatable {
        var key: String
        var value: Value
    }

    private(set) var entries: [Entry]

    /// What roothide's patcher merges into every program it signs
    /// (`roothide.entitlements`), in that file's order.
    static let roothide = [
        "platform-application",
        "com.apple.private.security.no-sandbox",
        "com.apple.private.security.storage.AppBundles",
        "com.apple.private.security.storage.AppDataContainers",
    ]

    /// `xml` is what the old signature's entitlements slot holds; empty is
    /// no entitlements. A binary plist, a date, a real, anything else ldid
    /// would not carry into DER, and XML libplist would read its own way
    /// are refused.
    init(xml: Data) throws {
        guard !xml.isEmpty else {
            entries = []
            return
        }
        var reader = Reader(xml)
        entries = try reader.read()
    }

    /// Each key set to true, as `plist_dict_set_item` sets it.
    mutating func merge(_ keys: [String]) {
        for key in keys {
            Self.set(key, .boolean(true), in: &entries)
        }
    }

    /// The executable segment flags ldid derives: the main binary's for a
    /// program's slice, and one for each entitlement that asks. ldid gives
    /// can-execute-cdhash the bit of can-load-cdhash (0x100), and so does
    /// this.
    func executableSegmentFlags(mainBinary: Bool) -> UInt64 {
        let flags: [(key: String, bit: UInt64)] = [
            ("get-task-allow", 0x10), ("run-unsigned-code", 0x10), ("com.apple.private.cs.debugger", 0x20),
            ("dynamic-codesigning", 0x40), ("com.apple.private.skip-library-validation", 0x80),
            ("com.apple.private.amfi.can-load-cdhash", 0x100), ("com.apple.private.amfi.can-execute-cdhash", 0x100),
        ]
        return flags.reduce(mainBinary ? 1 : 0) { result, flag in
            entries.first { $0.key.utf8.elementsEqual(flag.key.utf8) }?.value == .boolean(true) ? result | flag.bit : result
        }
    }

    /// As libplist's `plist_to_xml` writes it, which is Foundation's XML to
    /// the byte but in one thing: libplist keeps a dictionary's keys in the
    /// order they arrived, and Foundation sorts them, so Foundation cannot
    /// write it. The writer here is held to Foundation on every call: the
    /// same list with its keys in Foundation's order must come out as
    /// `PropertyListSerialization` writes it, so every byte but the order
    /// is Foundation's, and a list the two would write differently is
    /// refused rather than signed.
    func xml() throws -> Data {
        let foundation = try? PropertyListSerialization.data(fromPropertyList: Self.foundation(.dictionary(entries)), format: .xml, options: 0)
        guard Self.document(.dictionary(entries), sorted: true) == foundation else { throw MachOFailure.unsupportedEntitlements }
        return Self.document(.dictionary(entries), sorted: false)
    }

    /// As ldid writes it: the dictionary a SET whose members are sorted as
    /// encoded byte strings, not by key, and no wrapper around it.
    var der: Data {
        Data(Self.der(.dictionary(entries)))
    }

    /// Replaces the value where the key stands, or appends the key.
    /// libplist compares keys as bytes; Swift's `==` would equate two
    /// spellings of one character.
    private static func set(_ key: String, _ value: Value, in entries: inout [Entry]) {
        if let index = entries.firstIndex(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
            entries[index].value = value
        } else {
            entries.append(Entry(key: key, value: value))
        }
    }

    /// Tabs, only `<`, `>` and `&` escaped, an empty container closed on
    /// itself; `sorted` puts keys in the UTF-16 order Foundation writes.
    private static func document(_ value: Value, sorted: Bool) -> Data {
        var out = Array("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """.utf8)
        write(value, depth: 0, sorted: sorted, into: &out)
        out += "</plist>\n".utf8
        return Data(out)
    }

    /// The list as Foundation holds it. The keys stay `NSString`s, which
    /// compare as UTF-16, so two spellings of one character stay two keys.
    private static func foundation(_ value: Value) -> Any {
        switch value {
        case let .boolean(value): NSNumber(value: value)
        case let .integer(value): NSNumber(value: value)
        case let .string(value): NSString(string: value)
        case let .data(value): NSData(data: value)
        case let .array(values): NSArray(array: values.map(foundation))
        case let .dictionary(entries):
            NSDictionary(objects: entries.map { foundation($0.value) }, forKeys: entries.map { NSString(string: $0.key) })
        }
    }

    private static func write(_ value: Value, depth: Int, sorted: Bool, into out: inout [UInt8]) {
        let indent = [UInt8](repeating: 0x09, count: depth)
        out += indent
        func text(_ tag: String, _ content: String) {
            out += "<\(tag)>".utf8
            for byte in content.utf8 {
                switch byte {
                case UInt8(ascii: "<"): out += "&lt;".utf8
                case UInt8(ascii: ">"): out += "&gt;".utf8
                case UInt8(ascii: "&"): out += "&amp;".utf8
                default: out.append(byte)
                }
            }
            out += "</\(tag)>\n".utf8
        }
        switch value {
        case let .boolean(value):
            out += (value ? "<true/>\n" : "<false/>\n").utf8
        case let .integer(value):
            out += "<integer>\(value)</integer>\n".utf8
        case let .string(value):
            text("string", value)
        case let .data(value):
            out += "<data>\n".utf8
            // lines no wider than 76 columns counting a tab as 8, whole
            // groups of three bytes each, at most eight tabs in
            let lineIndent = [UInt8](repeating: 0x09, count: min(depth, 8))
            let perLine = (76 - lineIndent.count * 8) / 4 * 3
            for start in stride(from: 0, to: value.count, by: perLine) {
                let line = value.dropFirst(start).prefix(perLine)
                out += lineIndent + Data(line).base64EncodedString().utf8 + [0x0A]
            }
            out += indent + "</data>\n".utf8
        case let .array(values):
            guard !values.isEmpty else {
                out += "<array/>\n".utf8
                return
            }
            out += "<array>\n".utf8
            for value in values {
                write(value, depth: depth + 1, sorted: sorted, into: &out)
            }
            out += indent + "</array>\n".utf8
        case let .dictionary(entries):
            guard !entries.isEmpty else {
                out += "<dict/>\n".utf8
                return
            }
            out += "<dict>\n".utf8
            for entry in sorted ? entries.sorted(by: { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }) : entries {
                out += indent + [0x09]
                text("key", entry.key)
                write(entry.value, depth: depth + 1, sorted: sorted, into: &out)
            }
            out += indent + "</dict>\n".utf8
        }
    }

    private static func der(_ value: Value) -> [UInt8] {
        switch value {
        case let .boolean(value):
            [0x01, 0x01, value ? 1 : 0]
        case let .integer(value):
            tagged(0x02, bigEndian(UInt64(value)))
        case let .string(value):
            tagged(0x0C, Array(value.utf8))
        case let .data(value):
            tagged(0x04, Array(value))
        case let .array(values):
            tagged(0x30, values.flatMap(der))
        case let .dictionary(entries):
            tagged(
                0x31,
                entries.map { tagged(0x30, tagged(0x0C, Array($0.key.utf8)) + der($0.value)) }
                    .sorted { $0.lexicographicallyPrecedes($1) }
                    .flatMap(\.self)
            )
        }
    }

    private static func tagged(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        guard content.count >= 0x80 else { return [tag, UInt8(content.count)] + content }
        let length = bigEndian(UInt64(content.count))
        return [tag, 0x80 | UInt8(length.count)] + length + content
    }

    /// The fewest bytes that hold `value`, most significant first.
    private static func bigEndian(_ value: UInt64) -> [UInt8] {
        Array(withUnsafeBytes(of: value.bigEndian, Array.init).drop { $0 == 0 })
    }
}

extension LdidEntitlements {
    /// The XML read as libplist's `plist_from_xml` reads it, for what an
    /// entitlements file holds. What libplist reads its own way is refused
    /// rather than guessed at: an entity it matches by the first letters, text
    /// split by a comment or CDATA, a second key in a row, a key left without a
    /// value, a byte that ends its C strings early, and elements after an empty
    /// root, which it reads into that root. The rest it reads as written here:
    /// every byte of a string kept (a CR too), the document read up to the
    /// end of its root and no further.
    private struct Reader {
        /// A container being read.
        private struct Frame {
            let isDictionary: Bool
            /// The key read for the next value of a dictionary.
            var key: String?
            var entries: [LdidEntitlements.Entry] = []
            /// Where each key of `entries` stands, by its bytes.
            var index: [[UInt8]: Int] = [:]
            var values: [LdidEntitlements.Value] = []

            /// As `plist_dict_set_item`: the value replaced where the key stands.
            mutating func set(_ key: String, _ value: LdidEntitlements.Value) {
                if let at = index[Array(key.utf8)] {
                    entries[at].value = value
                } else {
                    index[Array(key.utf8)] = entries.count
                    entries.append(LdidEntitlements.Entry(key: key, value: value))
                }
            }
        }

        /// Deeper than any entitlements go, and shallow enough for the writers'
        /// recursion on a small stack.
        private static let depth = 64

        private let bytes: [UInt8]
        private var at = 0
        private var stack: [Frame] = []
        /// An empty root, which libplist reads past.
        private var root: [LdidEntitlements.Entry]?

        init(_ data: Data) {
            bytes = Array(data)
        }

        /// The root dictionary's entries. Anything refused throws
        /// `MachOFailure.unsupportedEntitlements`.
        mutating func read() throws -> [LdidEntitlements.Entry] {
            let entries = try document()
            // libplist turns a lone CF$UID into a UID, which ldid refuses
            if entries.count == 1, entries[0].key.utf8.elementsEqual("CF$UID".utf8), case .integer = entries[0].value {
                throw MachOFailure.unsupportedEntitlements
            }
            return entries
        }

        private mutating func document() throws -> [LdidEntitlements.Entry] {
            var inPlist = false
            while true {
                skipSpace()
                guard at < bytes.count else { break }
                try expect("<")
                if try skipMarkup() {
                    continue
                }
                let (name, empty) = try tag()
                switch name {
                case "plist":
                    guard !empty, !inPlist, stack.isEmpty, root == nil else { throw MachOFailure.unsupportedEntitlements }
                    inPlist = true
                case "/plist":
                    // reached only past an empty root: libplist stops at the end
                    // of any other
                    guard !empty, inPlist, root != nil else { throw MachOFailure.unsupportedEntitlements }
                    inPlist = false
                case _ where root != nil:
                    throw MachOFailure.unsupportedEntitlements
                case "dict", "array":
                    if empty {
                        try add(name == "dict" ? .dictionary([]) : .array([]))
                    } else {
                        try open(dictionary: name == "dict")
                    }
                case "/dict", "/array":
                    guard !empty, let frame = stack.popLast(), frame.isDictionary == (name == "/dict"), frame.key == nil else {
                        throw MachOFailure.unsupportedEntitlements
                    }
                    guard !stack.isEmpty else {
                        // the root, a dictionary (`open`): libplist reads no further
                        return frame.entries
                    }
                    try add(frame.isDictionary ? .dictionary(frame.entries) : .array(frame.values))
                case "key":
                    guard !empty, let top = stack.indices.last, stack[top].isDictionary, stack[top].key == nil else {
                        throw MachOFailure.unsupportedEntitlements
                    }
                    let key = try Self.string(text(closing: name, skippingSpace: false))
                    stack[top].key = key
                case "string":
                    let string = try empty ? "" : Self.string(text(closing: name, skippingSpace: false))
                    try add(.string(string))
                case "integer":
                    // libplist reads it with strtoull in any base, and ldid's DER
                    // cannot spell zero or a negative one: plain decimal only
                    guard !empty else { throw MachOFailure.unsupportedEntitlements }
                    let text = try text(closing: name, skippingSpace: true)
                    let digits = text.prefix { (0x30 ... 0x39).contains($0) }
                    guard digits.first.map({ $0 != 0x30 }) == true, text.dropFirst(digits.count).allSatisfy(Self.isSpace),
                          let value = Int64(String(decoding: digits, as: UTF8.self))
                    else { throw MachOFailure.unsupportedEntitlements }
                    try add(.integer(value))
                case "data":
                    // libplist's decoder skips what it does not know; base64 that
                    // reads back the same is what the two agree on
                    let encoded = try empty ? "" : String(decoding: text(closing: name, skippingSpace: true).filter { !Self.isSpace($0) }, as: UTF8.self)
                    guard let value = Data(base64Encoded: encoded), value.base64EncodedString() == encoded else { throw MachOFailure.unsupportedEntitlements }
                    try add(.data(value))
                case "true", "false":
                    // libplist reads past any text in them; there is none here
                    guard try empty || text(closing: name, skippingSpace: true).isEmpty else { throw MachOFailure.unsupportedEntitlements }
                    try add(.boolean(name == "true"))
                default:
                    // a real, a date and anything that is no plist element
                    throw MachOFailure.unsupportedEntitlements
                }
            }
            // the end of the document, fine only after an empty root
            guard stack.isEmpty, !inPlist, let root else { throw MachOFailure.unsupportedEntitlements }
            return root
        }

        private mutating func open(dictionary: Bool) throws {
            // a value in a dictionary needs its key, and the root is a dictionary
            guard stack.count < Self.depth, stack.last.map({ !$0.isDictionary || $0.key != nil }) ?? dictionary else {
                throw MachOFailure.unsupportedEntitlements
            }
            stack.append(Frame(isDictionary: dictionary))
        }

        private mutating func add(_ value: LdidEntitlements.Value) throws {
            guard let top = stack.indices.last else {
                // a root that is not a container ends libplist's read, and one
                // that is empty does not; only an empty dictionary is a dictionary
                guard value == .dictionary([]) else { throw MachOFailure.unsupportedEntitlements }
                root = []
                return
            }
            if stack[top].isDictionary {
                guard let key = stack[top].key else { throw MachOFailure.unsupportedEntitlements }
                stack[top].key = nil
                stack[top].set(key, value)
            } else {
                stack[top].values.append(value)
            }
        }

        /// A tag's name, read past its `<` as libplist reads it, and whether it
        /// closes itself. Only `<plist>` may carry attributes, their
        /// double-quoted values skipped whole as libplist skips them.
        private mutating func tag() throws -> (name: String, empty: Bool) {
            let start = at
            while at < bytes.count, !" \t\r\n<>".utf8.contains(bytes[at]) {
                at += 1
            }
            var name = bytes[start ..< at]
            if at < bytes.count, bytes[at] != UInt8(ascii: ">") {
                guard name.elementsEqual("plist".utf8) else { throw MachOFailure.unsupportedEntitlements }
                while at < bytes.count, bytes[at] != UInt8(ascii: "<"), bytes[at] != UInt8(ascii: ">") {
                    if bytes[at] == UInt8(ascii: "\"") {
                        at = try closingQuote()
                    }
                    at += 1
                }
            }
            try expect(">")
            let empty = bytes[at - 2] == UInt8(ascii: "/")
            if empty, name.last == UInt8(ascii: "/") {
                name = name.dropLast()
            }
            return (String(decoding: name, as: UTF8.self), empty)
        }

        /// An element's text up to its closing tag, which must be what follows
        /// it: libplist splits a text at a comment or CDATA and joins the parts
        /// its own way.
        private mutating func text(closing name: String, skippingSpace: Bool) throws -> ArraySlice<UInt8> {
            if skippingSpace {
                skipSpace()
            }
            guard let end = bytes[at...].firstIndex(of: UInt8(ascii: "<")) else { throw MachOFailure.unsupportedEntitlements }
            let text = bytes[at ..< end]
            at = end + 1
            try expect("/" + name)
            skipSpace()
            try expect(">")
            return text
        }

        /// Skips what libplist skips between elements, past the `<`: `<?…?>`, a
        /// comment, and a `<!DOCTYPE>` without an internal subset.
        private mutating func skipMarkup() throws -> Bool {
            if bytes[at...].starts(with: "?".utf8) {
                try skip(past: "?>", quotes: true)
            } else if bytes[at...].starts(with: "!--".utf8) {
                at += 3
                try skip(past: "-->", quotes: false)
            } else if bytes[at...].starts(with: "!DOCTYPE".utf8) {
                at += 8
                while true {
                    guard at < bytes.count, bytes[at] != UInt8(ascii: "[") else { throw MachOFailure.unsupportedEntitlements }
                    if bytes[at] == UInt8(ascii: "\"") {
                        at = try closingQuote()
                    } else if bytes[at] == UInt8(ascii: ">") {
                        at += 1
                        break
                    }
                    at += 1
                }
            } else if bytes[at...].starts(with: "!".utf8) {
                throw MachOFailure.unsupportedEntitlements
            } else {
                return false
            }
            return true
        }

        private mutating func skip(past terminator: String, quotes: Bool) throws {
            while at < bytes.count {
                if bytes[at...].starts(with: terminator.utf8) {
                    at += terminator.utf8.count
                    return
                }
                if quotes, bytes[at] == UInt8(ascii: "\"") {
                    at = try closingQuote()
                }
                at += 1
            }
            throw MachOFailure.unsupportedEntitlements
        }

        /// Where the double quote opened at `at` closes.
        private func closingQuote() throws -> Int {
            guard let close = bytes[(at + 1)...].firstIndex(of: UInt8(ascii: "\"")) else { throw MachOFailure.unsupportedEntitlements }
            return close
        }

        private mutating func expect(_ literal: String) throws {
            guard bytes[at...].starts(with: literal.utf8) else { throw MachOFailure.unsupportedEntitlements }
            at += literal.utf8.count
        }

        private mutating func skipSpace() {
            while at < bytes.count, Self.isSpace(bytes[at]) {
                at += 1
            }
        }

        /// What libplist skips as space: these four and nothing else.
        private static func isSpace(_ byte: UInt8) -> Bool {
            [0x20, 0x09, 0x0A, 0x0D].contains(byte)
        }

        /// A key's or a string's text: the five named entities and a numeric
        /// reference of up to eight characters, as libplist takes them, and
        /// UTF-8 with no NUL, which would end libplist's string.
        private static func string(_ text: ArraySlice<UInt8>) throws -> String {
            var bytes: [UInt8] = []
            var at = text.startIndex
            while at < text.endIndex {
                guard text[at] == UInt8(ascii: "&") else {
                    bytes.append(text[at])
                    at += 1
                    continue
                }
                guard let end = text[at...].firstIndex(of: UInt8(ascii: ";")) else { throw MachOFailure.unsupportedEntitlements }
                let name = text[(at + 1) ..< end]
                switch String(decoding: name, as: UTF8.self) {
                case "amp": bytes.append(UInt8(ascii: "&"))
                case "lt": bytes.append(UInt8(ascii: "<"))
                case "gt": bytes.append(UInt8(ascii: ">"))
                case "quot": bytes.append(UInt8(ascii: "\""))
                case "apos": bytes.append(UInt8(ascii: "'"))
                default:
                    let hex = name.dropFirst().first.map { $0 | 0x20 == UInt8(ascii: "x") } == true
                    let digits = name.dropFirst(hex ? 2 : 1)
                    guard name.first == UInt8(ascii: "#"), name.count <= 8, !digits.isEmpty,
                          digits.allSatisfy({ (0x30 ... 0x39).contains($0) || hex && (0x61 ... 0x66).contains($0 | 0x20) }),
                          let value = UInt32(String(decoding: digits, as: UTF8.self), radix: hex ? 16 : 10), value != 0,
                          let scalar = Unicode.Scalar(value)
                    else { throw MachOFailure.unsupportedEntitlements }
                    bytes += Array(String(scalar).utf8)
                }
                at = end + 1
            }
            let string = String(decoding: bytes, as: UTF8.self)
            guard !bytes.contains(0), string.utf8.elementsEqual(bytes) else { throw MachOFailure.unsupportedEntitlements }
            return string
        }
    }
}
