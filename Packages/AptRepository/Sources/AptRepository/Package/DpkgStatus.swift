import Foundation

public enum DpkgStatus {
    /// Keep unpacked/half-configured entries: they are present, but not valid
    /// Pre-Depends witnesses. Residual configuration is not an installed package.
    public static func packages(in data: Data) throws -> [String: Package] {
        // dpkg keeps whatever bytes the control file had; one description
        // in another encoding must not take the installed list with it.
        let text = IndexText.decode(data)
        var result: [String: Package] = [:]
        for paragraph in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            guard !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let fields = try? DebianControl.parse(paragraph),
                  let name = fields["package"], let status = fields["status"]
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let words = status.split(separator: " ")
            guard words.count == 3,
                  ["unknown", "install", "hold", "deinstall", "purge"].contains(String(words[0])),
                  ["ok", "reinstreq"].contains(String(words[1])),
                  [
                      "not-installed", "config-files", "half-installed", "unpacked", "half-configured",
                      "triggers-awaited", "triggers-pending", "installed",
                  ].contains(String(words[2]))
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if words[2] == "not-installed" || words[2] == "config-files" {
                continue
            }
            guard let version = fields["version"], DebianVersion.isValid(version), result[name] == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result[name] = Package(identity: name, payload: [version: fields])
        }
        return result
    }
}
