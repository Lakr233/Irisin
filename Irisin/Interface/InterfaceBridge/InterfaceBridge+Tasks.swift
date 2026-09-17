//
//  InterfaceBridge+Tasks.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension InterfaceBridge {
    /// Walks the whole installed list, off the main actor on a copy. Two index
    /// lookups per package and the list runs into the thousands, so a caller
    /// asks once and reads the answer per row.
    static func identitiesWithUpdate() async -> Set<String> {
        await identities(withUpdateIn: PackageCenter.default.index)
    }

    static func availableUpdateCount() async -> Int {
        await identitiesWithUpdate().count
    }

    @concurrent
    private nonisolated static func identities(withUpdateIn index: PackageIndex) async -> Set<String> {
        Set(index.updateCandidates().map(\.installed.identity))
    }
}
