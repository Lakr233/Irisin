//
//  PaymentManager.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/25.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import AuthenticationServices
import Dog
import SPIndicator
import UIKit

/// Sileo-style payment endpoints: sign in through the web, then ask the
/// vendor about accounts, purchases and download links. Lives on the main
/// actor because every entry point ends in a sheet or a notification; the
/// network calls suspend instead of blocking.
final class PaymentManager {
    static let shared = PaymentManager()

    private init() {}

    // MARK: - STRUCT

    nonisolated struct UserTokenInfo: Sendable {
        let token: String
        let secret: String
    }

    nonisolated struct UserAccount: Sendable {
        let item: [String]
    }

    nonisolated struct PackageInfo: Sendable {
        let purchased: Bool?
        let available: Bool?
    }

    // MARK: - FUNCTION

    private func postNotification() {
        NotificationCenter.default.post(name: .RepositoryPaymentChanged, object: nil)
    }

    func startUserAuthenticate(
        window: UIWindow,
        controller: UIViewController?,
        repoUrl: URL,
        completionCallback: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repoUrl),
            let endpoint = repo.endpoint
        else {
            completionCallback()
            return
        }
        if obtainStoredTokenInfomation(for: repo) != nil {
            Dog.shared.join(self, "user already signed in \(repo.url.absoluteString)")
            completionCallback()
            return
        }
        let authUrl = endpoint
            .appendingPathComponent("authenticate")
            // follow the order in a strict way
            .appendingQueryParameters(["udid": DeviceInfo.current.udid])
            .appendingQueryParameters(["model": DeviceInfo.current.machine])

        let item = ASWebAuthenticationSessionWindowProvider(window: window)
        let session = ASWebAuthenticationSession(url: authUrl, callbackURLScheme: "sileo") { url, err in
            Task { @MainActor in
                defer { completionCallback() }
                _ = item // avoid dealloc
                if let err, (err as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    // the user closed the sheet; nothing failed
                    return
                }
                guard let url, err == nil else {
                    SPIndicator.present(
                        title: String(localized: "Sign-in failed"),
                        message: String(localized: "Try again."),
                        preset: .error,
                        haptic: .error,
                        from: .top,
                        completion: nil
                    )
                    return
                }

                guard let param = url.queryParameters,
                      let token = param["token"],
                      let secret = param["payment_secret"]
                else {
                    controller?.presentNotice(title: "Sign-In Failed", message: "Sign-in did not complete. Try again.")
                    return
                }
                Dog.shared.join(
                    self,
                    "authentication completed with token \(token.count) long for \(repo.url.absoluteString)"
                )
                self.recordUserInformation(for: repo, token: token, secret: secret)
            }
        }
        session.presentationContextProvider = item
        session.start()
    }

    /// The two Keychain account names a repository's sign-in is stored under.
    /// These are persisted `kSecAttrAccount` values: changing either spelling
    /// signs every existing user out.
    private nonisolated static func keychainKeys(for repo: Repository) -> (token: String, secret: String) {
        (
            token: "KeyChain.[\(repo.url.absoluteString)].token",
            secret: "KeyChain.[\(repo.url.absoluteString)].secert"
        )
    }

    func recordUserInformation(for repo: Repository, token: String, secret: String) {
        let keys = Self.keychainKeys(for: repo)
        // A failed Keychain write means the user looks signed in until the
        // next launch reads nothing back, so say so at the moment it happens.
        for (key, data) in [(keys.token, Data(token.utf8)), (keys.secret, Data(secret.utf8))] {
            let status = KeyChain.save(key: key, data: data)
            if status != errSecSuccess {
                Dog.shared.join(self, "keychain refused to store \(key): OSStatus \(status)", level: .error)
            }
        }
        postNotification()
    }

    nonisolated func obtainStoredTokenInfomation(for repo: Repository) -> UserTokenInfo? {
        let keys = Self.keychainKeys(for: repo)
        guard let tokenRaw = KeyChain.load(key: keys.token),
              let token = String(data: tokenRaw, encoding: .utf8),
              let secretRaw = KeyChain.load(key: keys.secret),
              let secret = String(data: secretRaw, encoding: .utf8)
        else {
            return nil
        }
        return .init(token: token, secret: secret)
    }

    func deleteSignInRecord(for repoUrl: URL) {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repoUrl)
        else {
            return
        }
        guard let info = obtainStoredTokenInfomation(for: repo) else { return }
        let keys = Self.keychainKeys(for: repo)
        KeyChain.delete(key: keys.token)
        KeyChain.delete(key: keys.secret)
        postNotification()
        guard let endpoint = repo.endpoint?.appendingPathComponent("sign_out") else {
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = Self.json([
            "token": info.token,
            "udid": DeviceInfo.current.udid, // otherwise it will return remote failed
            "device": DeviceInfo.current.machine,
        ])
        let repoName = repo.url.absoluteString
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let str = String(data: data, encoding: .utf8)
            else {
                Dog.shared.join("PaymentManager", "signing out on \(repoName) got no readable reply", level: .warning)
                return
            }
            Dog.shared.join("PaymentManager", "signing out on \(repoName) replied with \(str)")
        }
    }

    func obtainUserAccountInfo(for repo: URL) async -> UserAccount? {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repo),
            let endpoint = repo.endpoint,
            let userInfo = obtainStoredTokenInfomation(for: repo)
        else {
            return nil
        }

        let request = Self.jsonRequest(endpoint.appendingPathComponent("user_info"), token: userInfo.token)
        guard let json = await Self.jsonReply(for: request) else { return nil }
        return UserAccount(item: json["items"] as? [String] ?? [])
    }

    func obtainPackageInfo(for repo: URL, withPackageIdentity identity: String) async -> PackageInfo? {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repo),
            let endpoint = repo
            .endpoint?
            .appendingPathComponent("package")
            .appendingPathComponent(identity)
            .appendingPathComponent("info"),
            let userInfo = obtainStoredTokenInfomation(for: repo)
        else {
            return nil
        }

        let request = Self.jsonRequest(endpoint, token: userInfo.token)
        guard let json = await Self.jsonReply(for: request) else { return nil }
        return PackageInfo(
            purchased: json["purchased"] as? Bool,
            available: json["available"] as? Bool
        )
    }

    func initPurchase(
        for repo: URL,
        withPackageIdentity identity: String,
        window: UIWindow
    ) async {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repo),
            let endpoint = repo
            .endpoint?
            .appendingPathComponent("package")
            .appendingPathComponent(identity)
            .appendingPathComponent("purchase"),
            let userInfo = obtainStoredTokenInfomation(for: repo)
        else {
            return
        }

        let request = Self.jsonRequest(endpoint, token: userInfo.token, payload: [
            "payment_secret": userInfo.secret,
            "architecture": EnvironmentDetector.architecture,
        ])
        // status 0 is a purchase that already went through: no page to open
        guard let json = await Self.jsonReply(for: request),
              let status = json["status"] as? Int,
              status != 0,
              let action = json["url"] as? String,
              let url = URL(string: action)
        else {
            return
        }
        let foo = ASWebAuthenticationSessionWindowProvider(window: window)
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "sileo") { _, _ in
            _ = foo
        }
        session.presentationContextProvider = foo
        session.start()
    }

    /// The paid link for the build the resolver chose, not for the build a
    /// repository would pick for this device: a package installed in
    /// compatibility mode is another architecture's, and Havoc answers an
    /// architecture it has no package for with whichever it does have —
    /// the file then fails the hash the index published for ours.
    func queryDownloadLink(withPackage package: Package) async -> URL? {
        guard let represent = package.repoRef,
              let repo = RepositoryCenter
              .default
              .obtainImmutableRepository(withUrl: represent),
              let endpoint = repo
              .endpoint?
              .appendingPathComponent("package")
              .appendingPathComponent(package.identity)
              .appendingPathComponent("authorize_download"),
              let userInfo = obtainStoredTokenInfomation(for: repo)
        else {
            return nil
        }

        let request = Self.jsonRequest(endpoint, token: userInfo.token, payload: [
            "version": package.latestVersion,
            "repo": represent.absoluteString,
            "payment_secret": userInfo.secret,
            "architecture": package.architectures.first { $0 != "all" } ?? EnvironmentDetector.architecture,
        ])
        guard let json = await Self.jsonReply(for: request),
              let value = json["url"] as? String,
              let url = URL(string: value)
        else { return nil }
        return url
    }

    // MARK: - WIRE

    private nonisolated static func json(_ payload: [String: String?]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: payload.compactMapValues(\.self),
            options: .fragmentsAllowed
        )) ?? Data()
    }

    /// A signed-in call: the account token and the device go with every payload.
    private static func jsonRequest(_ endpoint: URL, token: String, payload: [String: String?] = [:]) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json(payload.merging([
            "token": token,
            "udid": DeviceInfo.current.udid, // otherwise it will return remote failed
            "device": DeviceInfo.current.machine,
        ]) { current, _ in current })
        return request
    }

    /// Every paid-repository call goes through here, so this is the one place
    /// a vendor's endpoint can be seen failing. Each branch says which one it
    /// was: "the purchase did nothing" is otherwise indistinguishable from a
    /// timeout, a 500 and a vendor answering with HTML.
    private nonisolated static func jsonReply(for request: URLRequest) async -> [String: Any]? {
        let endpoint = request.url?.absoluteString ?? "unknown endpoint"
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                Dog.shared.join("PaymentManager", "\(endpoint) answered HTTP \(http.statusCode)", level: .error)
                return nil
            }
            data = body
        } catch {
            Dog.shared.join("PaymentManager", "\(endpoint) failed: \(error.localizedDescription)", level: .error)
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any]
        else {
            Dog.shared.join(
                "PaymentManager",
                "\(endpoint) did not answer with a JSON object, \(data.count) bytes",
                level: .error
            )
            return nil
        }
        return json
    }
}

// MARK: - HELPER

private class ASWebAuthenticationSessionWindowProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let windowCache: UIWindow
    required init(window: UIWindow) {
        windowCache = window
        super.init()
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        windowCache
    }
}

private nonisolated enum KeyChain {
    static func save(key: String, data: Data) -> OSStatus {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ] as [String: Any]

        SecItemDelete(query as CFDictionary)

        return SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(key: String) {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key,
        ] as [String: Any]
        SecItemDelete(query as CFDictionary)
    }

    static func load(key: String) -> Data? {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as [String: Any]

        var dataTypeRef: AnyObject?

        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess else { return nil }
        return dataTypeRef as? Data
    }
}
