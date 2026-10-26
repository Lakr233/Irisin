/// The system processes the helper signals, by the name `ProcessTable`
/// matches, for the system it was built for.
enum SystemProcess {
    /// The home screen: safe mode crashes it with `SIGSEGV`, which is what a
    /// tweak injector watches for. PineBoard is Apple TV's.
    static let homeScreen: String = {
        #if os(tvOS)
            "PineBoard"
        #else
            "SpringBoard"
        #endif
    }()

    /// The respring fallback: asked to exit with `SIGTERM`, it takes the
    /// home screen with it, the way `killall backboardd` did.
    static let backboard = "backboardd"

    /// AirDrop's daemon, which an AirDrop reload kills. Nil on tvOS, which
    /// has no AirDrop.
    static let airDrop: String? = {
        #if os(tvOS)
            nil
        #else
            "sharingd"
        #endif
    }()
}
