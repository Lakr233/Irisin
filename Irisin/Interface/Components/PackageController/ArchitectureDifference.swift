//
//  ArchitectureDifference.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/20.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// A package's architecture read against the device's, character by
/// character, the way a diff reads a line: `iphoneos-arm64e` on an
/// `iphoneos-arm64` device has an `e` too many, and the other way round has
/// one missing. Where the two part is what the package page marks.
nonisolated enum ArchitectureDifference {
    enum Run: Equatable {
        /// In both.
        case same(String)
        /// The package's, which the device's does not have: struck through.
        case extra(String)
        /// The device's, which the package's lacks: shown where it belongs.
        case missing(String)
    }

    static func runs(of package: String, against device: String) -> [Run] {
        let package = Array(package), device = Array(device)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in device.difference(from: package) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var runs: [Run] = []
        func append(_ character: Character, _ make: (String) -> Run, joins: (Run) -> String?) {
            if let last = runs.last, let text = joins(last) {
                runs[runs.count - 1] = make(text + String(character))
            } else {
                runs.append(make(String(character)))
            }
        }
        var here = 0, there = 0
        while here < package.count || there < device.count {
            if here < package.count, removed.contains(here) {
                append(package[here], Run.extra) {
                    if case let .extra(text) = $0 {
                        text
                    } else {
                        nil
                    }
                }
                here += 1
            } else if there < device.count, inserted.contains(there) {
                append(device[there], Run.missing) {
                    if case let .missing(text) = $0 {
                        text
                    } else {
                        nil
                    }
                }
                there += 1
            } else if here < package.count {
                append(package[here], Run.same) {
                    if case let .same(text) = $0 {
                        text
                    } else {
                        nil
                    }
                }
                here += 1
                there += 1
            } else {
                break
            }
        }
        return runs
    }
}
