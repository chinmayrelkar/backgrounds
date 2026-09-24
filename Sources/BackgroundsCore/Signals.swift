import Darwin
import Foundation

public struct SignalInfo: Identifiable, Hashable, Sendable {
    public var id: Int32 { number }
    public var number: Int32
    public var name: String
    public var meaning: String
}

public enum SignalError: LocalizedError, Sendable {
    case notPermitted(pid: Int)
    case stillAlive(pids: [Int])

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let pid):
            "Not allowed to signal PID \(pid). It belongs to another user."
        case .stillAlive(let pids):
            "Still running after SIGKILL: \(pids.map(String.init).joined(separator: ", "))"
        }
    }
}

public enum StopOutcome: Sendable, Equatable {
    case exited
    case killed
    case alreadyGone
}

public enum Signals {
    public static let all: [SignalInfo] = [
        .init(number: SIGTERM, name: "SIGTERM", meaning: "Ask to quit"),
        .init(number: SIGINT, name: "SIGINT", meaning: "Interrupt (Ctrl-C)"),
        .init(number: SIGHUP, name: "SIGHUP", meaning: "Hang up / reload"),
        .init(number: SIGQUIT, name: "SIGQUIT", meaning: "Quit and dump core"),
        .init(number: SIGKILL, name: "SIGKILL", meaning: "Force kill"),
        .init(number: SIGSTOP, name: "SIGSTOP", meaning: "Pause"),
        .init(number: SIGCONT, name: "SIGCONT", meaning: "Resume"),
        .init(number: SIGUSR1, name: "SIGUSR1", meaning: "User signal 1"),
        .init(number: SIGUSR2, name: "SIGUSR2", meaning: "User signal 2"),
        .init(number: SIGTSTP, name: "SIGTSTP", meaning: "Terminal stop"),
        .init(number: SIGWINCH, name: "SIGWINCH", meaning: "Window size changed"),
        .init(number: SIGINFO, name: "SIGINFO", meaning: "Status request"),
        .init(number: SIGABRT, name: "SIGABRT", meaning: "Abort"),
        .init(number: SIGALRM, name: "SIGALRM", meaning: "Alarm"),
        .init(number: SIGPIPE, name: "SIGPIPE", meaning: "Broken pipe"),
    ]

    public static func name(_ number: Int32) -> String? {
        if let known = all.first(where: { $0.number == number }) { return known.name }
        guard number > 0, number < NSIG, let raw = strsignal(number) else { return nil }
        return String(cString: raw)
    }

    /// A zombie has exited and only waits to be reaped, so it counts as gone.
    public static func isAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) != 0 && errno != EPERM { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size {
            return info.pbi_status != UInt32(SZOMB)
        }
        return true
    }

    /// Sends one signal. Falls back to an admin prompt when the process is not ours.
    public static func send(_ signal: Int32, to pid: Int, allowAdmin: Bool = false) throws {
        if kill(pid_t(pid), signal) == 0 { return }
        let code = errno
        if code == ESRCH { return }
        if code == EPERM {
            guard allowAdmin else { throw SignalError.notPermitted(pid: pid) }
            _ = try Shell.run("/bin/kill", ["-\(signal)", String(pid)], admin: true)
            return
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// SIGTERM, wait, then SIGKILL anything left. Throws if a PID survives.
    @discardableResult
    public static func terminate(
        _ pids: [Int],
        grace: TimeInterval = 3,
        allowAdmin: Bool = false
    ) throws -> StopOutcome {
        let targets = pids.filter(isAlive)
        if targets.isEmpty { return .alreadyGone }
        for pid in targets { try send(SIGTERM, to: pid, allowAdmin: allowAdmin) }
        if waitGone(targets, timeout: grace) { return .exited }
        let left = targets.filter(isAlive)
        for pid in left { try send(SIGKILL, to: pid, allowAdmin: allowAdmin) }
        if waitGone(left, timeout: 1.5) { return .killed }
        throw SignalError.stillAlive(pids: left.filter(isAlive))
    }

    static func waitGone(_ pids: [Int], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !pids.contains(where: isAlive) { return true }
            usleep(100_000)
        } while Date() < deadline
        return !pids.contains(where: isAlive)
    }
}
