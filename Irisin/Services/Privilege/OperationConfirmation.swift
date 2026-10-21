//
//  OperationConfirmation.swift
//  Irisin
//

import LocalAuthentication
import UIKit

/// The device owner's yes before a change to the system is staged.
///
/// irisind serves mobile only for Irisin's own app, and what stands between
/// mobile and root there is this app's interface: a change the user asked
/// for and, when this is on, confirmed with Face ID, Touch ID, Optic ID or
/// the passcode. Every other client calls as root, which the user grants
/// with `sudo` and a password (`PeerAuthenticator`).
enum OperationConfirmation {
    /// How the owner confirms here, by what the device has set up.
    enum Method {
        case faceID, touchID, opticID, passcode

        /// The name the system's own prompt uses in this language (面容 ID
        /// in Chinese), kept on one line wherever a sentence wraps it.
        var name: String {
            let name = switch self {
            case .faceID: String(localized: "Face ID")
            case .touchID: String(localized: "Touch ID")
            case .opticID: String(localized: "Optic ID")
            case .passcode: String(localized: "Passcode")
            }
            return name.replacingOccurrences(of: " ", with: "\u{00A0}")
        }

        /// Symbols the iOS 15 floor draws; Optic ID's own is iOS 17's.
        var symbol: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID, .passcode: "lock.fill"
            }
        }
    }

    /// On until the user turns it off, in onboarding or in Settings.
    private static let enabledStore = Stored(key: "operation.ownerConfirmation", defaultValue: true)

    static var isEnabled: Bool {
        get { enabledStore.wrappedValue }
        set { enabledStore.wrappedValue = newValue }
    }

    /// nil on a device with no passcode: there is no owner to ask, and the
    /// setting has no row.
    static var method: Method? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        // read after canEvaluatePolicy, which is what fills it in
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default:
            if #available(iOS 17.0, *), context.biometryType == .opticID {
                return .opticID
            }
            return .passcode
        }
    }

    /// True when the change may go ahead: the owner confirmed, the setting
    /// is off, or the device has no passcode to ask for.
    static func confirm() async -> Bool {
        guard isEnabled, method != nil else { return true }
        return await authenticate()
    }

    /// Asks whatever the setting says; turning the setting on or off is
    /// confirmed the same way.
    static func authenticate() async -> Bool {
        let reason = String(localized: "Verify that you own this device to change packages.")
        let context = LAContext()
        let success = await withCheckedContinuation { finished in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                finished.resume(returning: success)
            }
        }
        // a context released while it asks cancels the question
        withExtendedLifetime(context) {}
        return success
    }
}
