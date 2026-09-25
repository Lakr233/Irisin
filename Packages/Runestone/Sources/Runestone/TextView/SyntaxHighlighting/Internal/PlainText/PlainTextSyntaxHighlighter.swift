import CoreGraphics
import Foundation

final class PlainTextSyntaxHighlighter: LineSyntaxHighlighter {
    var theme: Theme = DefaultTheme()
    var kern: CGFloat = 0
    var canHighlight: Bool {
        false
    }

    func syntaxHighlight(_: LineSyntaxHighlighterInput) {}

    func syntaxHighlight(_: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback) {
        completion(.success(()))
    }

    func cancel() {}
}
