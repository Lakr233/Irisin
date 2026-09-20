//
//  SidebarCards.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import UIKit

class SidebarCards: UIView {
    private var subscriptions = Set<AnyCancellable>()
    private var updateCountTask: Task<Void, Never>?

    private let dashboardCard = SidebarCard(
        text: String(localized: "Dashboard"),
        symbol: "square.grid.2x2.fill",
        defaultSelected: true
    )

    private let settingsCard = SidebarCard(
        text: String(localized: "Settings"),
        symbol: "gearshape.fill",
        defaultSelected: false
    )

    private let queueCard = SidebarCard(
        text: String(localized: "Queue"),
        symbol: "tray.full.fill",
        defaultSelected: false
    )

    private let installedCard = SidebarCard(
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

        addSubview(dashboardCard)
        dashboardCard.cardClosure = { [weak self] in self?.open(.dashboard) }
        dashboardCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.top).offset(8)
            x.leading.equalTo(self.snp.leading)
            x.bottom.equalTo(self.snp.centerY).offset(-8)
            x.trailing.equalTo(self.snp.centerX).offset(-8)
        }

        addSubview(settingsCard)
        settingsCard.cardClosure = { [weak self] in self?.open(.settings) }
        settingsCard.snp.makeConstraints { x in
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

        addSubview(installedCard)
        installedCard.cardClosure = { [weak self] in self?.open(.installed) }
        installedCard.snp.makeConstraints { x in
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
        case .dashboard: select(dashboardCard)
        case .settings: select(settingsCard)
        case .installed: select(installedCard)
        case .queue: select(queueCard)
        }
        onSelect?(page)
    }

    private func select(_ card: SidebarCard) {
        for other in [dashboardCard, settingsCard, queueCard, installedCard] where other !== card {
            other.deselect()
        }
        card.select()
    }

    private func updateAvailableUpdateBadge() {
        updateCountTask?.cancel()
        updateCountTask = Task { [weak self] in
            let count = await Self.updateCount(in: PackageCenter.default.index)
            guard !Task.isCancelled, let self else { return }
            installedCard.badgeText = count > 0 ? String(count) : "" // empty for animation
        }
    }

    /// A walk of the whole installed list, so it runs off the main actor on
    /// a copy of the index.
    @concurrent
    private nonisolated static func updateCount(in index: PackageIndex) async -> Int {
        index.updateCandidates().count
    }
}
