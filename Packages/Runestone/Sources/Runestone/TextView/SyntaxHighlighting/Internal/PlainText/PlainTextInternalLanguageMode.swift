import Foundation

final class PlainTextInternalLanguageMode: InternalLanguageMode {
    func parse(_: NSString) {}

    func parse(_: NSString, completion: @escaping ((Bool) -> Void)) {
        completion(true)
    }

    func textDidChange(_: TextChange) -> LineChangeSet {
        LineChangeSet()
    }

    func tokenType(at _: Int) -> String? {
        nil
    }

    func createLineSyntaxHighlighter() -> LineSyntaxHighlighter {
        PlainTextSyntaxHighlighter()
    }

    func highestSyntaxNode(at _: LinePosition) -> SyntaxNode? {
        nil
    }

    func syntaxNode(at _: LinePosition) -> SyntaxNode? {
        nil
    }

    func currentIndentLevel(of _: DocumentLineNode, using _: IndentStrategy) -> Int {
        0
    }

    func strategyForInsertingLineBreak(
        from _: LinePosition,
        to _: LinePosition,
        using _: IndentStrategy
    ) -> InsertLineBreakIndentStrategy {
        InsertLineBreakIndentStrategy(indentLevel: 0, insertExtraLineBreak: false)
    }

    func detectIndentStrategy() -> DetectedIndentStrategy {
        .unknown
    }
}
