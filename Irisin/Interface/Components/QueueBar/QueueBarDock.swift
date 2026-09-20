//
//  QueueBarDock.swift
//  Irisin
//

import Combine
import SnapKit
import UIKit

/// Keeps a `QueueBarView` at the bottom of one layout: there while the queue
/// touches a package and its page is not the one open, gone otherwise. The
/// pages under it give up the bar's height as safe area while it is there,
/// so a list's last row scrolls clear of it. The count is the Queue tab's
/// badge, from the same notification.
final class QueueBarDock {
    private let bar = QueueBarView()
    private weak var host: UIViewController?
    private let pages: () -> [UIViewController]
    private var bottom: Constraint?
    private var isShown = false
    private var subscriptions = Set<AnyCancellable>()

    /// The Queue page is open in this layout: nothing to offer a way to.
    var isQueueOpen = false {
        didSet {
            guard isQueueOpen != oldValue else { return }
            update(animated: true)
        }
    }

    /// From the host's bottom edge up to the bar's: the host's safe area, or
    /// a tab bar's height.
    var bottomInset: CGFloat = 0 {
        didSet {
            guard bottomInset != oldValue else { return }
            bottom?.update(inset: bottomInset + QueueBarView.spacing)
        }
    }

    /// - Parameters:
    ///   - host: the layout's controller; the bar goes on top of its view,
    ///     centered in `guide`.
    ///   - pages: the controllers whose safe area makes room for the bar.
    init(host: UIViewController, centeredIn guide: UILayoutGuide, pages: @escaping () -> [UIViewController]) {
        self.host = host
        self.pages = pages

        host.view.addSubview(bar)
        bar.snp.makeConstraints { x in
            x.centerX.equalTo(guide)
            x.width.lessThanOrEqualTo(QueueBarView.maximumWidth)
            x.width.equalTo(guide).inset(16).priority(.high)
            bottom = x.bottom.equalToSuperview().inset(QueueBarView.spacing).constraint
        }
        bar.alpha = 0
        bar.isHidden = true
        bar.addAction(UIAction { [weak host] _ in
            guard let host else { return }
            NavigatorEnterViewController.enclosing(host)?.openQueue()
        }, for: .touchUpInside)

        NotificationCenter.default.publisher(for: .TaskQueueChanged)
            .receive(on: DispatchQueue.main)
            .map { _ in QueueController.queuedCount }
            .removeDuplicates()
            .sink { [weak self] _ in self?.update(animated: true) }
            .store(in: &subscriptions)
        update(animated: false)
    }

    private func update(animated: Bool) {
        let count = QueueController.queuedCount
        let shown = count > 0 && !isQueueOpen
        if count > 0 {
            bar.count = count // a bar on its way out keeps the number it had
        }
        guard shown != isShown, let host else { return }
        isShown = shown

        let room = shown ? QueueBarView.height + QueueBarView.spacing * 2 : 0
        let pages = pages()
        let changes = { [bar] in
            bar.alpha = shown ? 1 : 0
            bar.transform = shown ? .identity : Self.lowered
            for page in pages {
                page.additionalSafeAreaInsets.bottom = room
            }
        }
        guard animated, host.view.window != nil else {
            changes()
            bar.isHidden = !shown
            return
        }
        if shown {
            bar.isHidden = false
            bar.transform = Self.lowered
        }
        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes
        ) { [weak self, bar] _ in
            guard let self, !isShown else { return }
            bar.isHidden = true
        }
    }

    /// Where the bar comes up from and goes back to.
    private static let lowered = CGAffineTransform(translationX: 0, y: QueueBarView.height / 2)
}
