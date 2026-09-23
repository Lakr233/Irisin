# Runestone

The text view `TextReaderController` shows maintainer scripts and a
package's control fields in, vendored from source so the app carries two
grammars instead of every grammar Tree-sitter has. `Lakr233/Runestone.xcframework`
links about forty languages into one static archive, and the Perl and Ruby
tables alone were 5 MB of the app's binary.

| Directory | What it is | Origin | License |
| --- | --- | --- | --- |
| `Sources/Runestone` | The text view | [simonbs/Runestone](https://github.com/simonbs/Runestone) 0.5.2 (`592434a1`), without its DocC catalog | MIT (`LICENSE`) |
| `Sources/TreeSitter` | Tree-sitter runtime | [tree-sitter/tree-sitter](https://github.com/tree-sitter/tree-sitter), as `Lakr233/Runestone.xcframework` 0.3.2 vendors it | MIT (`Sources/TreeSitter/LICENSE`) |
| `Sources/TreeSitterBash`, `Sources/TreeSitterJSON` | Grammars | [simonbs/TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages), as the same xcframework vendors them | MIT (their `LICENSE`) |
| `Sources/RunestoneLanguageSupport` | `TreeSitterLanguage.bash` and `.json`, with their highlight queries | the same, queries inlined as string literals | MIT |
| `Sources/RunestoneThemeSupport` | Tomorrow and One Dark | Runestone's example themes, as the xcframework vendors them, colours written in code | MIT |

## What changed from upstream

- `TreeSitter/include/TreeSitter.h` completes each tree-sitter handle struct
  before `api.h`, since Xcode 27's importer skips an incomplete C struct, and
  `TreeSitterParser`, `TreeSitterQuery`, `TreeSitterQueryCursor` and
  `TreeSitterTree` hold typed pointers instead of `OpaquePointer` to match.
  The xcframework's `Script/assemble.py` makes the same change.
- `EditMenuController` keeps only its `UIEditMenuInteraction` path, and
  `TextView` dismisses that menu instead of `UIMenuController`'s: the
  pre-iOS 16 path is dead code at this package's floor and warns.
- The themes read their colours from code instead of asset catalogs, and
  `HighlightName` no longer prints the names it does not know.

A language is added by copying its grammar next to the two here, with its
`LICENSE`, and a `TreeSitterLanguage+<Name>.swift` in
`RunestoneLanguageSupport`. Each grammar is paid for in the app's binary.
