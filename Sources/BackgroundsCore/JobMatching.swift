import Foundation

public enum JobMatching {
    /// The login job that owns a running process, if any.
    ///
    /// A PID match is proof. Without one, only an exact binary match counts, and never for
    /// interpreters: a job running `/usr/bin/python3` would otherwise claim every Python process.
    public static func job(for process: RunningItem, in jobs: [LaunchItem]) -> LaunchItem? {
        let pids = Set(process.allPIDs)
        if let owner = jobs.first(where: { job in job.pid.map(pids.contains) ?? false }) {
            return owner
        }
        return jobs.first { job in
            guard let program = job.program, !UserProcesses.isInterpreter(program) else { return false }
            return process.path == program
        }
    }
}
