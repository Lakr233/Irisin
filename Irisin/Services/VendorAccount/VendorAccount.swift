//
//  VendorAccount.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/25.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import AuthenticationServices
import Dog
import IrisinVendor
import SPIndicator
import UIKit

/// Sileo-style payment endpoints: sign in through the web, then ask the
/// vendor about accounts, purchases and download links. Lives on the main
/// actor because every entry point ends in a sheet or a notification; the
/// network calls suspend instead of blocking. The Keychain names and every
/// request are `IrisinVendor`'s, shared with the command line.
final class VendorAccount {
    static let shared = VendorAccount()

    private init() {}

    // MARK: - STRUCT

    typealias UserToken = VendorCredentials
    typealias PurchaseStatus = VendorService.PurchaseStatus

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
        if storedToken(for: repo) != nil {
            Dog.shared.join(self, "user already signed in \(repo.url.absoluteString)")
            completionCallback()
            return
        }
        let authUrl = VendorService.signInURL(endpoint: endpoint, device: DeviceIdentity.vendorDevice)

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

    func recordUserInformation(for repo: Repository, token: String, secret: String) {
        // A failed Keychain write means the user looks signed in until the
        // next launch reads nothing back, so say so at the moment it happens.
        let refused = VendorKeychain.store(VendorCredentials(token: token, secret: secret), for: repo.url)
        for (account, status) in refused {
            Dog.shared.join(self, "keychain refused to store \(account): OSStatus \(status)", level: .error)
        }
        postNotification()
    }

    nonisolated func storedToken(for repo: Repository) -> UserToken? {
        VendorKeychain.credentials(for: repo.url)
    }

    func deleteSignInRecord(for repoUrl: URL) {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repoUrl)
        else {
            return
        }
        guard let info = storedToken(for: repo) else { return }
        VendorKeychain.remove(for: repo.url)
        postNotification()
        guard let endpoint = repo.endpoint else {
            return
        }
        let repoName = repo.url.absoluteString
        let device = DeviceIdentity.vendorDevice
        Task {
            guard let str = await VendorService.signOut(endpoint: endpoint, credentials: info, device: device)
            else {
                Dog.shared.join("VendorAccount", "signing out on \(repoName) got no readable reply", level: .warning)
                return
            }
            Dog.shared.join("VendorAccount", "signing out on \(repoName) replied with \(str)")
        }
    }

    /// The identities of the packages this account has bought, or nil when the
    /// vendor did not answer.
    func purchasedIdentities(for repo: URL) async -> [String]? {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repo),
            let endpoint = repo.endpoint,
            let userInfo = storedToken(for: repo)
        else {
            return nil
        }
        return await Self.logged(endpoint.appendingPathComponent("user_info")) { () async throws(VendorService.Failure) in
            try await VendorService.purchasedIdentities(
                endpoint: endpoint,
                credentials: userInfo,
                device: DeviceIdentity.vendorDevice
            )
        }
    }

    func purchaseStatus(for repo: URL, withPackageIdentity identity: String) async -> PurchaseStatus? {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repo),
            let endpoint = repo.endpoint,
            let userInfo = storedToken(for: repo)
        else {
            return nil
        }
        return await Self.logged(VendorService.package(identity, "info", at: endpoint)) { () async throws(VendorService.Failure) in
            try await VendorService.purchaseStatus(
                of: identity,
                endpoint: endpoint,
                credentials: userInfo,
                device: DeviceIdentity.vendorDevice
            )
        }
    }

    func initPurchase(
        for repo: URL,
        withPackageIdentity identity: String,
        window: UIWindow
    ) async {
        guard let repo = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: repo),
            let endpoint = repo.endpoint,
            let userInfo = storedToken(for: repo)
        else {
            return
        }
        // nil as well for a purchase that already went through: no page to open
        let page = await Self.logged(VendorService.package(identity, "purchase", at: endpoint)) { () async throws(VendorService.Failure) in
            try await VendorService.purchasePage(
                for: identity,
                architecture: PackagedArchitecture.architecture,
                endpoint: endpoint,
                credentials: userInfo,
                device: DeviceIdentity.vendorDevice
            )
        }
        guard let url = page ?? nil else {
            return
        }
        let foo = ASWebAuthenticationSessionWindowProvider(window: window)
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "sileo") { _, _ in
            _ = foo
        }
        session.presentationContextProvider = foo
        session.start()
    }

    /// The paid link for the build the resolver chose, named by its own
    /// architecture: Havoc answers an architecture it has no package for
    /// with whichever it does have — the file then fails the hash the index
    /// published for ours.
    func queryDownloadLink(withPackage package: Package) async -> URL? {
        guard let represent = package.repoRef,
              let repo = RepositoryCenter
              .default
              .obtainImmutableRepository(withUrl: represent),
              let endpoint = repo.endpoint,
              let userInfo = storedToken(for: repo)
        else {
            return nil
        }
        let link = await Self.logged(VendorService.package(package.identity, "authorize_download", at: endpoint)) {
            () async throws(VendorService.Failure) in
            try await VendorService.downloadLink(
                for: package.identity,
                version: package.latestVersion,
                architecture: package.architectures.first { $0 != "all" } ?? PackagedArchitecture.architecture,
                repository: represent,
                endpoint: endpoint,
                credentials: userInfo,
                device: DeviceIdentity.vendorDevice
            )
        }
        return link ?? nil
    }

    /// Every paid-repository call goes through here, so this is the one place
    /// a vendor's endpoint can be seen failing. Each line says which way it
    /// failed: "the purchase did nothing" is otherwise indistinguishable from
    /// a timeout, a 500 and a vendor answering with HTML.
    private static func logged<Value>(
        _ endpoint: URL,
        _ call: () async throws(VendorService.Failure) -> Value
    ) async -> Value? {
        do {
            return try await call()
        } catch {
            Dog.shared.join("VendorAccount", "\(endpoint.absoluteString) \(error)", level: .error)
            return nil
        }
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
