//
//  MarkdownParser.swift
//  FlowMarkdownView
//
//  Created by 秋星桥 on 2025/1/2.
//

import cmark_gfm
import cmark_gfm_extensions
import Foundation

public final class MarkdownParser: Sendable {
    public init() {}

    func withParser<T>(_ block: (UnsafeMutablePointer<cmark_parser>) -> T) -> T {
        let parser = cmark_parser_new(CMARK_OPT_DEFAULT)!
        cmark_gfm_core_extensions_ensure_registered()
        let extensionNames = [
            "autolink",
            "strikethrough",
            "tagfilter",
            "tasklist",
            "table",
        ]
        for extensionName in extensionNames {
            guard let syntaxExtension = cmark_find_syntax_extension(extensionName) else {
                assertionFailure()
                continue
            }
            cmark_parser_attach_syntax_extension(parser, syntaxExtension)
        }
        defer { cmark_parser_free(parser) }
        return block(parser)
    }

    public struct ParseResult: Sendable {
        public let document: [MarkdownBlockNode]
    }

    public func parse(_ markdown: String) -> ParseResult {
        let nodes = withParser { parser in
            markdown.withCString { str in
                cmark_parser_feed(parser, str, markdown.utf8.count)
                return cmark_parser_finish(parser)
            }
        }
        defer {
            if let nodes {
                cmark_node_free(nodes)
            }
        }
        return .init(document: dumpBlocks(root: nodes))
    }

    public struct RootBlockRange: Sendable {
        public let type: MarkdownNodeType
        public let startIndex: String.Index
        public let endIndex: String.Index
    }

    public func parseBlockRange(_ markdown: String) -> [RootBlockRange] {
        var ranges = [RootBlockRange]()

        let root = withParser { parser in
            markdown.withCString { str in
                cmark_parser_feed(parser, str, markdown.utf8.count)
                return cmark_parser_finish(parser)
            }
        }
        guard let root else {
            assertionFailure()
            return ranges
        }
        defer { cmark_node_free(root) }

        assert(root.pointee.type == CMARK_NODE_DOCUMENT.rawValue)
        for block in root.children {
            let node = block.pointee

            let startLine = Int(node.start_line)
            let startColumn = Int(node.start_column)
            let endLine = Int(node.end_line)
            let endColumn = Int(node.end_column)

            guard let startIndex = getIndex(forLine: startLine, column: startColumn, in: markdown),
                  let endIndex = getIndex(forLine: endLine, column: endColumn, columnIsInclusiveEnd: true, in: markdown)
            else {
                assertionFailure()
                continue
            }
            let content = RootBlockRange(type: block.nodeType, startIndex: startIndex, endIndex: endIndex)
            ranges.append(content)
        }
        return ranges
    }
}

private func getIndex(forLine targetLine: Int, column targetColumn: Int, columnIsInclusiveEnd: Bool = false, in text: String) -> String.Index? {
    var currentLine = 1
    var lineStartIndex = text.startIndex

    while currentLine < targetLine {
        guard let newlineIndex = text[lineStartIndex...].firstIndex(of: "\n") else {
            return nil
        }
        lineStartIndex = text.index(after: newlineIndex)
        currentLine += 1
    }

    // cmark 使用 1-based 列号，需要减1转换为 0-based
    let targetOffset = columnIsInclusiveEnd ? targetColumn : targetColumn - 1

    let lineEndIndex: String.Index = if let newlineIndex = text[lineStartIndex...].firstIndex(of: "\n") {
        newlineIndex
    } else {
        text.endIndex
    }

    guard let lineStartUTF8 = lineStartIndex.samePosition(in: text.utf8),
          let lineEndUTF8 = lineEndIndex.samePosition(in: text.utf8)
    else {
        return lineEndIndex
    }

    let maxOffset = text.utf8.distance(from: lineStartUTF8, to: lineEndUTF8)

    if targetOffset > maxOffset {
        return lineEndIndex
    }

    if targetOffset < 0 {
        return lineStartIndex
    }

    let utf8Index = text.utf8.index(lineStartUTF8, offsetBy: targetOffset)
    return utf8Index.samePosition(in: text) ?? lineEndIndex
}
