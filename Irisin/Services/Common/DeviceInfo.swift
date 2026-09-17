//
//  DeviceInfo.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/25.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import Foundation

/// The identity the app presents to repositories and vendors.
final class DeviceInfo {
    static let current = DeviceInfo()

    let udid: String

    var machine: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }

    var firmware: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            text += ".\(version.patchVersion)"
        }
        return text
    }

    private init() {
        typealias MGCopyAnswerAddr = @convention(c) (CFString) -> CFString
        var udid = ""
        if let lookup = dlsym(dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_GLOBAL | RTLD_LAZY), "MGCopyAnswer") {
            let MGCopyAnswer = unsafeBitCast(lookup, to: MGCopyAnswerAddr.self)
            udid = MGCopyAnswer("UniqueDeviceID" as CFString) as String
            Dog.shared.join("MGCopyAnswer", "UniqueDeviceID returned udid \(udid.count) long", level: .info)
        }
        if udid.isEmpty {
            let build = String((0 ..< 40).map { _ in "0123456789abcdef".randomElement()! })
            Dog.shared.join(
                "MGCopyAnswer",
                "UniqueDeviceID lookup failed, using \(build) for requests",
                level: .warning
            )
            udid = build
        }
        self.udid = udid
    }

    func applyNetworkingHeaders() {
        RepositoryCenter.default.networkingHeaders = [
            "X-Machine": machine,
            "X-Unique-ID": udid,
            "X-Firmware": firmware,
        ]
    }
}
