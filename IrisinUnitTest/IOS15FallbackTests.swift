import Foundation
@testable import irisin
@testable import MarkdownView
import Testing

/// The iOS 15 paths, held to the iOS 16 ones they stand in for. The
/// simulator runs the newer system, so both sides run here and must answer
/// alike; the device on iOS 15 then runs only the side checked against it.
struct IOS15FallbackTests {
    private static let contactFields = [
        "Dhinak G <dhinak@example.org>",
        "dhinak@example.org",
        "  dhinak@example.org  ",
        "Anthropic PBC <https://www.anthropic.com/>",
        "<https://example.com/x>",
        "<a@b.c>",
        "ElleKit Team",
        "Some <thing>",
        "Name <a@b.c>\n",
        "Name <a@b.c> trailing",
        "Name\t<http://example.com/>  ",
        "两个 名字 <作者@例子.中国>",
        "Émile Zola 🇫🇷 <emile@example.fr>",
        "a@b@c",
        "",
        " ",
        "Name <ftp://example.com/>",
        "Name <a b@c.d>",
        "Name<a@b.c>",
        "x <y@z> <w@v>",
    ]

    @Test(arguments: contactFields)
    func contactParsesAsSwiftRegexDoes(field: String) {
        let legacy = PackageController.legacyContact(field)
        let current = PackageController.contact(field)
        #expect(legacy.text == current.text)
        #expect(legacy.action == current.action)
    }

    private static let markdown = [
        "## Features",
        "- one\n  2. two",
        "> quoted",
        "See [the guide](https://example.com/a_b) now",
        "Run `apt update` first",
        "<b>Bold</b> https://example.com",
        "Before\n```\nlet x = 1\n```\n---\n1.0.2\nAfter",
        "This is **very** good, ~~not~~ *really*",
        "2 * 3 * 4 apples",
        "# Title\nA **bold** claim\n- item\n1.0",
        "###### Six\n####### Seven",
        "1) first\n10. tenth\n>> nested quote",
        "![image](https://example.com/a.png) and [link]",
        "*** triple *** __under__ ~~strike~~ **unclosed",
        "中文 **强调** 和 `代码` 以及 [链接](https://例子.中国/路径)",
        "Emoji 👨‍👩‍👧 **family** 🇯🇵 *flag*",
        "e\u{301} **é** combining",
        "Line with\ttab and   spaces  ",
        "* * *",
        "- [ ] task\n- [x] done",
        "<a href=\"https://x.y\">x</a> https://a.b/c?d=e&f]",
        "\u{2028}separator **inside**",
    ]

    @Test(arguments: markdown)
    func depictionTranslationMatchesSwiftRegex(text: String) {
        for line in text.components(separatedBy: "\n") {
            if #available(iOS 16, *) {
                let marker = line.prefixMatch(of: #/^(?:\s*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s?))+/#)
                    .map { String($0.output) } ?? ""
                #expect(DepictionTranslation.Legacy.lineMarkerPrefix(of: line) == marker)
                let held = line.matches(of: #/`[^`]+`|!?\[|\]\([^)]*\)|\]|<[^>]+>|https?:\/\/\S+/#)
                    .map { String(line[$0.range]) }
                #expect(DepictionTranslation.Legacy.heldBackRanges(in: line).map { String(line[$0]) } == held)
                let plain = String(line.replacing(#/(\*\*\*|\*\*|\*|__|~~)(\S(?:.*?\S)?)\1/#) { $0.output.2 })
                #expect(DepictionTranslation.Legacy.withoutEmphasis(line) == plain)
            }
        }
    }

    private static let locales = [
        "zh-Hans", "zh_CN", "zh-Hans-CN", "zh_SG", "zh", "zh-Hant", "zh_TW", "zh-Hant-TW",
        "zh_HK", "zh-Hant-HK", "zh_MO", "ja", "ja_JP", "ko_KR", "en", "en_US", "fr_CA",
    ]

    @MainActor
    @Test(arguments: locales)
    func markdownLocaleIsSpelledAsLocaleLanguageSpellsIt(identifier: String) {
        guard #available(iOS 16, *) else { return }
        #expect(MarkdownContentLocale.normalizedLanguage(identifier: identifier)
            == MarkdownContentLocale.normalizedLanguage(Locale(identifier: identifier).language))
    }

    @Test(arguments: locales)
    func translatorLocalePartsAreLocaleLanguageParts(identifier: String) {
        guard #available(iOS 16, *) else { return }
        let language = Locale.Language(identifier: identifier)
        let parts = Locale.IdentifierParts(identifier)
        #expect(parts.language == language.languageCode?.identifier)
        #expect(parts.region == language.region?.identifier)
        if language.languageCode == .chinese {
            #expect(parts.script == Locale.Language(identifier: language.maximalIdentifier).script?.identifier)
        }
    }

    @Test(arguments: [
        ("zh-Hans", "zh_CN"), ("zh-Hant", "zh_TW"), ("zh_HK", "zh-Hant-HK"), ("en", "en_US"),
        ("ja", "ja_JP"), ("zh-Hans", "zh-Hant"), ("en", "fr"), ("pt_BR", "pt_PT"),
    ])
    func equivalentLocalesAgreeWhereRegionsAreNamed(pair: (String, String)) {
        guard #available(iOS 16, *) else { return }
        let current = Locale.Language(identifier: pair.0).isEquivalent(to: Locale.Language(identifier: pair.1))
        let legacy = Locale.IdentifierParts(pair.0).isEquivalent(to: Locale.IdentifierParts(pair.1))
        // a region left out is not held against the other side below iOS 16,
        // where likely subtags are not offered: legacy may say yes where the
        // current says no, never the other way round
        #expect(!current || legacy)
        if Locale.IdentifierParts(pair.0).region != nil, Locale.IdentifierParts(pair.1).region != nil {
            #expect(current == legacy)
        }
    }
}
