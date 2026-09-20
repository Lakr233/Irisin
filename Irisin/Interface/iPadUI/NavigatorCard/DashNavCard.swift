//
//  DashNavCard.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import UIKit

class DashNavCard: UIView {
    private var subscriptions = Set<AnyCancellable>()
    private var updateCountTask: Task<Void, Never>?

    private let dashCard = DashNavCardInstance(
        text: String(localized: "Dashboard"),
        symbol: "square.grid.2x2.fill",
        defaultSelected: true
    )

    private let settCard = DashNavCardInstance(
        text: String(localized: "Settings"),
        symbol: "gearshape.fill",
        defaultSelected: false
    )

    private let queueCard = DashNavCardInstance(
        text: String(localized: "Queue"),
        symbol: "tray.full.fill",
        defaultSelected: false
    )

    private let instCard = DashNavCardInstance(
        text: String(localized: "Installed"),
        symbol: "shippingbox.fill",
        defaultSelected: false
    )

    /// A card was tapped: the detail column shows its page.
    var onSelect: ((DetailPage) -> Void)?

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    required init() {
        super.init(frame: CGRect())

        addSubview(dashCard)
        dashCard.cardClosure = { [weak self] in self?.open(.dashboard) }
        dashCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.top).offset(8)
            x.leading.equalTo(self.snp.leading)
            x.bottom.equalTo(self.snp.centerY).offset(-8)
            x.trailing.equalTo(self.snp.centerX).offset(-8)
        }

        addSubview(settCard)
        settCard.cardClosure = { [weak self] in self?.open(.settings) }
        settCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.top).offset(8)
            x.leading.equalTo(self.snp.centerX).offset(8)
            x.bottom.equalTo(self.snp.centerY).offset(-8)
            x.trailing.equalTo(self.snp.trailing)
        }

        addSubview(queueCard)
        queueCard.cardClosure = { [weak self] in self?.open(.queue) }
        queueCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.centerY).offset(8)
            x.leading.equalTo(self.snp.leading)
            x.bottom.equalTo(self.snp.bottom).offset(-8)
            x.trailing.equalTo(self.snp.centerX).offset(-8)
        }

        addSubview(instCard)
        instCard.cardClosure = { [weak self] in self?.open(.installed) }
        instCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.centerY).offset(8)
            x.leading.equalTo(self.snp.centerX).offset(8)
            x.bottom.equalTo(self.snp.bottom).offset(-8)
            x.trailing.equalTo(self.snp.trailing)
        }

        NotificationCenter.default.publisher(for: .TaskQueueChanged)
            .receive(on: DispatchQueue.main)
            .map { _ in QueueController.badge }
            .prepend(QueueController.badge)
            .removeDuplicates()
            .sink { [weak self] badge in self?.queueCard.badgeText = badge ?? "" } // empty for animation
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: PackageCenter.packageRecordChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateAvailableUpdateBadge() }
            .store(in: &subscriptions)

        updateAvailableUpdateBadge()
    }

    /// What a tap on a card does.
    func open(_ page: DetailPage) {
        switch page {
        case .dashboard: select(dashCard)
        case .settings: select(settCard)
        case .installed: select(instCard)
        case .queue: select(queueCard)
        }
        onSelect?(page)
    }

    private func select(_ card: DashNavCardInstance) {
        for other in [dashCard, settCard, queueCard, instCard] where other !== card {
            other.deselecte()
        }
        card.select()
    }

    private func updateAvailableUpdateBadge() {
        updateCountTask?.cancel()
        updateCountTask = Task { [weak self] in
            let count = await Self.updateCount(in: PackageCenter.default.index)
            guard !Task.isCancelled, let self else { return }
            instCard.badgeText = count > 0 ? String(count) : "" // empty for animation
        }
    }

    /// A walk of the whole installed list, so it runs off the main actor on
    /// a copy of the index.
    @concurrent
    private nonisolated static func updateCount(in index: PackageIndex) async -> Int {
        index.updateCandidates().count
    }
}
