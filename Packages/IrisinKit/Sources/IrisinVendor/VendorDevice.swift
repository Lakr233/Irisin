import Darwin
import Foundation

/// What a vendor is told about the device: the identifier purchases are
/// bound to, the model and the system version.
public struct VendorDevice: Sendable, Equatable {
    public let udid: String
    public let machine: String
    public let firmware: String

    public init(udid: String, machine: String, firmware: String) {
        self.udid = udid
        self.machine = machine
        self.firmware = firmware
    }

    /// MobileGestalt's `UniqueDeviceID`; nil where it does not answer (a
    /// Mac, a simulator), and the caller decides what to send instead.
    public static func uniqueDeviceIdentifier() -> String? {
        typealias Copy = @convention(c) (CFString) -> Unmanaged<CFString>?
        guard let library = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_GLOBAL | RTLD_LAZY),
              let symbol = dlsym(library, "MGCopyAnswer")
        else { return nil }
        let copy = unsafeBitCast(symbol, to: Copy.self)
        guard let answer = copy("UniqueDeviceID" as CFString)?.takeRetainedValue() as String?,
              !answer.isEmpty
        else { return nil }
        return answer
    }

    /// `uname`'s machine, such as `iPhone18,4`.
    public static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `26.6.2`, or `27.0` with no patch version.
    public static var firmware: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            text += ".\(version.patchVersion)"
        }
        return text
    }
}
