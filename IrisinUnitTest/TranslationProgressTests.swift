@testable import irisin
import Testing
import UIKit

@MainActor
struct TranslationProgressTests {
    private static func buttons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
    }

    /// The library's progress alert never drew an action added to it; the
    /// card must have its Cancel the moment it is made.
    @Test
    func theCardHasACancelButtonThatCancelsOnce() throws {
        var cancelled = 0
        let alert = TranslationProgressController.alert { cancelled += 1 }
        alert.loadViewIfNeeded()
        let cancel = try #require(
            Self.buttons(in: alert.view).first { $0.configuration?.title == String(localized: "Cancel") }
        )
        cancel.sendActions(for: .touchUpInside)
        cancel.sendActions(for: .touchUpInside)
        #expect(cancelled == 1)
        #expect(!cancel.isEnabled)
    }
}
