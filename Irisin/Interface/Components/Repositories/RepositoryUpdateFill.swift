//
//  RepositoryUpdateFill.swift
//  Irisin
//

import AptRepository
import Combine
import SnapKit
import Then
import UIKit

/// A repository's update progress, drawn as a tint behind the whole row
/// that widens from the leading edge as the download moves. The cell that
/// hosts a `RepositoryRow` lays it out behind the row and hands it the URL.
final class RepositoryUpdateFill: UIView {
    private var subscriptions = Set<AnyCancellable>()

    private let fill = UIView().then {
        $0.backgroundColor = .buttonNormal.withAlphaComponent(0.1)
        $0.alpha = 0
    }

    private var fillWidth: Constraint?

    /// Nil for a row that is not a repository, which hides the tint at once.
    var url: URL? {
        didSet { update(animated: false) }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // progress drawn behind the row; the row itself says what it is
        accessibilityElementsHidden = true
        addSubview(fill)
        fill.snp.makeConstraints { x in
            x.leading.top.bottom.equalToSuperview()
            fillWidth = x.width.equalToSuperview().multipliedBy(0.001).constraint
        }
        // Every repository's download ticks through metadataUpdate: a row
        // moves for its own, and for the queue, which names none.
        Publishers.MergeMany([RepositoryCenter.metadataUpdate, .RepositoryQueueChanged].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self else { return }
            if let update = notification.object as? RepositoryCenter.UpdateNotification,
               update.repository != url
            {
                return
            }
            update(animated: true)
        }
        .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func update(animated: Bool) {
        guard let url else {
            setFill(fraction: 0, visible: false, animated: false)
            return
        }
        switch RepositoryCenter.default.updateState(withUrl: url) {
        case .idle:
            setFill(fraction: 1, visible: false, animated: animated)
        case .pending:
            setFill(fraction: 0, visible: true, animated: animated)
        case let .updating(fraction):
            setFill(fraction: fraction, visible: true, animated: animated)
        }
    }

    private func setFill(fraction: Double, visible: Bool, animated: Bool) {
        fillWidth?.deactivate()
        fill.snp.makeConstraints { x in
            fillWidth = x.width.equalToSuperview().multipliedBy(max(fraction, 0.001)).constraint
        }
        let changes = {
            self.fill.alpha = visible ? 1 : 0
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animateProgress(changes)
        } else {
            changes()
        }
    }
}
