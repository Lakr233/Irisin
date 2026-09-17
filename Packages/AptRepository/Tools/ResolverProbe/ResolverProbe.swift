import AptRepository
import AptResolver
import Foundation

@main
struct ResolverProbe {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let input = try JSONDecoder().decode(ProbeInput.self, from: data)
        let start = Date()
        let packages = input.available.map { input.package($0, installed: false) }
        var actions = input.remove.map(ResolutionAction.remove)
        for name in input.install {
            let components = name.split(separator: "=", maxSplits: 1).map(String.init)
            let candidates = packages.filter {
                $0.identity == components[0].lowercased() && $0.supports(architecture: input.architecture) &&
                    (components.count == 1 || $0.latestVersion == components[1])
            }
            guard let chosen = candidates.max(by: {
                DebianVersion.compare($0.latestVersion!, $1.latestVersion!) < 0
            }) else {
                throw ResolutionFailure(message: "Requested package not found: \(name)")
            }
            actions.append(.install(chosen))
        }
        let result = try PackageResolver.resolve(
            request: .init(actions: actions, updateAll: input.updateAll),
            snapshot: .init(
                packages: packages,
                installed: input.installed.map { input.package($0, installed: true) },
                architecture: input.architecture
            )
        )
        let output = ProbeOutput(
            install: Dictionary(uniqueKeysWithValues: result.install.map { ($0.identity, $0.latestVersion!) }),
            remove: result.remove.map(\.identity).sorted(),
            final: Dictionary(uniqueKeysWithValues: result.finalPackages.map { ($0.identity, $0.latestVersion!) }),
            heldBack: result.heldBack,
            stages: result.stages,
            seconds: Date().timeIntervalSince(start)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try print(String(decoding: encoder.encode(output), as: UTF8.self))
    }
}
