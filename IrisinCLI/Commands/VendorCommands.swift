import ArgumentParser
import AptRepository
import Foundation
import IrisinVendor

struct Udid: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the device identifier paid repositories are sent.")

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            _ = try Context.load()
            guard let udid = VendorDevice.uniqueDeviceIdentifier() else {
                throw CommandFailure.unavailable("The device did not give its identifier.")
            }
            output.line(udid)
            output.object(["udid": udid, "machine": VendorDevice.machine, "firmware": VendorDevice.firmware])
        }
    }
}

/// Paid repositories: who is signed in, what was bought, and the pages to
/// sign in or buy. The account token and the payment secret are never
/// printed, in text or JSON.
struct Vendor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look up sign-ins and purchases on paid repositories.",
        subcommands: [VendorList.self, VendorLogin.self, VendorPurchases.self, VendorStatus.self, VendorPurchase.self],
        defaultSubcommand: VendorList.self
    )

    static var device: VendorDevice {
        VendorDevice(
            udid: VendorDevice.uniqueDeviceIdentifier() ?? "",
            machine: VendorDevice.machine,
            firmware: VendorDevice.firmware
        )
    }

    /// The paid repository `text` names, by address or by name.
    static func repository(_ text: String, in index: PackageIndex) throws -> (Repository, URL) {
        let paid = index.obtainRepositories().compactMap { repository in repository.endpoint.map { (repository, $0) } }
        let lowered = text.lowercased()
        let match = paid.first { $0.0.url.absoluteString.lowercased() == lowered }
            ?? paid.first { $0.0.url.absoluteString.lowercased().contains(lowered) }
            ?? paid.first { $0.0.nickName.lowercased() == lowered }
        guard let match else {
            throw CommandFailure.refused("No paid repository matches \(text). See irisin-cli vendor list.")
        }
        return match
    }

    /// The paid repository that offers `package`, and the account signed in there.
    static func seller(of package: String, in index: PackageIndex) throws -> (Repository, URL, VendorCredentials) {
        let identity = package.lowercased()
        for (repository, _) in index.obtainPackageSummary(with: identity) {
            guard let record = index.obtainRepositories().first(where: { $0.url == repository }),
                  let endpoint = record.endpoint
            else { continue }
            guard let credentials = VendorKeychain.credentials(for: record.url) else {
                throw CommandFailure.refused("Sign in to \(record.nickName) in Irisin first (Settings › Vendor Accounts).")
            }
            return (record, endpoint, credentials)
        }
        throw CommandFailure.refused("No paid repository offers \(identity).")
    }

    static func failure(_ failure: VendorService.Failure, at endpoint: URL) -> CommandFailure {
        .unavailable("The repository's payment service \(failure) (\(endpoint.host ?? endpoint.absoluteString)).")
    }
}

struct VendorList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List paid repositories and whether you are signed in.")

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (_, index) = try Session.open(options)
            for repository in index.obtainRepositories() where repository.endpoint != nil {
                let signedIn = VendorKeychain.credentials(for: repository.url) != nil
                output.line("\(repository.url.absoluteString)  \(repository.nickName)  \(signedIn ? "signed in" : "not signed in")")
                output.object(["url": repository.url.absoluteString, "name": repository.nickName, "signedIn": signedIn])
            }
        }
    }
}

struct VendorLogin: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Print the page that signs in to a paid repository.",
        discussion: "The page hands the sign-in back to Irisin, so finish it there: Settings › Vendor Accounts."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The repository, by address or name.")
    var repository: String

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (_, index) = try Session.open(options)
            let (record, endpoint) = try Vendor.repository(repository, in: index)
            let url = VendorService.signInURL(endpoint: endpoint, device: Vendor.device)
            output.line("Sign in to \(record.nickName) from Irisin (Settings › Vendor Accounts); it opens this page:")
            output.line(url.absoluteString)
            output.object(["repository": record.url.absoluteString, "loginURL": url.absoluteString])
        }
    }
}

struct VendorPurchases: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "purchases", abstract: "List what the signed-in account bought.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The repository, by address or name.")
    var repository: String

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (_, index) = try Session.open(options)
            let (record, endpoint) = try Vendor.repository(repository, in: index)
            guard let credentials = VendorKeychain.credentials(for: record.url) else {
                throw CommandFailure.refused("Sign in to \(record.nickName) in Irisin first (Settings › Vendor Accounts).")
            }
            let identities: [String]
            do throws(VendorService.Failure) {
                identities = try await VendorService.purchasedIdentities(
                    endpoint: endpoint, credentials: credentials, device: Vendor.device
                )
            } catch {
                throw Vendor.failure(error, at: endpoint)
            }
            for identity in identities.sorted() {
                output.line(identity)
            }
            output.object(["repository": record.url.absoluteString, "purchased": identities.sorted()])
        }
    }
}

struct VendorStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Ask whether a paid package is bought and available.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The package identifier.")
    var package: String

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (_, index) = try Session.open(options)
            let (record, endpoint, credentials) = try Vendor.seller(of: package, in: index)
            let status: VendorService.PurchaseStatus
            do throws(VendorService.Failure) {
                status = try await VendorService.purchaseStatus(
                    of: package.lowercased(), endpoint: endpoint, credentials: credentials, device: Vendor.device
                )
            } catch {
                throw Vendor.failure(error, at: endpoint)
            }
            output.line("\(package.lowercased()) on \(record.nickName): purchased \(status.purchased.map { $0 ? "yes" : "no" } ?? "unknown"), available \(status.available.map { $0 ? "yes" : "no" } ?? "unknown")")
            output.object([
                "package": package.lowercased(), "repository": record.url.absoluteString,
                "purchased": status.purchased ?? NSNull(), "available": status.available ?? NSNull(),
            ])
        }
    }
}

struct VendorPurchase: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "purchase", abstract: "Print the page that buys a paid package.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The package identifier.")
    var package: String

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (context, index) = try Session.open(options)
            let (record, endpoint, credentials) = try Vendor.seller(of: package, in: index)
            let page: URL?
            do throws(VendorService.Failure) {
                page = try await VendorService.purchasePage(
                    for: package.lowercased(), architecture: context.architecture,
                    endpoint: endpoint, credentials: credentials, device: Vendor.device
                )
            } catch {
                throw Vendor.failure(error, at: endpoint)
            }
            if let page {
                output.line("Buy \(package.lowercased()) on \(record.nickName) on this page:")
                output.line(page.absoluteString)
            } else {
                output.line("\(package.lowercased()) is already bought on \(record.nickName).")
            }
            output.object([
                "package": package.lowercased(), "repository": record.url.absoluteString,
                "purchaseURL": page?.absoluteString ?? NSNull(),
            ])
        }
    }
}
