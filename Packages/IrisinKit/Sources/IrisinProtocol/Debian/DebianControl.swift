import Foundation

/// RFC822-style Debian control paragraphs. A malformed/duplicate field must
/// not silently replace or discard a dependency constraint.
public enum DebianControl {
    /// The paragraph's field names as it spells them, in its order. `parse`
    /// lowercases them to match as dpkg does; dpkg writes a field it does
    /// not know back as it read it, and this is what that takes.
    public static func fieldNames(_ paragraph: String) -> [String] {
        paragraph.utf8.split(separator: 0x0A).compactMap { line in
            guard let first = line.first, first != 0x20, first != 0x09, first != UInt8(ascii: "#"),
                  let separator = line.firstIndex(of: UInt8(ascii: ":"))
            else { return nil }
            return String(decoding: line[..<separator], as: UTF8.self)
        }
    }

    public static func parse(_ paragraph: String, preservingLinesFor: Set<String> = []) throws -> [String: String] {
        var fields: [String: String] = [:]
        var previous: String?
        // Lines end at a newline byte, and a carriage return before one goes
        // with it. `String` would take `\r\n` for a character that is not a
        // newline, and so a value could carry a line into the status file.
        let lines = paragraph.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map {
            String(decoding: $0.last == 0x0D ? $0.dropLast() : $0, as: UTF8.self)
        }
        for line in lines {
            if line.isEmpty || line.utf8.first == UInt8(ascii: "#") {
                continue
            }
            guard !line.utf8.contains(0) else { throw CocoaError(.fileReadCorruptFile) }
            if line.utf8.first == 0x20 || line.utf8.first == 0x09 {
                guard let previous else { throw CocoaError(.fileReadCorruptFile) }
                let preserve = preservingLinesFor.contains(previous)
                let continuation = preserve ? String(decoding: line.utf8.dropFirst(), as: UTF8.self) : line.trimmingCharacters(in: .whitespaces)
                fields[previous, default: ""] += (preserve ? "\n" : " ") + continuation
                continue
            }
            guard let separator = line.utf8.firstIndex(of: UInt8(ascii: ":")) else { throw CocoaError(.fileReadCorruptFile) }
            let key = String(decoding: line.utf8[..<separator], as: UTF8.self).lowercased()
            // dpkg takes any printable field name up to the colon: an old
            // status file may still say `Package_Revision`
            guard !key.isEmpty,
                  key.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 58 }),
                  fields[key] == nil
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            fields[key] = String(decoding: line.utf8[line.utf8.index(after: separator)...], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            previous = key
        }
        guard !fields.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return fields
    }
}
