//
//  TableExport.swift
//  MarkdownView
//

import Foundation
import Litext
import MarkdownParser

/// A table's rows as text to copy or save: a Markdown table, or CSV.
@MainActor
enum TableExport {
    /// A cell's text, with each attachment in it — the spacers around
    /// inline code, a rendered formula — replaced by its text form.
    static func plainText(_ cell: NSAttributedString) -> String {
        let result = NSMutableAttributedString(attributedString: cell)
        var replacements: [(NSRange, String)] = []
        result.enumerateAttribute(
            .litextAttachment,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, _ in
            guard let attachment = value as? TextLabel.Attachment else { return }
            replacements.append((range, attachment.attributedStringRepresentation().string))
        }
        for (range, text) in replacements.reversed() {
            result.replaceCharacters(in: range, with: text)
        }
        return result.string
    }

    /// A cell's inline nodes written back as Markdown: links keep their
    /// destinations, code its backticks, math its dollar signs, and text that
    /// would read as markup is escaped. Pipes and line breaks are left for
    /// `markdown(rows:alignments:)` to make safe inside a table row.
    nonisolated static func markdownSource(_ nodes: [MarkdownInlineNode]) -> String {
        var output = ""
        for node in nodes {
            output += markdownSource(node, after: output.last)
        }
        return output
    }

    /// `node` as Markdown, written after `previous`, the character before it.
    ///
    /// Emphasis takes `_` rather than `*` right after a `*`, so `*a*` then
    /// `*b*` do not run together into `*a**b*`, and `**_x_**` keeps its
    /// nesting.
    private nonisolated static func markdownSource(_ node: MarkdownInlineNode, after previous: Character?) -> String {
        let delimiter: Character = previous == "*" ? "_" : "*"
        func wrapped(_ marker: String, _ children: [MarkdownInlineNode]) -> String {
            var output = marker
            for child in children {
                output += markdownSource(child, after: output.last)
            }
            return output + marker
        }
        switch node {
        case let .text(text):
            return escapedText(text)
        case .softBreak:
            return " "
        case .lineBreak:
            return "\n"
        case let .code(code):
            // A fence one backtick longer than any run inside. Reading strips
            // one space from each end of code that has one at both, so pad
            // such code, and code that starts or ends with a backtick.
            let longestRun = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: longestRun + 1)
            let spaced = code.hasPrefix(" ") && code.hasSuffix(" ") && code.contains { $0 != " " }
            let padding = code.hasPrefix("`") || code.hasSuffix("`") || spaced ? " " : ""
            return fence + padding + code + padding + fence
        case let .html(html):
            return html
        case let .emphasis(children):
            return wrapped(String(delimiter), children)
        case let .strong(children):
            return wrapped(String(repeating: delimiter, count: 2), children)
        case let .strikethrough(children):
            return wrapped("~~", children)
        case let .link(destination, children):
            return String(wrapped("[", children).dropLast()) + "](" + linkDestination(destination) + ")"
        case let .image(source, children):
            return "!" + String(wrapped("[", children).dropLast()) + "](" + linkDestination(source) + ")"
        }
    }

    /// A link destination as written inside `( )`: bare when it reads back
    /// whole, or in angle brackets when it holds whitespace, an angle
    /// bracket or parentheses that do not pair.
    private nonisolated static func linkDestination(_ destination: String) -> String {
        var depth = 0
        var balanced = true
        for character in destination {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 {
                    balanced = false
                }
            }
        }
        let needsBrackets = !balanced || depth != 0 || destination.isEmpty
            || destination.contains { $0.isWhitespace || $0 == "<" || $0 == ">" }
        // A backslash before punctuation, or at the end, would escape what
        // follows it; doubled, it reads back as itself.
        let characters = Array(destination)
        var escaped = ""
        for (index, character) in characters.enumerated() {
            if character == "\\" {
                let next = characters.indices.contains(index + 1) ? characters[index + 1] : nil
                if next.map({ $0.isASCII && $0.isPunctuation || $0.isASCII && $0.isSymbol }) ?? true {
                    escaped.append("\\")
                }
            } else if needsBrackets, character == "<" || character == ">" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return needsBrackets ? "<" + escaped + ">" : escaped
    }

    /// Literal text escaped so it reads back as the same text: markup
    /// characters, an `&` that would start an entity, and a `<` that would
    /// start a tag.
    private nonisolated static func escapedText(_ text: String) -> String {
        let characters = Array(text)
        var escaped = ""
        for (index, character) in characters.enumerated() {
            let next = characters.dropFirst(index + 1)
            // A backslash or bracket is written as its character reference:
            // `\[` would read as the start of display math.
            switch character {
            case "\\":
                escaped += "&#92;"
                continue
            case "[":
                escaped += "&#91;"
                continue
            case "]":
                escaped += "&#93;"
                continue
            default:
                break
            }
            let needsEscape: Bool = switch character {
            case "*", "_", "`", "~":
                true
            case "&":
                // `&name;`, `&#123;` or `&#x1F;`.
                next.prefix { $0.isLetter || $0.isNumber || $0 == "#" }.count > 0
                    && next.dropFirst(next.prefix { $0.isLetter || $0.isNumber || $0 == "#" }.count).first == ";"
            case "<":
                next.first.map { $0.isLetter || "/!?".contains($0) } ?? false
            default:
                false
            }
            if needsEscape {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// `rows`, header first, as a Markdown table with `alignments` in its
    /// delimiter row.
    static func markdown(rows: [[String]], alignments: [RawTableColumnAlignment]) -> String {
        let columnCount = max(rows.map(\.count).max() ?? 0, alignments.count)
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: max(0, columnCount - cells.count))
            return "| " + padded.map(markdownCell).joined(separator: " | ") + " |"
        }
        let delimiters = (0 ..< columnCount).map { column -> String in
            switch alignments.indices.contains(column) ? alignments[column] : .none {
            case .left: ":---"
            case .center: ":---:"
            case .right: "---:"
            case .none: "---"
            }
        }
        var lines = rows.map(line)
        lines.insert("| " + delimiters.joined(separator: " | ") + " |", at: min(1, lines.count))
        return lines.joined(separator: "\n")
    }

    /// A cell's text as it reads inside a Markdown table row.
    private static func markdownCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// `rows` as CSV (RFC 4180): a field holding a comma, a quote or a line
    /// break is quoted, with its quotes doubled, and records end in CRLF.
    static func csv(rows: [[String]]) -> String {
        rows.map { row in
            row.map { field in
                guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else {
                    return field
                }
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + (rows.isEmpty ? "" : "\r\n")
    }

    /// CSV encoded as UTF-8 behind a byte order mark, which spreadsheet apps
    /// read to tell UTF-8 from a legacy encoding.
    static func csvData(rows: [[String]]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(csv(rows: rows).utf8)
    }
}
