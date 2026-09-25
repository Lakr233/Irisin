import Runestone
import TreeSitterJSON

public extension TreeSitterLanguage {
    static var json: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_json(),
            highlightsQuery: TreeSitterLanguage.Query(string: jsonHighlights),
            injectionsQuery: nil,
            indentationScopes: .json
        )
    }
}

public extension TreeSitterIndentationScopes {
    static var json: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["object", "array"], outdent: ["}", "]"])
    }
}

/// Queries/highlights.scm from TreeSitterLanguages, kept as a literal so the
/// package ships no resource bundle for it.
private let jsonHighlights = #"""
(pair
  key: (_) @string.special.key)

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @escape

(comment) @comment
"""#
