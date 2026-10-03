//
//  CodeBlockAction.swift
//  MarkdownView
//

import Foundation

/// A code block as an action sees it when tapped.
public struct CodeBlock: Sendable, Equatable {
    /// The fence's info string, or nil for a block that names no language.
    public let language: String?
    /// The block's text, as shown.
    public let content: String

    public init(language: String?, content: String) {
        self.language = language
        self.content = content
    }
}

/// A button the host adds to a code block's bar, beside Copy.
public struct CodeBlockAction {
    /// Read by VoiceOver and shown as the button's tooltip.
    public var title: String
    /// An SF Symbol name.
    public var systemImage: String
    public var handler: @MainActor (CodeBlock) -> Void

    public init(
        title: String,
        systemImage: String,
        handler: @escaping @MainActor (CodeBlock) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.handler = handler
    }
}

/// Lets a host add its own buttons to code blocks — open a file, run a
/// snippet, send it somewhere.
///
/// Asked once per block when its language is known or changes, not on
/// every streamed token; the content is handed to the action when it is
/// tapped, so a block still streaming gives the handler what it shows then.
@MainActor
public protocol CodeBlockActionProvider: AnyObject {
    /// The buttons for a block in `language`, leading to trailing; they sit
    /// before Copy. Return an empty array for none.
    func codeBlockActions(forLanguage language: String?) -> [CodeBlockAction]
}
