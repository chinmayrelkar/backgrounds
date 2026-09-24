import Darwin
import Foundation

public struct ProcessRow: Identifiable, Hashable, Sendable {
    public var id: Int { pid }
    public var pid: Int
    public var ppid: Int
    public var uid: Int
    public var user: String
    public var name: String
    public var path: String
    public var command: String
    public var state: String
    public var nice: Int
    public var priority: Int
    public var residentBytes: UInt64
    public var virtualBytes: UInt64
    /// Seconds of CPU used since start.
    public var cpuTime: Double
    /// Seconds since start.
    public var elapsed: Double
    /// Percent of one core (Activity Monitor style). Divide by core count for share of the whole CPU.
    public var cpuPercent: Double = 0
    public var threads: Int?
    public var diskReadBytes: UInt64?
    public var diskWriteBytes: UInt64?
    public var diskReadRate: Double = 0
    public var diskWriteRate: Double = 0

    public var isOwn: Bool { uid == Int(getuid()) }

    public var stateTitle: String {
        switch state.first {
        case "R": "running"
        case "S": "sleeping"
        case "I": "idle"
        case "T": "stopped"
        case "U": "waiting"
        case "Z": "zombie"
        default: state
        }
    }
}

public enum ProcessList {
    /// One pass of `ps` for every process. CPU % needs two passes; see `ProcessSampler`.
    public static func snapshot() throws -> [ProcessRow] {
        let raw = try Shell.output("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,pri=,nice=,rss=,vsz=,state=,time=,etime=,args="])
        var users: [Int: String] = [:]
        return raw.split(separator: "\n").compactMap { line in
            guard var row = parse(String(line)) else { return nil }
            if let cached = users[row.uid] {
                row.user = cached
            } else {
                row.user = userName(row.uid)
                users[row.uid] = row.user
            }
            enrich(&row)
            return row
        }
    }

    static func parse(_ line: String) -> ProcessRow? {
        let parts = line.split(maxSplits: 10, omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
        guard parts.count == 11,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]),
              let uid = Int(parts[2]),
              let rss = UInt64(parts[5]),
              let vsz = UInt64(parts[6])
        else { return nil }
        let command = String(parts[10])
        let path = executablePath(pid) ?? String(command.split(separator: " ").first ?? "")
        var name = URL(fileURLWithPath: path).lastPathComponent
        if name.isEmpty { name = command }
        return ProcessRow(
            pid: pid,
            ppid: ppid,
            uid: uid,
            user: "",
            name: name,
            path: path,
            command: command,
            state: String(parts[7]),
            nice: Int(parts[4]) ?? 0,
            priority: Int(parts[3]) ?? 0,
            residentBytes: rss * 1024,
            virtualBytes: vsz * 1024,
            cpuTime: duration(String(parts[8])),
            elapsed: duration(String(parts[9]))
        )
    }

    /// Parses ps times: "ss.cc", "m:ss.cc", "h:mm:ss", "d-hh:mm:ss".
    static func duration(_ text: String) -> Double {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        let seconds = parts.reversed().enumerated().reduce(0.0) { sum, item in
            sum + item.element * pow(60, Double(item.offset))
        }
        return days * 86_400 + seconds
    }

    /// Thread count and disk I/O. Only works for our own processes without root.
    static func enrich(_ row: inout ProcessRow) {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(Int32(row.pid), PROC_PIDTASKINFO, 0, &task, size) == size {
            row.threads = Int(task.pti_threadnum)
        }
        var usage = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(Int32(row.pid), RUSAGE_INFO_V2, $0) == 0
            }
        }
        if ok {
            row.diskReadBytes = usage.ri_diskio_bytesread
            row.diskWriteBytes = usage.ri_diskio_byteswritten
        }
    }

    static func executablePath(_ pid: Int) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func userName(_ uid: Int) -> String {
        guard let pw = getpwuid(uid_t(truncatingIfNeeded: uid)) else { return String(uid) }
        return String(cString: pw.pointee.pw_name)
    }

    /// Changes priority. Raising priority (negative nice) needs admin.
    public static func renice(_ pid: Int, to value: Int, allowAdmin: Bool = true) throws {
        if setpriority(PRIO_PROCESS, id_t(pid), Int32(value)) == 0 { return }
        guard allowAdmin, errno == EPERM || errno == EACCES else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = try Shell.run("/usr/bin/renice", [String(value), "-p", String(pid)], admin: true)
    }
}

/// Keeps the previous pass so CPU % and disk rates come from real deltas, like btop.
public final class ProcessSampler: @unchecked Sendable {
    private var previous: [Int: (cpu: Double, read: UInt64?, write: UInt64?)] = [:]
    private var lastTime: Date?
    private let lock = NSLock()

    public init() {}

    public func sample() throws -> [ProcessRow] {
        var rows = try ProcessList.snapshot()
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        let wall = lastTime.map { now.timeIntervalSince($0) } ?? 0
        var next: [Int: (cpu: Double, read: UInt64?, write: UInt64?)] = [:]
        for index in rows.indices {
            let row = rows[index]
            if wall > 0, let prev = previous[row.pid] {
                rows[index].cpuPercent = max(0, (row.cpuTime - prev.cpu) / wall * 100)
                if let read = row.diskReadBytes, let old = prev.read, read >= old {
                    rows[index].diskReadRate = Double(read - old) / wall
                }
                if let write = row.diskWriteBytes, let old = prev.write, write >= old {
                    rows[index].diskWriteRate = Double(write - old) / wall
                }
            } else if row.elapsed > 0 {
                // First pass: lifetime average, same as `ps %cpu` roughly.
                rows[index].cpuPercent = row.cpuTime / row.elapsed * 100
            }
            next[row.pid] = (row.cpuTime, row.diskReadBytes, row.diskWriteBytes)
        }
        previous = next
        lastTime = now
        return rows
    }
}

public struct ProcessNode: Identifiable, Sendable {
    public var id: Int { row.pid }
    public var row: ProcessRow
    public var depth: Int
    public var hasChildren: Bool
    /// Row plus all descendants.
    public var treeCPU: Double
    public var treeMemory: UInt64

    public init(row: ProcessRow, depth: Int, hasChildren: Bool, treeCPU: Double, treeMemory: UInt64) {
        self.row = row
        self.depth = depth
        self.hasChildren = hasChildren
        self.treeCPU = treeCPU
        self.treeMemory = treeMemory
    }
}

public enum ProcessTree {
    /// Depth-first flattening. Children are ordered by `areInIncreasingOrder`; collapsed PIDs hide their subtree.
    public static func flatten(
        _ rows: [ProcessRow],
        collapsed: Set<Int> = [],
        by areInIncreasingOrder: (ProcessRow, ProcessRow) -> Bool
    ) -> [ProcessNode] {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int: [ProcessRow]] = [:]
        var roots: [ProcessRow] = []
        for row in rows {
            if row.ppid != row.pid, byPID[row.ppid] != nil {
                children[row.ppid, default: []].append(row)
            } else {
                roots.append(row)
            }
        }
        var totals: [Int: (Double, UInt64)] = [:]
        func total(_ row: ProcessRow) -> (Double, UInt64) {
            if let cached = totals[row.pid] { return cached }
            var sum = (row.cpuPercent, row.residentBytes)
            for child in children[row.pid] ?? [] {
                let t = total(child)
                sum.0 += t.0
                sum.1 += t.1
            }
            totals[row.pid] = sum
            return sum
        }
        var out: [ProcessNode] = []
        func visit(_ row: ProcessRow, depth: Int) {
            let kids = (children[row.pid] ?? []).sorted(by: areInIncreasingOrder)
            let t = total(row)
            out.append(ProcessNode(row: row, depth: depth, hasChildren: !kids.isEmpty, treeCPU: t.0, treeMemory: t.1))
            guard !collapsed.contains(row.pid) else { return }
            for kid in kids { visit(kid, depth: depth + 1) }
        }
        for root in roots.sorted(by: areInIncreasingOrder) { visit(root, depth: 0) }
        return out
    }
}
