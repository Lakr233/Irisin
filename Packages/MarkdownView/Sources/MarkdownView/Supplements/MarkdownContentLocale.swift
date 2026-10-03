import Foundation

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

    /// Picks each run's fallback font for the language it is written in.
    ///
    /// The language attribute is applied, the fonts are resolved against it,
    /// and then it is dropped wherever it no longer changes what the reader
    /// sees — see ``affectsShaping(_:)``. A run whose font is replaced after
    /// this has lost the language it was resolved for, so it must come back
    /// through here rather than being left to the pass over the document.
    static func resolveFonts(
        in attributedString: NSMutableAttributedString,
        fallbackLocale: Locale
    ) {
        applyLanguageAttributes(to: attributedString, fallbackLocale: fallbackLocale)
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.fixAttributes(in: fullRange)
        attributedString.enumerateAttribute(.coreTextLanguage, in: fullRange, options: []) { value, range, _ in
            guard let language = value as? String,
                  !affectsShaping(language)
            else { return }
            attributedString.removeAttribute(.coreTextLanguage, range: range)
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
    /// Simplified Chinese and Japanese change neither. The reader's locale is
    /// spelled through ``normalizedLanguage(_:)`` first, so `zh_CN` arrives
    /// here as `zh-Hans`. Anything else — Arabic,
    /// Hebrew, a language added later — keeps the attribute, because the cost
    /// of being wrong is a reader seeing the wrong shapes.
    static func affectsShaping(_ language: String) -> Bool {
        language != "zh-Hans" && language != "ja"
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

    /// The language Han text is written in for a reader in `locale`.
    ///
    /// Memoized per locale identifier: it is asked for on every text that
    /// misses the run cache, and the answer only depends on the locale.
    private static func preferredCJKLanguageIdentifier(_ locale: Locale) -> String {
        let key = locale.identifier
        if let cached = cjkLanguageByLocale[key] {
            return cached
        }
        let language = normalizedLanguage(locale.language)
        cjkLanguageByLocale[key] = language
        return language
    }

    private static var cjkLanguageByLocale: [String: String] = [:]

    /// One spelling per way of drawing Han text, read from the locale's
    /// language, script and region rather than from its identifier string.
    ///
    /// The locale arrives as `zh_CN`, `zh-Hans-CN`, `zh_SG` or plain `zh`, and
    /// every one of those draws Simplified Chinese exactly as `zh-Hans` does —
    /// same font, same glyphs, same advances. Spelled `zh-Hans` the attribute
    /// can be dropped once the font is resolved (see ``affectsShaping(_:)``);
    /// spelled any other way it stayed on every run and made each rebuild
    /// pay for it.
    ///
    /// Traditional Chinese keeps its region: Hong Kong and Macau are drawn
    /// with their own fonts and differ from `zh-Hant` in hundreds of glyphs,
    /// so collapsing them would change what those readers see. Taiwan draws
    /// exactly as `zh-Hant` does and is spelled that way, which CoreText
    /// shapes measurably faster than `zh-Hant-TW`.
    ///
    /// Any language that is not Chinese, Japanese or Korean falls back to
    /// Simplified Chinese, as it always has.
    static func normalizedLanguage(_ language: Locale.Language) -> String {
        switch language.languageCode {
        case .japanese?:
            return "ja"
        case .korean?:
            return "ko"
        case .chinese?:
            break
        default:
            return "zh-Hans"
        }

        let script = language.script
            ?? Locale.Language(identifier: language.maximalIdentifier).script
        guard script == .hanTraditional else {
            return "zh-Hans"
        }
        guard let region = language.region, region != .taiwan else {
            return "zh-Hant"
        }
        return "zh-Hant-\(region.identifier)"
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
