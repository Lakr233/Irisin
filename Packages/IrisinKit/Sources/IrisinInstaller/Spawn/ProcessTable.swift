import Darwin
import Foundation

@_silgen_name("proc_listpids")
private func irisinProcListPIDs(
    _ type: UInt32,
    _ typeInfo: UInt32,
    _ buffer: UnsafeMutableRawPointer?,
    _ bufferSize: Int32
) -> Int32

@_silgen_name("proc_name")
private func irisinProcName(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ bufferSize: UInt32) -> Int32

/// The running processes, by name, and a signal for them.
///
/// What `killall` did for the helper, done in-process: the helper runs as
/// root, so `kill(2)` is all a respring fallback, a safe-mode entry or an
/// AirDrop reload needs, and there is no binary to find, spawn or trust. The
/// name compared is what `proc_name` reports: the executable's name, or the
/// kernel's `p_comm` (its first 16 bytes) for a process that has no longer
/// one, which is how `killall` matches too.
enum ProcessTable {
    private static let allProcesses: UInt32 = 1 // PROC_ALL_PIDS

    /// Every pid whose process name is `name`, excluding this process.
    static func processIdentifiers(named name: String) -> [pid_t] {
        let truncated = String(decoding: Array(name.utf8.prefix(16)), as: UTF8.self)
        let needed = irisinProcListPIDs(allProcesses, 0, nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes {
            irisinProcListPIDs(allProcesses, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        let count = Int(filled) / MemoryLayout<pid_t>.stride
        let me = getpid()
        var buffer = [CChar](repeating: 0, count: 64)
        return pids[..<count].filter { pid in
            guard pid > 0, pid != me else { return false }
            let length = buffer.withUnsafeMutableBytes { irisinProcName(pid, $0.baseAddress!, UInt32($0.count)) }
            guard length > 0 else { return false }
            let actual = String(cString: buffer)
            return actual == name || actual == truncated
        }
    }

    /// Sends `number` to every process named `name`. Returns how many were
    /// signalled; zero means there was nothing by that name.
    ///
    /// The same race `killall` has: a pid read from the table could in
    /// principle be reused before `kill(2)` runs. The names this is called
    /// with are compile-time literals for long-lived system daemons, which
    /// is why that window is accepted here.
    static func signal(processesNamed name: String, with number: Int32) -> Int {
        var delivered = 0
        for pid in processIdentifiers(named: name) where kill(pid, number) == 0 {
            delivered += 1
        }
        return delivered
    }
}
