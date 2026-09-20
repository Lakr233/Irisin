@testable import irisin
import PackageDepiction
import Testing
import UIKit

@MainActor
struct DepictionTests {
    private let separator: [String: Any] = ["class": "DepictionSeparatorView"]
    private let header: [String: Any] = ["class": "DepictionHeaderView", "title": "Compatibility"]
    private let subheader: [String: Any] = ["class": "DepictionSubheaderView", "title": "Compatibility"]
    private let unknown: [String: Any] = ["class": "DepictionNoSuchView"]
    private let label: [String: Any] = ["class": "DepictionLabelView", "text": "body"]

    private func build(_ dictionary: [String: Any]) -> DepictionView? {
        DepictionView.view(
            dictionary: dictionary,
            viewController: UIViewController(),
            tintColor: nil,
            isActionable: false
        )
    }

    /// The height Auto Layout gives the view at a phone's width.
    private func height(of view: UIView?) -> CGFloat {
        guard let view else { return -1 }
        return view.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func height(of views: [[String: Any]]) -> CGFloat {
        height(of: build(["class": "DepictionStackView", "views": views]))
    }

    /// The factory looks a class up by the json's string, so the root type
    /// still answers to the runtime name it always had.
    @Test
    func rootViewKeepsItsRuntimeName() {
        #expect(build(["class": "DepictionBaseView"]) != nil)
    }

    /// A stack drops the children this build cannot render; the headers and
    /// separators left around the hole must go with them.
    @Test
    func headerOverAnUnrenderableChildGoesWithItsSeparator() {
        let orphaned = [separator, header, label, separator, subheader, unknown, separator, label]
        let intended = [separator, header, label, separator, label]
        #expect(height(of: orphaned) == height(of: intended))
        #expect(height(of: intended) > 0)
    }

    @Test
    func separatorsAtTheEdgesAndInARowAreDropped() {
        #expect(height(of: [separator, label, separator, separator, label, separator]) == height(of: [label, separator, label]))
        #expect(height(of: [separator, header, separator]) == 0)
    }

    /// Chariz sends its page as html; it renders without a web view, and an
    /// html block that sets no text is reported as unrenderable.
    @Test
    func rawFormatMarkdownRendersAsText() {
        let html = "<style>p{margin:0}</style><p class=\"small\">Supports iOS 8.0 – 17.1. <a href=\"https://chariz.com/\">Chariz</a></p>"
        #expect(height(of: build(["class": "DepictionMarkdownView", "useRawFormat": true, "markdown": html])) > 26)
        #expect(build(["class": "DepictionMarkdownView", "useRawFormat": true, "markdown": "<div></div>"]) == nil)
    }

    @Test
    func contactFieldKeepsTheNameAndLinksTheAddress() {
        #expect(PackageController.contact("Dhinak G <dhinak@example.org>") == ("Dhinak G", "mailto:dhinak@example.org"))
        #expect(PackageController.contact("dhinak@example.org") == ("dhinak@example.org", "mailto:dhinak@example.org"))
        #expect(PackageController.contact("Anthropic PBC <https://www.anthropic.com/>") == ("Anthropic PBC", "https://www.anthropic.com/"))
        #expect(PackageController.contact("ElleKit Team") == ("ElleKit Team", nil))
        #expect(PackageController.contact("Some <thing>") == ("Some <thing>", nil))
    }
}
