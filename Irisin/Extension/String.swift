//
//  String.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import CommonCrypto
import Foundation

nonisolated extension String {
    static func sha1From(data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        let hexBytes = digest.map { String(format: "%02hhx", $0) }
        return hexBytes.joined()
    }

    static func sha256From(data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        let hexBytes = digest.map { String(format: "%02hhx", $0) }
        return hexBytes.joined()
    }

    /// The text of a value a caller spelled out as a literal, which is where
    /// its key is extracted. `String(localized:)` on a parameter makes the
    /// localization sync warn that it skipped a key it was never meant to
    /// find there; the unapplied initializer is the same call, unremarked.
    init(resolving value: String.LocalizationValue) {
        let resolve = String.init(localized:table:bundle:locale:comment:)
        self = resolve(value, nil, nil, .current, nil)
    }

    /// A dpkg section as the interface spells it: `Terminal_Support` reads
    /// `Terminal Support`. A filter keeps matching on the raw value.
    var sectionDisplayName: String {
        replacingOccurrences(of: "_", with: " ")
    }
}
