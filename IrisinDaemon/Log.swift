import os

/// Shared by the listener's queue and the main thread; `Logger` is Sendable.
let log = Logger(subsystem: "wiki.qaq.irisind", category: "daemon")
