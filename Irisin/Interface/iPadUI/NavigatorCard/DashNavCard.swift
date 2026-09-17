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

    var notificationToken: String?

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    required init() {
        super.init(frame: CGRect())

        addSubview(dashCard)
        dashCard.cardClosure = { [weak self] in
            self?.selectDash()
            NotificationCenter.default.post(name: .LXMainControllerSwitchDashboard, object: self?.notificationToken)
        }
        dashCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.top).offset(8)
            x.leading.equalTo(self.snp.leading)
            x.bottom.equalTo(self.snp.centerY).offset(-8)
            x.trailing.equalTo(self.snp.centerX).offset(-8)
        }

        addSubview(settCard)
        settCard.cardClosure = { [weak self] in
            self?.selectSetting()
            NotificationCenter.default.post(name: .LXMainControllerSwitchSettings, object: self?.notificationToken)
        }
        settCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.top).offset(8)
            x.leading.equalTo(self.snp.centerX).offset(8)
            x.bottom.equalTo(self.snp.centerY).offset(-8)
            x.trailing.equalTo(self.snp.trailing)
        }

        addSubview(queueCard)
        queueCard.cardClosure = { [weak self] in
            self?.selectQueue()
            NotificationCenter.default.post(name: .LXMainControllerSwitchQueue, object: self?.notificationToken)
        }
        queueCard.snp.makeConstraints { x in
            x.top.equalTo(self.snp.centerY).offset(8)
            x.leading.equalTo(self.snp.leading)
            x.bottom.equalTo(self.snp.bottom).offset(-8)
            x.trailing.equalTo(self.snp.centerX).offset(-8)
        }

        addSubview(instCard)
        instCard.cardClosure = { [weak self] in
            self?.selectInstalled()
            NotificationCenter.default.post(name: .LXMainControllerSwitchInstalled, object: self?.notificationToken)
        }
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

    func selectDash() {
        select(dashCard)
    }

    func selectSetting() {
        select(settCard)
    }

    func selectQueue() {
        select(queueCard)
    }

    func selectInstalled() {
        select(instCard)
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
            let count = await InterfaceBridge.availableUpdateCount()
            guard !Task.isCancelled, let self else { return }
            instCard.badgeText = count > 0 ? String(count) : "" // empty for animation
        }
    }
}
