//
//  QuestionController.swift
//  IrisinLaunchpad
//

import UIKit

/// A change a browser asked for, put to the owner: what it does, and two
/// buttons. Decline has the focus when it comes up, so a press that was
/// meant for something else says no (Documentation/WebManagement.md,
/// Trust), and Menu on the remote declines as well.
final class QuestionController: UIViewController {
    let question: WebManagement.Question

    private let declineButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    /// More lines than this and the rest is counted, not listed: the whole
    /// plan is on the page that asked.
    private static let listedLines = 10

    init(question: WebManagement.Question) {
        self.question = question
        super.init(nibName: nil, bundle: nil)
        #if os(tvOS)
            modalPresentationStyle = .fullScreen
        #else
            modalPresentationStyle = .formSheet
        #endif
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = UILabel()
        title.font = .launchpadTitle
        title.textColor = .launchpadPrimaryText
        title.numberOfLines = 0
        title.textAlignment = .center
        title.text = question.title

        let origin = UILabel()
        origin.font = .launchpadBody
        origin.textColor = .launchpadSecondaryText
        origin.numberOfLines = 0
        origin.textAlignment = .center
        origin.text = String(localized: "A browser asks to make this change on this device.")

        var shown = Array(question.lines.prefix(Self.listedLines))
        let rest = question.lines.count - shown.count
        if rest > 0 {
            shown.append(String(localized: "and \(rest) more"))
        }
        let lines = UILabel()
        lines.font = .launchpadBody
        lines.textColor = .launchpadPrimaryText
        lines.numberOfLines = 0
        lines.textAlignment = .center
        lines.text = shown.joined(separator: "\n")

        declineButton.setTitle(String(localized: "Decline"), for: .normal)
        declineButton.titleLabel?.font = .launchpadHeadline
        declineButton.addAction(UIAction { [weak self] _ in self?.answer(false) }, for: .primaryActionTriggered)

        confirmButton.setTitle(question.confirmTitle, for: .normal)
        confirmButton.titleLabel?.font = .launchpadHeadline
        if question.destructive {
            confirmButton.setTitleColor(.launchpadDestructive, for: .normal)
        }
        confirmButton.addAction(UIAction { [weak self] _ in self?.answer(true) }, for: .primaryActionTriggered)

        let buttons = UIStackView(arrangedSubviews: [declineButton, confirmButton])
        buttons.axis = .horizontal
        buttons.spacing = 48
        buttons.distribution = .fillEqually

        let content = UIStackView(arrangedSubviews: [title, origin, lines, buttons])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 32
        content.setCustomSpacing(56, after: lines)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: margins.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: margins.topAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
        ])
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        [declineButton]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            answer(false)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    /// The screen takes the question away once `WebManagement` has the
    /// answer (`LaunchpadController.ask`).
    private func answer(_ allowed: Bool) {
        WebManagement.shared.answer(question.id, allowed: allowed)
    }
}
