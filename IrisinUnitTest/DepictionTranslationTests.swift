@testable import irisin
import Testing

struct DepictionTranslationTests {
    /// Stands in for the engine: what it was handed comes back marked.
    private func marked(_ markdown: String) -> String {
        DepictionTranslation.rewrite(markdown: markdown) { "«\($0)»" }
    }

    @Test
    func markdownSyntaxNeverReachesTheEngine() {
        #expect(marked("## Features") == "## «Features»")
        #expect(marked("- one\n  2. two") == "- «one»\n  2. «two»")
        #expect(marked("> quoted") == "> «quoted»")
        #expect(marked("See [the guide](https://example.com/a_b) now") == "«See» [«the guide»](https://example.com/a_b) «now»")
        #expect(marked("Run `apt update` first") == "«Run» `apt update` «first»")
        #expect(marked("<b>Bold</b> https://example.com") == "<b>«Bold»</b> https://example.com")
    }

    @Test
    func codeFencesAndLinesWithoutWordsStayAsWritten() {
        let markdown = "Before\n```\nlet x = 1\n```\n---\n1.0.2\nAfter"
        #expect(marked(markdown) == "«Before»\n```\nlet x = 1\n```\n---\n1.0.2\n«After»")
    }

    /// An engine returns `** very **`, which prints its asterisks.
    @Test
    func aTranslatedLineGivesItsEmphasisUp() {
        #expect(marked("This is **very** good, ~~not~~ *really*") == "«This is very good, not really»")
        #expect(marked("2 * 3 * 4 apples") == "«2 * 3 * 4 apples»")
    }

    @Test
    func comparingPutsTheTranslationUnderWhatWasWritten() {
        let compared = DepictionTranslation.rewrite(markdown: "# Title\nA **bold** claim\n- item\n1.0", comparing: true) {
            "«\($0)»"
        }
        #expect(compared == "# Title\n# «Title»\nA **bold** claim\n\n«A bold claim»\n- item\n- «item»\n1.0")
    }

    @Test
    func onlyProseIsTakenFromADepiction() {
        let depiction: [String: Any] = [
            "class": "DepictionTabView",
            "tabs": [[
                "class": "DepictionStackView",
                "tabname": "Details",
                "views": [
                    ["class": "DepictionHeaderView", "title": "Header"],
                    ["class": "DepictionMarkdownView", "markdown": "Body\n\nBody"],
                    ["class": "DepictionMarkdownView", "markdown": "<p>html</p>", "useRawFormat": true],
                    ["class": "DepictionTableTextView", "title": "Version", "text": "1.0"],
                    ["class": "DepictionLabelView", "text": "Label"],
                ],
            ]],
        ]
        #expect(DepictionTranslation.texts(in: depiction) == ["Details", "Header", "Body", "Label"])

        let answer = DepictionTranslation.replacing(depiction, with: ["Body": "Corps", "Label": "Étiquette"])
        let views = (answer["tabs"] as? [[String: Any]])?.first?["views"] as? [[String: Any]]
        #expect(views?[0]["title"] as? String == "Header")
        #expect(views?[1]["markdown"] as? String == "Corps\n\nCorps")
        #expect(views?[3]["text"] as? String == "1.0")
        #expect(views?[4]["text"] as? String == "Étiquette")
    }
}
