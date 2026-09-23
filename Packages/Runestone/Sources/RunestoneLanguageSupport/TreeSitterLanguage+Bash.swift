import Runestone
import TreeSitterBash

public extension TreeSitterLanguage {
    static var bash: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_bash(),
            highlightsQuery: TreeSitterLanguage.Query(string: bashHighlights),
            injectionsQuery: nil,
            indentationScopes: .bash
        )
    }
}

public extension TreeSitterIndentationScopes {
    static var bash: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: [
                "if_statement",
                "else",
                "while_statement",
                "for_statement",
                "function_definition",
                "do_group",
            ],
            outdent: [
                "fi",
                "done",
            ]
        )
    }
}

// Queries/highlights.scm from TreeSitterLanguages, kept as a literal so the
// package ships no resource bundle for it.
private let bashHighlights = #"""
[
  (string)
  (raw_string)
  (heredoc_body)
  (heredoc_start)
] @string

(command_name) @function

(variable_name) @property

[
  "case"
  "do"
  "done"
  "elif"
  "else"
  "esac"
  "export"
  "fi"
  "for"
  "function"
  "if"
  "in"
  "unset"
  "while"
  "then"
] @keyword

(comment) @comment

(function_definition name: (word) @function)

(file_descriptor) @number

[
  (command_substitution)
  (process_substitution)
  (expansion)
]@embedded

[
  "$"
  "&&"
  ">"
  ">>"
  "<"
  "|"
] @operator

(
  (command (_) @constant)
  (#match? @constant "^-")
)
"""#
