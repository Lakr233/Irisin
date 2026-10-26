import CIrisinSpawn
import Darwin

/// One program started with `posix_spawn`, the way irisind starts the helper
/// and the helper starts a bootstrap tool: the argv and the environment the
/// caller composed and nothing else, no shell and no `PATH` lookup.
///
/// The spawn calls come from `CIrisinSpawn`, bound to libSystem's own
/// symbols, because the AppleTVOS SDK marks every one of them unavailable
/// and the iPhoneOS SDK marks `posix_spawn_file_actions_addchdir_np` so.
/// This is the one Swift file that names them; `make check` fails on another.
public enum ProcessSpawn {
    /// What one of the child's descriptors is when it starts.
    public enum Descriptor: Sendable {
        /// This process's descriptor, duplicated onto the child's `target`.
        case duplicate(Int32, as: Int32)
        /// `path`, opened with `flags`, as the child's `target`.
        case open(String, flags: Int32, as: Int32)
    }

    /// The error `posix_spawn` returned, or the one a file action could not
    /// be added with.
    public struct Failure: Error, Sendable {
        public let errno: Int32
    }

    /// Starts `executable` with exactly `arguments` as its argv and
    /// `environment` (`NAME=value` strings) as its environment, and returns
    /// its pid; the caller waits for it.
    ///
    /// The child has the descriptors in `descriptors` and no other: every one
    /// this process holds is closed in it (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so
    /// it has nothing it could use to reach back. Every signal is at its
    /// default and none is blocked, whatever this process ignores or masks.
    /// `newSession` puts it in a session of its own (`POSIX_SPAWN_SETSID`);
    /// `workingDirectory` starts it there.
    public static func spawn(
        _ executable: String,
        arguments: [String],
        environment: [String],
        descriptors: [Descriptor],
        workingDirectory: String? = nil,
        newSession: Bool = false
    ) throws(Failure) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(irisin_posix_spawn_file_actions_init(&actions))
        defer { irisin_posix_spawn_file_actions_destroy(&actions) }
        for descriptor in descriptors {
            switch descriptor {
            case let .duplicate(source, target):
                try check(irisin_posix_spawn_file_actions_adddup2(&actions, source, target))
            case let .open(path, flags, target):
                try check(irisin_posix_spawn_file_actions_addopen(&actions, target, path, flags, 0))
            }
        }
        if let workingDirectory {
            try check(irisin_posix_spawn_file_actions_addchdir_np(&actions, workingDirectory))
        }

        var attributes: posix_spawnattr_t?
        try check(irisin_posix_spawnattr_init(&attributes))
        defer { irisin_posix_spawnattr_destroy(&attributes) }
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        try check(irisin_posix_spawnattr_setsigdefault(&attributes, &defaulted))
        var masked = sigset_t()
        sigemptyset(&masked)
        try check(irisin_posix_spawnattr_setsigmask(&attributes, &masked))
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newSession {
            flags |= POSIX_SPAWN_SETSID
        }
        try check(irisin_posix_spawnattr_setflags(&attributes, Int16(flags)))

        let argv = CStringArray(arguments)
        let envp = CStringArray(environment)
        var pid: pid_t = 0
        // the arrays free their strings when they go, which without this
        // could be as soon as their pointers are read
        let spawned = withExtendedLifetime((argv, envp)) {
            irisin_posix_spawn(&pid, executable, &actions, &attributes, argv.pointers, envp.pointers)
        }
        try check(spawned)
        return pid
    }

    private static func check(_ result: Int32) throws(Failure) {
        guard result == 0 else { throw Failure(errno: result) }
    }
}
