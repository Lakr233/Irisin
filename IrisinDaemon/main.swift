import Dispatch
import Foundation
import IrisinProtocol
import os

autoreleasepool {
    // Where the jailbreak put us. An unknown layout must not become an
    // unrestricted rootful backend, so this is decided before the listener
    // exists.
    guard let installRoot = ProcessPath.installRoot(ofCurrentProcessAt: IrisinWire.daemonPath) else {
        log.error("irisind is not at its installed path; refusing to start")
        exit(EX_CONFIG)
    }
    log.info("irisind started, pid \(getpid()), uid \(getuid()), root \(installRoot, privacy: .public)")
    let server = DaemonServer(installRoot: installRoot)
    guard server.start() else {
        log.error("irisind could not register \(IrisinWire.serviceName, privacy: .public)")
        exit(EXIT_FAILURE)
    }
    let executableWatch = ProcessPath.executable(of: getpid()).flatMap { path in
        ExecutableWatch(path: path, queue: .global(qos: .utility)) {
            log.info("irisind executable was replaced or removed; exiting")
            exit(EXIT_SUCCESS)
        }
    }
    withExtendedLifetime((server, executableWatch)) {
        dispatchMain()
    }
}
