//
//  TableSort.swift
//  MarkdownView
//

import Foundation
import Litext

/// Which column the full table is sorted by, and which way.
struct TableSort: Equatable {
    enum Direction: Equatable {
        case ascending
        case descending
    }

    let column: Int
    let direction: Direction

    /// The sort after tapping `column`'s header while `current` is applied:
    /// ascending, then descending, then back to source order.
    static func next(afterTapping column: Int, current: TableSort?) -> TableSort? {
        guard let current, current.column == column else {
            return .init(column: column, direction: .ascending)
        }
        switch current.direction {
        case .ascending:
            return .init(column: column, direction: .descending)
        case .descending:
            return nil
        }
    }

    /// The order to show `rows` in, as indices into `rows`.
    ///
    /// Rows move whole — the result is a permutation of `rows.indices` — so a
    /// sort can never put one row's cell beside another row's. Rows that
    /// compare equal keep their source order in either direction, and rows
    /// whose cell is empty stay last in either direction.
    @MainActor
    func order(of rows: [[String]]) -> [Int] {
        let keys = rows.map { SortKey($0.indices.contains(column) ? $0[column] : "") }
        return rows.indices.sorted { lhs, rhs in
            switch keys[lhs].compare(to: keys[rhs], direction: direction) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs < rhs
            }
        }
    }
}

/// What a cell sorts by: its number when it reads as one, otherwise its text.
struct SortKey: Equatable {
    enum Value: Equatable {
        case empty
        case number(Double)
        case text(String)
    }

    let value: Value

    @MainActor
    init(_ cell: String) {
        let text = cell
            .replacingOccurrences(of: TextLabel.Attachment.replacementText, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            value = .empty
        } else if let number = Self.number(in: text) {
            value = .number(number)
        } else {
            value = .text(text)
        }
    }

    /// `text` as a number, allowing grouping commas, a leading currency sign
    /// and a trailing percent sign: "1,024", "$12.50", "-3%", "1e6".
    static func number(in text: String) -> Double? {
        var candidate = Substring(text)
        if let first = candidate.first, "$€£¥￥".contains(first) {
            candidate = candidate.dropFirst()
        }
        if candidate.last == "%" {
            candidate = candidate.dropLast()
        }
        let normalized = String(candidate)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .trimmingCharacters(in: .whitespaces)
        // `Double` also reads "nan" and "infinity", which are words here.
        guard normalized.contains(where: \.isNumber),
              let number = Double(normalized),
              number.isFinite
        else { return nil }
        return number
    }

    /// Numbers before text, numbers by value, text the way Finder sorts names
    /// ("item 2" before "item 10"); empty cells last whichever the direction.
    func compare(to other: SortKey, direction: TableSort.Direction) -> ComparisonResult {
        let ascending: ComparisonResult
        switch (value, other.value) {
        case (.empty, .empty):
            return .orderedSame
        case (.empty, _):
            return .orderedDescending
        case (_, .empty):
            return .orderedAscending
        case let (.number(lhs), .number(rhs)):
            ascending = lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
        case (.number, .text):
            ascending = .orderedAscending
        case (.text, .number):
            ascending = .orderedDescending
        case let (.text(lhs), .text(rhs)):
            ascending = lhs.localizedStandardCompare(rhs)
        }
        guard direction == .descending else { return ascending }
        switch ascending {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
