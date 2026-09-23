import Foundation
import NaturalLanguage

@MainActor
enum MarkdownContentLocale {
    private final class CachedLanguageRuns: NSObject {
        let runs: [(NSRange, String)]

        init(runs: [(NSRange, String)]) {
            self.runs = runs
        }
    }

    private struct LanguageToken {
        var range: NSRange
        var containsKana: Bool
        var containsHangul: Bool
    }

    private static let cache = NSCache<NSString, CachedLanguageRuns>()

    private static let tokenBoundaryCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    static func applyLanguageAttributes(
        to attributedString: NSMutableAttributedString,
        fallbackLocale: Locale
    ) {
        guard attributedString.length > 0 else { return }

        let runs = cachedLanguageRuns(for: attributedString.string, fallbackLocale: fallbackLocale)
        for (range, language) in runs {
            attributedString.addAttribute(
                .coreTextLanguage,
                value: language,
                range: range
            )
        }
    }

    /// Whether a language still has work to do once the font is resolved.
    ///
    /// The attribute exists so CoreText picks the right font and the right
    /// glyphs for a run. Resolving the font is done once, where the text is
    /// cached; leaving the attribute in place makes building a framesetter
    /// three times more expensive, on every rebuild.
    ///
    /// Two languages genuinely need it at shaping time, measured over 3166
    /// ideographs and four widths:
    ///
    /// - Traditional Chinese picks a different glyph for 41% of them.
    /// - Korean breaks lines differently.
    ///
    /// Simplified Chinese and Japanese change neither. Anything else — Arabic,
    /// Hebrew, a language added later — keeps the attribute, because the cost
    /// of being wrong is a reader seeing the wrong shapes.
    static func affectsShaping(_ language: String) -> Bool {
        language != "zh-Hans" && language != "ja"
    }

    static func dominantLanguageIdentifier(
        for text: String,
        fallbackLocale: Locale
    ) -> String? {
        let scriptLanguage = scriptLanguageIdentifier(for: text, fallbackLocale: fallbackLocale)
        if scriptLanguage != nil {
            return scriptLanguage
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    private static func languageIdentifier(
        for character: Character,
        token: LanguageToken?,
        fallbackLocale: Locale
    ) -> String? {
        if let token, character.unicodeScalars.contains(where: { isHan($0.value) }) {
            if token.containsKana {
                return "ja"
            }
            if token.containsHangul {
                return "ko"
            }
        }
        return scriptLanguageIdentifier(scalars: character.unicodeScalars, fallbackLocale: fallbackLocale)
    }

    private static func scriptLanguageIdentifier(
        for text: String,
        fallbackLocale: Locale
    ) -> String? {
        scriptLanguageIdentifier(scalars: text.unicodeScalars, fallbackLocale: fallbackLocale)
    }

    private static func scriptLanguageIdentifier(
        scalars: some Sequence<Unicode.Scalar>,
        fallbackLocale: Locale
    ) -> String? {
        var containsHan = false
        var containsArabic = false
        var containsHebrew = false

        for scalar in scalars {
            let value = scalar.value
            if isHiragana(value) || isKatakana(value) {
                return "ja"
            }
            if isHangul(value) {
                return "ko"
            }
            if isHan(value) {
                containsHan = true
            }
            if isArabic(value) {
                containsArabic = true
            }
            if isHebrew(value) {
                containsHebrew = true
            }
        }

        if containsHan {
            return preferredCJKLanguageIdentifier(fallbackLocale)
        }
        if containsArabic {
            return "ar"
        }
        if containsHebrew {
            return "he"
        }
        return nil
    }

    private static func preferredCJKLanguageIdentifier(_ locale: Locale) -> String {
        let identifier = locale.identifier
        if identifier.hasPrefix("ja") {
            return "ja"
        }
        if identifier.hasPrefix("ko") {
            return "ko"
        }
        if identifier.hasPrefix("zh") {
            return identifier
        }
        return "zh-Hans"
    }

    private static func characterRanges(in string: String) -> [NSRange] {
        var ranges = [NSRange]()
        var cursor = string.startIndex
        while cursor < string.endIndex {
            let next = string.index(after: cursor)
            ranges.append(NSRange(cursor ..< next, in: string))
            cursor = next
        }
        return ranges
    }

    private static func cachedLanguageRuns(
        for string: String,
        fallbackLocale: Locale
    ) -> [(NSRange, String)] {
        let key = "\(fallbackLocale.identifier)|\(string)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.runs
        }

        let ranges = characterRanges(in: string)
        let tokens = languageTokens(in: string, ranges: ranges)
        var runs = [(NSRange, String)]()
        var currentLanguage: String?
        var runStart = 0
        var tokenIndex = 0

        func flush(until location: Int) {
            guard let currentLanguage, location > runStart else { return }
            runs.append((NSRange(location: runStart, length: location - runStart), currentLanguage))
        }

        for (character, range) in zip(string, ranges) {
            while tokenIndex < tokens.count, tokens[tokenIndex].range.upperBound <= range.location {
                tokenIndex += 1
            }
            var token: LanguageToken?
            if tokenIndex < tokens.count, NSLocationInRange(range.location, tokens[tokenIndex].range) {
                token = tokens[tokenIndex]
            }
            let language = languageIdentifier(
                for: character,
                token: token,
                fallbackLocale: fallbackLocale
            )
            if language != currentLanguage {
                flush(until: range.location)
                currentLanguage = language
                runStart = range.location
            }
        }

        flush(until: string.utf16.count)
        cache.setObject(CachedLanguageRuns(runs: runs), forKey: key)
        return runs
    }

    private static func languageTokens(in string: String, ranges: [NSRange]) -> [LanguageToken] {
        var tokens = [LanguageToken]()
        var currentToken: LanguageToken?

        for (character, range) in zip(string, ranges) {
            var isBoundary = true
            var containsKana = false
            var containsHangul = false
            for scalar in character.unicodeScalars {
                let value = scalar.value
                if isHiragana(value) || isKatakana(value) {
                    containsKana = true
                }
                if isHangul(value) {
                    containsHangul = true
                }
                if isBoundary, !tokenBoundaryCharacters.contains(scalar) {
                    isBoundary = false
                }
            }

            if isBoundary {
                if let token = currentToken {
                    tokens.append(token)
                    currentToken = nil
                }
                continue
            }

            if var token = currentToken {
                token.range.length = range.upperBound - token.range.location
                token.containsKana = token.containsKana || containsKana
                token.containsHangul = token.containsHangul || containsHangul
                currentToken = token
            } else {
                currentToken = LanguageToken(
                    range: range,
                    containsKana: containsKana,
                    containsHangul: containsHangul
                )
            }
        }

        if let token = currentToken {
            tokens.append(token)
        }
        return tokens
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400 ... 0x4DBF).contains(value)
            || (0x4E00 ... 0x9FFF).contains(value)
            || (0xF900 ... 0xFAFF).contains(value)
            || (0x20000 ... 0x2A6DF).contains(value)
            || (0x2A700 ... 0x2B73F).contains(value)
            || (0x2B740 ... 0x2B81F).contains(value)
            || (0x2B820 ... 0x2CEAF).contains(value)
            || (0x2CEB0 ... 0x2EBEF).contains(value)
            || (0x30000 ... 0x3134F).contains(value)
    }

    private static func isHiragana(_ value: UInt32) -> Bool {
        (0x3040 ... 0x309F).contains(value)
    }

    private static func isKatakana(_ value: UInt32) -> Bool {
        (0x30A0 ... 0x30FF).contains(value)
            || (0x31F0 ... 0x31FF).contains(value)
            || (0xFF66 ... 0xFF9D).contains(value)
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0x1100 ... 0x11FF).contains(value)
            || (0x3130 ... 0x318F).contains(value)
            || (0xAC00 ... 0xD7AF).contains(value)
    }

    private static func isArabic(_ value: UInt32) -> Bool {
        (0x0600 ... 0x06FF).contains(value)
            || (0x0750 ... 0x077F).contains(value)
            || (0x08A0 ... 0x08FF).contains(value)
            || (0xFB50 ... 0xFDFF).contains(value)
            || (0xFE70 ... 0xFEFF).contains(value)
    }

    private static func isHebrew(_ value: UInt32) -> Bool {
        (0x0590 ... 0x05FF).contains(value)
    }
}
