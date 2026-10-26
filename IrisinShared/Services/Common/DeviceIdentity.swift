//
//  DeviceIdentity.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/25.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import Foundation
import IrisinVendor

/// The identity the app presents to repositories and vendors.
enum DeviceIdentity {
    /// Asked of MobileGestalt once; a made-up one for the process when it
    /// does not answer.
    static let udid: String = {
        if let udid = VendorDevice.uniqueDeviceIdentifier() {
            Dog.shared.join("MGCopyAnswer", "UniqueDeviceID returned udid \(udid.count) long", level: .info)
            return udid
        }
        let build = String((0 ..< 40).map { _ in "0123456789abcdef".randomElement()! })
        Dog.shared.join(
            "MGCopyAnswer",
            "UniqueDeviceID lookup failed, using \(build) for requests",
            level: .warning
        )
        return build
    }()

    static var machine: String {
        VendorDevice.machine
    }

    static var firmware: String {
        VendorDevice.firmware
    }

    /// What a vendor is told about this device.
    static var vendorDevice: VendorDevice {
        VendorDevice(udid: udid, machine: machine, firmware: firmware)
    }

    static func applyNetworkingHeaders() {
        RepositoryCenter.default.networkingHeaders = [
            "X-Machine": machine,
            "X-Unique-ID": udid,
            "X-Firmware": firmware,
        ]
    }
}
