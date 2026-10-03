//
//  CodeFileName.swift
//  MarkdownView
//

import Foundation

/// The name a code block is saved under: `code` and the extension its
/// language is usually saved with.
enum CodeFileName {
    private static let extensions: [String: String] = [
        "bash": "sh", "sh": "sh", "shell": "sh", "zsh": "sh", "fish": "fish",
        "c": "c", "h": "h", "cpp": "cpp", "c++": "cpp", "cc": "cpp", "hpp": "hpp",
        "objc": "m", "objective-c": "m", "objectivec": "m",
        "swift": "swift", "kotlin": "kt", "kt": "kt", "java": "java", "scala": "scala",
        "go": "go", "golang": "go", "rust": "rs", "rs": "rs", "zig": "zig",
        "python": "py", "py": "py", "ruby": "rb", "rb": "rb", "php": "php", "perl": "pl",
        "lua": "lua", "r": "r", "dart": "dart", "elixir": "ex", "haskell": "hs",
        "javascript": "js", "js": "js", "jsx": "jsx", "typescript": "ts", "ts": "ts", "tsx": "tsx",
        "html": "html", "xml": "xml", "css": "css", "scss": "scss", "vue": "vue",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "ini": "ini",
        "sql": "sql", "graphql": "graphql", "markdown": "md", "md": "md",
        "dockerfile": "dockerfile", "makefile": "mk", "diff": "diff", "patch": "patch",
        "csharp": "cs", "c#": "cs", "cs": "cs", "fsharp": "fs", "powershell": "ps1", "ps1": "ps1",
        "latex": "tex", "tex": "tex", "text": "txt", "plaintext": "txt", "txt": "txt",
    ]

    static func fileName(forLanguage language: String) -> String {
        let key = language.trimmingCharacters(in: .whitespaces).lowercased()
        return "code." + (extensions[key] ?? "txt")
    }
}
