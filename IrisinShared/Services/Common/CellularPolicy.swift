//
//  CellularPolicy.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// Lifts the cellular data restriction for this bundle through CoreTelephony's
/// private server connection, which the `com.apple.CommCenter.fine-grained`
/// entitlement lets an unsandboxed app do. Resolved at runtime so nothing is
/// linked against a private symbol.
nonisolated enum CellularPolicy {
    static func allowForThisApplication() {
        #if targetEnvironment(simulator)
            return
        #else
            typealias Create = @convention(c) (
                CFAllocator?,
                UnsafeMutableRawPointer?,
                UnsafeMutableRawPointer?
            ) -> Unmanaged<CFTypeRef>?
            typealias SetPolicy = @convention(c) (CFTypeRef, CFString, CFDictionary) -> Int64
            guard let bundleIdentifier = Bundle.main.bundleIdentifier,
                  let handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW),
                  let createSymbol = dlsym(handle, "_CTServerConnectionCreate"),
                  let setSymbol = dlsym(handle, "_CTServerConnectionSetCellularUsagePolicy") else { return }
            let create = unsafeBitCast(createSymbol, to: Create.self)
            let setPolicy = unsafeBitCast(setSymbol, to: SetPolicy.self)
            guard let connection = create(kCFAllocatorDefault, nil, nil)?.takeRetainedValue() else { return }
            _ = setPolicy(connection, bundleIdentifier as CFString, [
                "kCTCellularDataUsagePolicy": "kCTCellularDataUsagePolicyAlwaysAllow",
                "kCTWiFiDataUsagePolicy": "kCTCellularDataUsagePolicyAlwaysAllow",
            ] as CFDictionary)
        #endif
    }
}
