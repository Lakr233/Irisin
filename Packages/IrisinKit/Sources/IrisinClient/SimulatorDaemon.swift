#if targetEnvironment(simulator)
    import Darwin
    import Foundation
    import IrisinInstaller
    import IrisinProtocol

    /// What answers for `irisind` and `irisin-install` in the simulator,
    /// where neither exists: the same `InstallerRunner` the helper runs, in
    /// this process, against a directory in the app's container that stands
    /// in for a rootless `/var/jb`.
    ///
    /// Everything above the transport is what a device runs: the job takes
    /// the trip through JSON the helper's standard input gives it, the
    /// transcript is the helper's events on a pipe, and `JobTranscript` reads
    /// the other end. What a Mac must not have done to it is left out by the
    /// installer itself under the same condition: maintainer scripts, icli
    /// and signals are announced and not carried out.
    enum SimulatorDaemon {
        /// Deleting the directory is a fresh device: the installer creates the
        /// dpkg database it does not find, and the record below comes back.
        static let installRoot: String = {
            let root = NSHomeDirectory() + "/Documents/SimulatorRoot"
            writeFirmwareRecord(under: root)
            return root
        }()

        /// What a bootstrap's firmware script does on a device: dpkg hears
        /// about iOS itself as an installed package, so `Depends: firmware (>=
        /// 15.0)` holds for the helper's own check of the final state and not
        /// only for the app's resolver, which would make one up. Written when
        /// the status file has none, before anything has read that file.
        private static func writeFirmwareRecord(under root: String) {
            let database = root + "/Library/dpkg"
            let status = (try? String(contentsOfFile: database + "/status", encoding: .utf8)) ?? ""
            guard !status.split(separator: "\n").contains("Package: firmware") else { return }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let record = """
            Package: firmware
            Essential: yes
            Status: install ok installed
            Priority: required
            Section: System
            Installed-Size: 0
            Maintainer: Irisin
            Architecture: iphoneos-arm64
            Version: \(os.majorVersion).\(os.minorVersion)
            Description: virtual package standing for the simulator's iOS

            """
            try? FileManager.default.createDirectory(atPath: database, withIntermediateDirectories: true)
            let separator = status.isEmpty || status.hasSuffix("\n\n") ? "" : status.hasSuffix("\n") ? "\n" : "\n\n"
            try? (status + separator + record).write(
                toFile: database + "/status",
                atomically: true,
                encoding: .utf8
            )
        }

        static func run(_ job: InstallerJob) throws -> JobTranscript {
            let job = try InstallerJob.decode(job.encoded())
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else {
                throw IrisinFailure(code: .operationFailed, systemError: errno)
            }
            // The helper ignores SIGPIPE so a reader that went away cannot kill
            // a half-finished transaction; here the writer is the app itself.
            _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
            let output = FileHandle(fileDescriptor: ends[1], closeOnDealloc: true)
            let emit: @Sendable (InstallerEvent) -> Void = { event in
                try? output.write(contentsOf: Data((InstallerOutput.encode(event) + "\n").utf8))
            }
            // A thread of its own, as the helper is a process of its own: the
            // runner blocks until the transaction is over.
            Thread.detachNewThread {
                emit(.started(.init(job: job.name, uid: getuid(), installRoot: installRoot)))
                let layout = BootstrapLayout(kind: .rootless(prefix: BootstrapLayout.rootlessPrefix), mount: installRoot)
                let status = InstallerRunner(installRoot: installRoot, layout: layout, emit: emit).run(job)
                emit(.exit(status))
                try? output.close()
            }
            return JobTranscript(identifier: UInt64.random(in: 1 ... .max), descriptor: ends[0])
        }
    }
#endif
