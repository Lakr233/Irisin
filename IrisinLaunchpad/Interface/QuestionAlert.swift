//
//  QuestionAlert.swift
//  IrisinLaunchpad
//

import UIKit

/// A change a browser asked for, put to the owner as the system's alert:
/// what it does, Decline, and the change's own button. Decline is the
/// preferred action, so it has the focus when the alert comes up and a
/// press that was meant for something else says no
/// (Documentation/WebManagement.md, Trust); it is the cancel action too,
/// which Menu on the remote answers.
enum QuestionAlert {
    /// More lines than this and the rest is counted, not listed: the whole
    /// plan is on the page that asked.
    private static let listedLines = 10

    static func make(_ question: WebManagement.Question) -> UIAlertController {
        var shown = Array(question.lines.prefix(listedLines))
        let rest = question.lines.count - shown.count
        if rest > 0 {
            shown.append(String(localized: "and \(rest) more"))
        }
        let origin = String(localized: "A browser asks to make this change on this device.")
        let message = shown.isEmpty ? origin : "\(origin)\n\n\(shown.joined(separator: "\n"))"

        let alert = UIAlertController(title: question.title, message: message, preferredStyle: .alert)
        let decline = UIAlertAction(title: String(localized: "Decline"), style: .cancel) { _ in
            WebManagement.shared.answer(question.id, allowed: false)
        }
        let confirm = UIAlertAction(
            title: question.confirmTitle,
            style: question.destructive ? .destructive : .default
        ) { _ in
            WebManagement.shared.answer(question.id, allowed: true)
        }
        alert.addAction(confirm)
        alert.addAction(decline)
        alert.preferredAction = decline
        return alert
    }
}
