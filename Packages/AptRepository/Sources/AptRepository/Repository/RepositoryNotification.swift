//
//  RepositoryNotification.swift
//
//
//  Created by Lakr Aream on 2021/8/10.
//

import Foundation

public extension RepositoryCenter {
    /// Posted as `metadataUpdate`'s object, on the main actor. `Progress` is
    /// the one the center keeps for the repository and is only ever mutated
    /// there, hence the unchecked conformance.
    struct UpdateNotification: @unchecked Sendable {
        public let repository: URL
        public let progress: Progress?
        public let complete: Bool
        public let success: Bool
        public let queueLeft: Int
    }
}
