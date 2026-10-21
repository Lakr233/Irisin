import AptRepository
import Darwin
import Foundation
import IrisinAdapter
import IrisinProtocol

/// Where this run finds everything, decided once at the start of a command:
/// the install root from this program's own path, mobile's copy of what the
/// app keeps, and the catalogue opened read-only (Documentation/CommandLine.md).
struct Context {
    /// The path the package installs this program at, below the install root.
    static let installedPath = "/usr/bin/irisin-cli"
    /// The app's data folder, in mobile's home (`AppPaths.documentsDirectory`).
    static let dataFolder = "Documents/" + IrisinWire.appDataFolderName

    let installRoot: String
    let architecture: String
    let mobile: (uid: uid_t, home: URL)
    let data: URL

    /// Root, at the installed path, or a refusal that says what to do.
    static func load() throws -> Context {
        guard getuid() == 0, geteuid() == 0 else {
            throw CommandFailure.notRoot
        }
        guard let installRoot = ProcessPath.installRoot(ofCurrentProcessAt: installedPath) else {
            throw CommandFailure.misplaced
        }
        guard let account = getpwnam("mobile") else {
            throw CommandFailure.unavailable("The mobile account was not found.")
        }
        let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true)
        let architecture = try Self.packagedArchitecture(installRoot: installRoot)
        return Context(
            installRoot: installRoot,
            architecture: architecture,
            mobile: (account.pointee.pw_uid, home),
            data: Self.appData(installRoot: installRoot, home: home)
        )
    }

    /// The folder the app keeps its catalogue in, under the home it was
    /// given. icli registers an app's HOME as `<jbroot>/var/mobile` on
    /// RootHide and as mobile's own elsewhere, and a RootHide device whose
    /// app was registered before that keeps mobile's: of the two, the one
    /// with a catalogue, and of two catalogues the one written last.
    private static func appData(installRoot: String, home: URL) -> URL {
        let candidates = [
            URL(fileURLWithPath: installRoot + "/var/mobile", isDirectory: true),
            home,
        ].map { $0.appendingPathComponent(dataFolder, isDirectory: true) }
        func written(_ folder: URL) -> Date? {
            ["apt.db-wal", "apt.db"].lazy.compactMap { name in
                (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.modificationDate] as? Date
            }.first
        }
        let found = candidates.compactMap { folder in written(folder).map { (folder, $0) } }
        return found.max { $0.1 < $1.1 }?.0 ?? candidates.last!
    }

    /// The bootstrap the installed app was packaged for, as the app reads it
    /// (`PackagedArchitecture`): one binary serves both flavors and the
    /// plist says which this copy is.
    private static func packagedArchitecture(installRoot: String) throws -> String {
        let plist = URL(fileURLWithPath: installRoot + "/Applications/irisin.app/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let architecture = info["IrisinCurrentArchitecture"] as? String
        else {
            throw CommandFailure.unavailable("Irisin's app was not found beside irisin-cli. Reinstall Irisin.")
        }
        return architecture
    }

    func path(_ path: String) -> String {
        installRoot + path
    }

    /// `physical` as the user's shell spells it, for a message: inside the
    /// jbroot without it on RootHide, the rest under `/rootfs`.
    func shellPath(_ physical: String) -> String {
        guard architecture == BootstrapArchitecture.roothide.rawValue else { return physical }
        let roots = [installRoot, installRoot.hasPrefix("/private/") ? String(installRoot.dropFirst("/private".count)) : installRoot]
        for root in roots where physical.hasPrefix(root + "/") {
            return String(physical.dropFirst(root.count))
        }
        return "/rootfs" + physical
    }

    /// A path the user typed, in the shell's spelling. A RootHide shell is
    /// vroot-linked and this program is not: there `/x` is the jbroot's
    /// `/x` and `/rootfs/x` the system's, while a relative path is read
    /// against the working directory, which is the same directory either
    /// way. A rootless shell spells paths as the kernel does.
    func userPath(_ typed: String) -> URL {
        guard typed.hasPrefix("/"), architecture == BootstrapArchitecture.roothide.rawValue else {
            return URL(fileURLWithPath: typed).standardizedFileURL
        }
        if typed == "/rootfs" || typed.hasPrefix("/rootfs/") {
            let system = String(typed.dropFirst("/rootfs".count))
            return URL(fileURLWithPath: system.isEmpty ? "/" : system).standardizedFileURL
        }
        return URL(fileURLWithPath: installRoot + typed).standardizedFileURL
    }

    var statusFile: String {
        path("/Library/dpkg/status")
    }

    var logFile: String {
        path("/var/log/irisin-install.log")
    }

    /// Hands AptRepository an environment that never points at mobile's
    /// folder: the catalogue is opened read-only on its own, and a working
    /// location there would let a writable handle meet it.
    func bootstrapEnvironment(verbose: Bool) {
        let architecture = architecture
        let installable = PackageAdapters.installed.installable(on: architecture)
        AptEnvironment.bootstrap(AptEnvironment(
            workingLocation: FileManager.default.temporaryDirectory.appendingPathComponent("irisin-cli-unused"),
            dpkgStatusLocation: statusFile,
            aptExtendedStatesLocation: path("/var/lib/apt/extended_states"),
            deviceArchitecture: { architecture },
            installableArchitectures: { installable },
            indexFallbacks: { BootstrapArchitecture.probeOrder.map(\.rawValue) },
            adaptedManifestPreview: {
                PackageAdapters.installed.resolveAdaptedPackageManifestPreview(control: $0, on: architecture)
            },
            storage: ReadOnlySettings(folder: data.appendingPathComponent("Settings", isDirectory: true)),
            logger: StandardErrorLogger(verbose: verbose)
        ))
    }

    /// The app's catalogue, read-only. Refused, with what to do, when the
    /// app has not left one root could open without making a file there.
    func openCatalogue() throws -> PackageIndex {
        do {
            var index = try PackageIndex.readOnly(in: data, owner: mobile.uid)
            index.restoreUpdatePreferences(from: ReadOnlySettings(folder: data.appendingPathComponent("Settings")))
            return index
        } catch let unavailable as CatalogueUnavailable {
            throw CommandFailure.unavailable(
                "Irisin's catalogue is not ready (\(shellPath(unavailable.file)): \(unavailable.reason)). Open Irisin once, then try again."
            )
        }
    }
}

/// The app's setting files, read and never written: a write from root
/// would leave a file in mobile's folder the app could not change again.
struct ReadOnlySettings: AptStorage {
    let folder: URL

    func read(key: String) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(key))
    }

    func write(key _: String, value _: Data?) {}
}

/// AptRepository's lines, on standard error and only when asked for.
struct StandardErrorLogger: AptLogger {
    let verbose: Bool

    func log(_ kind: String, _ message: String, level: AptLogLevel) {
        guard verbose || level == .critical else { return }
        FileHandle.standardError.write(Data("[\(level.rawValue)] \(kind): \(message)\n".utf8))
    }
}
