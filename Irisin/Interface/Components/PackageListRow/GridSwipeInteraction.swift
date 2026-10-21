//
//  GridSwipeInteraction.swift
//  Irisin
//

import UIKit

/// A swipe on the cells of a grid, which UIKit gives only to a list
/// section: the `UISwipeActionsConfiguration` a list row of the same
/// package shows, its actions drawn on the trailing side as the cell's
/// content slides aside. One cell is open at a time; scrolling, a tap
/// anywhere but its actions, an action, and `close` (before a snapshot
/// moves the cells) put it back.
final class GridSwipeInteraction: NSObject, UIGestureRecognizerDelegate {
    /// The swipe of the item at an index path, or nil where there is none,
    /// including where a list section swipes the row itself.
    typealias Provider = (IndexPath) -> UISwipeActionsConfiguration?

    private weak var collectionView: UICollectionView?
    private let provider: Provider
    private let pan = UIPanGestureRecognizer()
    private let dismissal = UITapGestureRecognizer()
    private var swiped: Swiped?
    /// Where the open cell was when the current pan began.
    private var origin: CGFloat = 0

    /// The cell that is open or opening, and how far.
    private final class Swiped {
        let cell: UICollectionViewCell
        let tray: GridSwipeTray
        /// The cell's own clipping, given back when it closes.
        var clipped: Bool
        var offset: CGFloat = 0

        init(cell: UICollectionViewCell, tray: GridSwipeTray) {
            self.cell = cell
            self.tray = tray
            clipped = cell.clipsToBounds
        }
    }

    init(collectionView: UICollectionView, provider: @escaping Provider) {
        self.collectionView = collectionView
        self.provider = provider
        super.init()
        pan.delegate = self
        pan.addTarget(self, action: #selector(panned))
        collectionView.addGestureRecognizer(pan)
        // a pan that is ours is no scroll; one that is not fails at once
        collectionView.panGestureRecognizer.require(toFail: pan)
        collectionView.panGestureRecognizer.addTarget(self, action: #selector(scrolled))
        dismissal.delegate = self
        dismissal.isEnabled = false
        dismissal.addTarget(self, action: #selector(dismissed))
        collectionView.addGestureRecognizer(dismissal)
    }

    /// Puts the open cell back.
    func close(animated: Bool) {
        guard let swiped else { return }
        self.swiped = nil
        dismissal.isEnabled = false
        let finish = { [weak self] in
            swiped.tray.removeFromSuperview()
            // a swipe that began on the same cell meanwhile keeps its place,
            // and gives the cell its own clipping back when it closes
            if let next = self?.swiped, next.cell === swiped.cell {
                next.clipped = swiped.clipped
                return
            }
            swiped.cell.clipsToBounds = swiped.clipped
            Self.slide(swiped.cell, by: 0)
        }
        guard animated, swiped.cell.window != nil else {
            move(swiped, to: 0)
            return finish()
        }
        UIView.animateSwipe { [self] in move(swiped, to: 0) } completion: { _ in finish() }
    }

    // MARK: - GESTURES

    /// The trailing edge, as a sign along x.
    private var trailing: CGFloat {
        collectionView?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        guard let collectionView else { return false }
        let velocity = pan.velocity(in: collectionView)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        let point = pan.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let cell = collectionView.cellForItem(at: indexPath)
        else { return false }
        if let swiped, swiped.cell === cell {
            origin = swiped.offset
            return true
        }
        // a closed cell opens toward its trailing edge only
        guard velocity.x * trailing < 0,
              let configuration = provider(indexPath), !configuration.actions.isEmpty
        else { return false }
        close(animated: true)
        let tray = GridSwipeTray(actions: configuration.actions) { [weak self] action, button in
            self?.perform(action, from: button)
        }
        cell.addSubview(tray)
        swiped = Swiped(cell: cell, tray: tray)
        cell.clipsToBounds = true
        origin = 0
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dismissal, let swiped else { return true }
        // the actions take their own taps
        return touch.view?.isDescendant(of: swiped.tray) != true
    }

    @objc private func panned() {
        guard let swiped, let collectionView else { return }
        let width = swiped.tray.fullWidth
        switch pan.state {
        case .changed:
            let wanted = origin - pan.translation(in: collectionView).x * trailing
            // past the actions the content follows the finger at a quarter
            let offset = wanted > width ? width + (wanted - width) / 4 : max(wanted, 0)
            move(swiped, to: offset)
        case .ended, .cancelled, .failed:
            let thrown = swiped.offset - pan.velocity(in: collectionView).x * trailing * 0.15
            guard pan.state == .ended, thrown > width / 2 else { return close(animated: true) }
            dismissal.isEnabled = true
            UIView.animateSwipe { [self] in move(swiped, to: width) } completion: { _ in }
        default:
            return
        }
    }

    @objc private func scrolled() {
        guard collectionView?.panGestureRecognizer.state == .began else { return }
        close(animated: true)
    }

    @objc private func dismissed() {
        close(animated: true)
    }

    private func perform(_ action: UIContextualAction, from button: UIView) {
        action.handler(action, button) { _ in }
        close(animated: true)
    }

    /// A list cell lays out its own content view, a swipe's offset included,
    /// so what slides is what is in it.
    private static func slide(_ cell: UICollectionViewCell, by distance: CGFloat) {
        let transform = distance == 0 ? .identity : CGAffineTransform(translationX: distance, y: 0)
        for view in cell.contentView.subviews {
            view.transform = transform
        }
    }

    /// The content `offset` aside, and the actions in the room it leaves.
    private func move(_ swiped: Swiped, to offset: CGFloat) {
        swiped.offset = offset
        let bounds = swiped.cell.bounds
        Self.slide(swiped.cell, by: -offset * trailing)
        swiped.tray.frame = CGRect(
            x: trailing > 0 ? bounds.width - offset : 0,
            y: 0,
            width: offset,
            height: bounds.height
        )
        swiped.tray.layoutIfNeeded()
    }
}

/// The actions of a grid cell's swipe, side by side in the room the content
/// left them, drawn as the system draws a list row's that have a symbol and
/// no title: a circle of the action's colour, growing in as the content
/// goes aside.
final class GridSwipeTray: UIView {
    /// An action's circle once the cell is open, at most: a short row
    /// keeps `margin` above and below it.
    private static let diameter: CGFloat = 54
    /// Between the circles, and after the last of them.
    private static let gap: CGFloat = 11
    /// Above and below a circle in a row too short for `diameter`.
    private static let margin: CGFloat = 6

    private let buttons: [UIButton]
    /// `buttons` from the leading edge across, as they are laid out.
    private let ordered: [UIButton]

    /// How far the content goes aside for every action to show in full.
    var fullWidth: CGFloat {
        CGFloat(buttons.count) * (Self.diameter + Self.gap) + Self.gap
    }

    /// - Parameter actions: from the trailing edge in, as a configuration
    ///   lists them.
    init(actions: [UIContextualAction], perform: @escaping (UIContextualAction, UIView) -> Void) {
        buttons = actions.map { action in
            let button = UIButton(type: .custom)
            button.backgroundColor = action.backgroundColor
            button.tintColor = .swipeGlyph
            button.setImage(
                action.image?.withRenderingMode(.alwaysTemplate)
                    .applyingSymbolConfiguration(.init(font: .type(.title))),
                for: .normal
            )
            button.accessibilityLabel = action.accessibilityLabel ?? action.title
            button.clipsToBounds = true
            button.addAction(UIAction { [weak button] _ in
                guard let button else { return }
                perform(action, button)
            }, for: .touchUpInside)
            return button
        }
        // the first action is nearest the trailing edge
        let rightToLeft = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
        ordered = rightToLeft ? buttons : buttons.reversed()
        super.init(frame: .zero)
        clipsToBounds = true
        ordered.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !buttons.isEmpty else { return }
        // each action has its share of the room; its circle fills the
        // share, short of the gap, and never grows past `diameter`
        let slot = max(bounds.width - Self.gap, 0) / CGFloat(buttons.count)
        let side = min(max(slot - Self.gap, 0), Self.diameter, max(bounds.height - Self.margin * 2, 0))
        for (index, button) in ordered.enumerated() {
            let center = CGPoint(x: CGFloat(index) * slot + slot / 2, y: bounds.midY)
            button.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            button.center = center
            button.layer.cornerRadius = side / 2
            // a circle too small for its symbol shows none of it
            button.imageView?.alpha = side > Self.diameter / 2 ? 1 : 0
        }
    }
}
