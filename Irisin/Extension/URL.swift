//
//  URL.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/28.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Foundation

nonisolated extension URL {
    /// returns the total allocated size of the directory's immediate contents
    func directoryTotalAllocatedSize() throws -> Int {
        try FileManager
            .default
            .contentsOfDirectory(at: self, includingPropertiesForKeys: nil)
            .reduce(0) {
                try (
                    $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                        .totalFileAllocatedSize ?? 0
                ) + $0
            }
    }

    /// `self` with `parameters` added to the query.
    func appendingQueryParameters(_ parameters: [String: String]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.queryItems = (components.queryItems ?? [])
            + parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url ?? self
    }

    /// The query as a dictionary, nil when there is no query.
    var queryParameters: [String: String]? {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
}
