//
//  PackageController+Depiction.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import PackageDepiction
import UIKit

extension PackageController {
    /// The depiction json for a package that named none, written here out of
    /// what dpkg already told us. Every package has a page; a repository that
    /// supplied no `SileoDepiction:` only means this app writes it instead.
    func localDepictionJSON() -> [String: Any] {
        let package = describedPackage
        var targetJsonData: [String: Any] = [:]
        targetJsonData["minVersion"] = "0.1"
        targetJsonData["class"] = "DepictionTabView"

        var tabRoot: [String: Any] = ["tabname": String(localized: "Details"),
                                      "class": "DepictionStackView"]
        var tabViewsArray: [[String: Any]] = []

        if let descMarkDown = package.latestMetadata?["description"] {
            var newmd: [String: Any] = [:]
            newmd["class"] = "DepictionMarkdownView"
            newmd["useSpacing"] = "true"
            newmd["markdown"] = descMarkDown
            tabViewsArray.append(newmd)
            tabViewsArray.append(["class": "DepictionSeparatorView"])
        }

        for (title, key) in [
            (String(localized: "Version"), "version"),
            (String(localized: "Section"), "section"),
            (String(localized: "Author"), "author"),
            (String(localized: "Maintainer"), "maintainer"),
        ] {
            var row: [String: Any] = ["title": title, "class": "DepictionTableTextView"]
            var field = package.latestMetadata?[key] ?? String(localized: "Unknown")
            if key == "section" {
                field = field.sectionDisplayName
            }
            (row["text"], row["action"]) = Self.contact(field)
            tabViewsArray.append(row)
        }

        tabRoot["views"] = tabViewsArray
        targetJsonData["tabs"] = [tabRoot]
        return targetJsonData
    }

    /// A dpkg `Author:` or `Maintainer:` field as the row shows it: the name
    /// with a `mailto:` behind it when the field is "Name <address>" (or the
    /// page itself for "Name <https://...>"), the address itself when that is
    /// all there is, the text untouched otherwise.
    /// The address is dropped from the text because it does not fit.
    nonisolated static func contact(_ field: String) -> (text: String, action: String?) {
        let address = #/[^<>\s@]+@[^<>\s@]+/#
        if let match = field.wholeMatch(of: #/\s*(?<name>.*?)\s*<(?<address>[^<>\s@]+@[^<>\s@]+)>\s*/#) {
            let name = String(match.name)
            return (name.isEmpty ? String(match.address) : name, "mailto:\(match.address)")
        }
        if let match = field.wholeMatch(of: #/\s*(?<name>.*?)\s*<(?<link>https?://[^<>\s]+)>\s*/#) {
            let name = String(match.name)
            return (name.isEmpty ? String(match.link) : name, String(match.link))
        }
        if let match = field.trimmingCharacters(in: .whitespaces).wholeMatch(of: address) {
            return (String(match.output), "mailto:\(match.output)")
        }
        return (field, nil)
    }

    /// The page shown while the remote depiction is still on its way.
    func defaultDepiction() -> UIView {
        render(localDepictionJSON(), tintColor: .buttonNormal) ?? UIView()
    }

    /// Fetches the package's own depiction and puts the rendered page on show.
    ///
    /// A package that named no depiction, and one whose depiction cannot be
    /// read, land in the same place: the json written locally. The difference
    /// between the two is a line in the log, not a different page.
    func downloadDepictionIfAvailable() {
        let package = describedPackage
        Task { [weak self] in
            guard let self else { return }

            var json: [String: Any]?
            if let url = PackageCenter.default.depictionURL(of: package) {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let remote = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    json = remote
                } else {
                    Dog.shared.join(
                        "Depiction",
                        "could not read the json depiction for \(package.identity) at \(url.absoluteString), writing one locally",
                        level: .error
                    )
                }
            } else {
                Dog.shared.join(
                    "Depiction",
                    "\(package.identity) named no depiction, writing one locally",
                    level: .verbose
                )
            }

            let depiction = json ?? localDepictionJSON()

            // a version without a photo does not keep the last one's
            bannerArtwork.load((depiction["headerImage"] as? String).flatMap(URL.init(string:)))

            let color = UIColor(css: depiction["tintColor"] as? String) ?? .buttonNormal
            bannerPackageView.buttonBackground.backgroundColor = color

            guard let view = render(depiction, tintColor: color) else {
                Dog.shared.join(
                    "Depiction",
                    "the depiction for \(package.identity) named a view class this build cannot render",
                    level: .warning
                )
                return
            }
            depictionView = view
        }
    }

    /// The one renderer both paths go through. Nothing at the root is
    /// actionable: that flag is what a button hands the view it wraps, so
    /// a label inside one wears the tint. Set here, every label did.
    private func render(_ json: [String: Any], tintColor: UIColor) -> UIView? {
        let proxy = PackageControllerProxy()
        proxy.parentController = self
        let view = DepictionBaseView.view(
            dictionary: json,
            viewController: proxy,
            tintColor: tintColor,
            isActionable: false
        )
        depictionIsPartial = !proxy.unrenderedClasses.isEmpty
        if depictionIsPartial {
            Dog.shared.join(
                "Depiction",
                "the depiction for \(packageObject.identity) named views this build cannot render: \(proxy.unrenderedClasses.joined(separator: ", "))",
                level: .warning
            )
        }
        return view
    }
}
