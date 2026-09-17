//
//  MD5.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/24.
//

import CryptoKit
import Foundation

/// Repository metadata still hashes package files with MD5, so verifying a
/// download means computing one. Never use this for anything but that.
nonisolated enum MD5 {
    static func hex(of data: Data) -> String {
        Insecure.MD5
            .hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func hex(of string: String) -> String {
        hex(of: Data(string.utf8))
    }
}
