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
    ///   - pages: the controllers whose safe area makes room for the bar. It
    ///     is asked whenever the room changes, not before: a page it leaves
    ///     out later keeps the room it was last given.
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
            InterfaceHostController.enclosing(host)?.openQueue()
        }, for: .touchUpInside)
        // the bar grows with the text size, and the room under it follows
        bar.heightChanged = { [weak self] in self?.makeRoom() }

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
        guard shown != isShown else { return }
        isShown = shown

        let wasHidden = bar.isHidden
        let changes = { [self] in
            bar.alpha = shown ? 1 : 0
            bar.transform = shown ? .identity : Self.lowered
            makeRoom()
        }
        guard animated, host?.view.window != nil else {
            changes()
            bar.isHidden = !shown
            return
        }
        if shown, wasHidden {
            // from below; one caught on its way out turns round where it is
            bar.isHidden = false
            bar.transform = Self.lowered
        }
        UIView.animateFloatingBar(changes) { [weak self, bar] finished in
            // an interrupted animation says nothing about where the bar ends
            guard finished, let self, !isShown else { return }
            bar.isHidden = true
        }
    }

    /// The pages' safe area ends above the bar while it is shown.
    private func makeRoom() {
        let height = max(bar.bounds.height, QueueBarView.minimumHeight)
        let room = isShown ? height + QueueBarView.spacing * 2 : 0
        for page in pages() where page.additionalSafeAreaInsets.bottom != room {
            page.additionalSafeAreaInsets.bottom = room
        }
    }

    /// Where the bar comes up from and goes back to.
    private static let lowered = CGAffineTransform(translationX: 0, y: QueueBarView.minimumHeight / 2)
}
