import Foundation

/// RFC822-style Debian control paragraphs. A malformed/duplicate field must
/// not silently replace or discard a dependency constraint.
public enum DebianControl {
    public static func parse(_ paragraph: String, preservingLinesFor: Set<String> = []) throws -> [String: String] {
        var fields: [String: String] = [:]
        var previous: String?
        for line in paragraph.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard !line.utf8.contains(0) else { throw CocoaError(.fileReadCorruptFile) }
            if line.first == " " || line.first == "\t" {
                guard let previous else { throw CocoaError(.fileReadCorruptFile) }
                let preserve = preservingLinesFor.contains(previous)
                let continuation = preserve ? String(line.dropFirst()) : line.trimmingCharacters(in: .whitespaces)
                fields[previous, default: ""] += (preserve ? "\n" : " ") + continuation
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { throw CocoaError(.fileReadCorruptFile) }
            let key = line[..<separator].lowercased()
            // dpkg takes any printable field name up to the colon: an old
            // status file may still say `Package_Revision`
            guard !key.isEmpty,
                  key.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 58 }),
                  fields[key] == nil
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            fields[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            previous = key
        }
        guard !fields.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return fields
    }
}
