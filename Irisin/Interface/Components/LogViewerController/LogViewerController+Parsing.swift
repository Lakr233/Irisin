//
//  LogViewerController+Parsing.swift
//  Irisin
//

import Dog
import UIKit

extension LogViewerController {
    func logText() -> String {
        String(Dog.shared.obtainCurrentLogContent().dropFirst(hiddenPrefixCount))
    }

    /// Bytes in the log file, without reading it.
    static var fileLength: Int {
        guard let path = Dog.shared.currentLogFileLocation?.path,
              let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        else { return -1 }
        return size
    }

    func reloadIfFileGrew() {
        let length = Self.fileLength
        guard length != lastReadLength else { return }
        reload()
    }

    @objc func reload() {
        // a first parse still running would land older lines over these
        work?.cancel()
        work = nil
        lastReadLength = Self.fileLength
        parsed = Self.parseLogLines(logText())
        applyFilters(stickToBottom: isNearBottom)
    }

    /// The first parse, off the main actor.
    @concurrent
    nonisolated static func parse(_ text: String) async -> [LogLine] {
        parseLogLines(text)
    }

    private nonisolated static func parseLogLines(_ text: String) -> [LogLine] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var parsedLines: [LogLine] = []
        var currentCategory = "System"
        var building: LogLine?

        func flush() {
            guard let logLine = building else { return }
            parsedLines.append(logLine)
            building = nil
        }

        for line in lines {
            if let category = Self.parseCategory(line) {
                flush()
                currentCategory = category
                continue
            }
            if let logLine = Self.parseEntry(line, category: currentCategory) {
                flush()
                building = logLine
                continue
            }
            if let current = building {
                building = current.appending(line)
            } else if !line.isEmpty {
                building = LogLine(
                    timestamp: "",
                    level: .info,
                    category: currentCategory,
                    message: line,
                    fullText: line
                )
            }
        }
        flush()

        return parsedLines
    }

    /// Dog writes `[Kind]` on its own line when the tag changes.
    private nonisolated static func parseCategory(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count >= 3, !line.contains("|") else {
            return nil
        }
        let name = String(line.dropFirst().dropLast())
        return name.isEmpty ? nil : name
    }

    /// Dog writes `* |level| yyyy-MM-dd_HH-mm-ss| message`.
    private nonisolated static func parseEntry(_ line: String, category: String) -> LogLine? {
        guard line.hasPrefix("* |") else { return nil }
        let body = line.dropFirst(3)
        guard let levelSep = body.firstIndex(of: "|") else { return nil }
        let levelStr = body[..<levelSep].trimmingCharacters(in: .whitespaces)
        guard let level = Dog.DogLevel(rawValue: levelStr) else { return nil }
        var rest = body[body.index(after: levelSep)...]
        if rest.first == " " {
            rest = rest.dropFirst()
        }
        guard let timeSep = rest.firstIndex(of: "|") else { return nil }
        let timestamp = rest[..<timeSep].trimmingCharacters(in: .whitespaces)
        var message = rest[rest.index(after: timeSep)...]
        if message.first == " " {
            message = message.dropFirst()
        }
        return LogLine(
            timestamp: String(timestamp),
            level: level,
            category: category,
            message: String(message),
            fullText: "[\(category)] \(line)"
        )
    }
}
