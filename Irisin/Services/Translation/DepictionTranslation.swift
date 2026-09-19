//
//  DepictionTranslation.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/19.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// What in a depiction is prose, and the depiction again with that prose
/// replaced. The json is translated, never the views: the page is rendered
/// from the answer through the same renderer as the original.
///
/// Only what an author wrote as sentences is taken: markdown, labels,
/// headers, review titles and the names of tabs. Table rows (a version, a
/// name), buttons and html stay as they are. Markdown goes to the engine a line at a
/// time with its syntax held back, since an engine handed `[text](link)` or
/// a code span returns something that no longer parses.
nonisolated enum DepictionTranslation {
    /// Every piece of prose in `depiction`, once each, in reading order.
    static func texts(in depiction: [String: Any]) -> [String] {
        var seen = Set<String>()
        var texts: [String] = []
        _ = rewrite(depiction) { text in
            if seen.insert(text).inserted {
                texts.append(text)
            }
            return text
        }
        return texts
    }

    /// `depiction` with each piece of prose looked up in `translations`; a
    /// piece that is not there stays in its own language. `comparing` keeps
    /// what the author wrote and puts the translation under it: line under
    /// line in markdown, so a list stays a list with every item said twice.
    static func replacing(
        _ depiction: [String: Any],
        with translations: [String: String],
        comparing: Bool = false
    ) -> [String: Any] {
        rewrite(depiction, comparing: comparing) { translations[$0] ?? $0 }
    }

    // MARK: - The json

    private static func rewrite(
        _ view: [String: Any],
        comparing: Bool = false,
        _ transform: (String) -> String
    ) -> [String: Any] {
        var view = view
        for key in proseKeys(of: view) {
            guard let text = view[key] as? String else { continue }
            if key == "markdown" {
                view[key] = rewrite(markdown: text, comparing: comparing, transform)
            } else {
                let rewritten = rewrite(plain: text, transform)
                // a tab has room for one name: compared, it wears the translation
                view[key] = comparing && key != "tabname" && rewritten != text
                    ? text + "\n" + rewritten
                    : rewritten
            }
        }
        for (key, value) in view {
            switch value {
            case let child as [String: Any]:
                view[key] = rewrite(child, comparing: comparing, transform)
            case let children as [[String: Any]]:
                view[key] = children.map { rewrite($0, comparing: comparing, transform) }
            default:
                break
            }
        }
        return view
    }

    private static func proseKeys(of view: [String: Any]) -> [String] {
        // a tab is a stack like any other, told apart by having a name
        if view["tabname"] is String {
            return ["tabname"]
        }
        return switch view["class"] as? String {
        case "DepictionMarkdownView":
            (view["useRawFormat"] as? Bool) == true ? [] : ["markdown"]
        case "DepictionReviewView":
            ["title", "markdown"]
        case "DepictionLabelView":
            ["text"]
        case "DepictionHeaderView", "DepictionSubheaderView":
            ["title"]
        default:
            []
        }
    }

    // MARK: - The text

    private static func rewrite(plain text: String, _ transform: (String) -> String) -> String {
        let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prose.contains(where: \.isLetter) else { return text }
        return text.replacingOccurrences(of: prose, with: transform(prose))
    }

    /// Block markers a line opens with: heading, list item, quote.
    private static var lineMarker: Regex<Substring> {
        #/^(?:\s*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s?))+/#
    }

    /// What must come back exactly as written: code spans, a link's or an
    /// image's target, html tags and bare addresses.
    private static var heldBack: Regex<Substring> {
        #/`[^`]+`|!?\[|\]\([^)]*\)|\]|<[^>]+>|https?:\/\/\S+/#
    }

    /// Emphasis around a run of text. An engine moves the markers apart from
    /// their words, where they stop being emphasis and print as asterisks,
    /// so a translated line gives its emphasis up.
    private static var emphasis: Regex<(Substring, Substring, Substring)> {
        #/(\*\*\*|\*\*|\*|__|~~)(\S(?:.*?\S)?)\1/#
    }

    static func rewrite(markdown: String, comparing: Bool = false, _ transform: (String) -> String) -> String {
        var fence: Substring?
        return markdown.components(separatedBy: "\n").map { line in
            let opening = line.drop(while: \.isWhitespace).prefix(3)
            if opening == "```" || opening == "~~~" {
                if fence == nil {
                    fence = opening
                } else if fence == opening {
                    fence = nil
                }
                return line
            }
            guard fence == nil else { return line }

            let marker = line.prefixMatch(of: lineMarker).map { String($0.output) } ?? ""
            let rewritten = rewrite(line: line, after: marker, transform)
            // a line the engine left alone is not said twice; a paragraph's
            // translation is a paragraph of its own, a list item's the next item
            guard comparing, rewritten != rewrite(line: line, after: marker, { $0 }) else { return rewritten }
            return line + (marker.isEmpty ? "\n\n" : "\n") + rewritten
        }.joined(separator: "\n")
    }

    private static func rewrite(line: String, after marker: String, _ transform: (String) -> String) -> String {
        let body = String(line.dropFirst(marker.count))
        var rewritten = marker
        var cursor = body.startIndex
        for match in body.matches(of: heldBack) {
            rewritten += rewrite(plain: withoutEmphasis(body[cursor ..< match.range.lowerBound]), transform)
            rewritten += body[match.range]
            cursor = match.range.upperBound
        }
        return rewritten + rewrite(plain: withoutEmphasis(body[cursor...]), transform)
    }

    private static func withoutEmphasis(_ text: Substring) -> String {
        String(text.replacing(emphasis) { $0.output.2 })
    }
}
