import Foundation

/// The text of an index, a status file or a control file.
///
/// apt never decodes one of these: it parses records as bytes, takes every
/// field for UTF-8 and only when printing turns bytes that are not into a
/// `?` (`UTF8ToCodeset`). So the file is UTF-8 and is never read whole as
/// anything else. Where apt would print the `?` we look closer, a line at a
/// time: repositories from 2008 carry fields typed on a Mac or on Windows
/// (BigBoss has both beside its UTF-8 Chinese), and a line that is not UTF-8
/// is read as whichever of the two makes words of it.
enum IndexText {
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { line in String(data: Data(line), encoding: .utf8) ?? legacy(Data(line)) }
            .joined(separator: "\n")
    }

    /// Windows-1252 wins a draw: it is the commoner of the two, and the draw
    /// is `’` against `í` inside an English word.
    private static func legacy(_ line: Data) -> String {
        let readings = [String.Encoding.windowsCP1252, .macOSRoman]
            .compactMap { String(data: line, encoding: $0) }
            .map { (text: $0, score: score($0)) }
        guard let best = readings.max(by: { $0.score < $1.score }) else {
            return String(decoding: line, as: UTF8.self)
        }
        return readings.first { $0.score == best.score }?.text ?? best.text
    }

    /// How much a reading looks like writing: a lowercase letter inside a
    /// word and an apostrophe inside one count for it, as does a dash or a
    /// quote at the edge of one; a capital after a lowercase letter, a
    /// symbol inside a word and a control character count against.
    private static func score(_ text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        var total = 0
        for (index, scalar) in scalars.enumerated() where !scalar.isASCII {
            let before = index > 0 ? scalars[index - 1] : " "
            let after = index + 1 < scalars.count ? scalars[index + 1] : " "
            let inWord = isLetter(before) && isLetter(after)
            switch scalar.properties.generalCategory {
            case .lowercaseLetter:
                total += isLetter(before) || isLetter(after) ? 1 : 0
            case .uppercaseLetter:
                total += before.properties.isLowercase ? -1 : 0
            case .control, .unassigned, .privateUse:
                total -= 2
            case .finalPunctuation where inWord:
                total += 1
            case .dashPunctuation, .initialPunctuation, .finalPunctuation:
                total += inWord ? -1 : 1
            default:
                total += inWord ? -1 : 0
            }
        }
        return total
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
    }
}
