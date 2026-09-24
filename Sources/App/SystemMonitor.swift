import Foundation
import Observation
import BackgroundsCore

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu, memory, pid, name, user, threads, time, disk, state

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .pid: "PID"
        case .name: "Name"
        case .user: "User"
        case .threads: "Threads"
        case .time: "CPU time"
        case .disk: "Disk I/O"
        case .state: "State"
        }
    }
}

/// Samples the machine on a timer and keeps history for graphs, like btop's boxes.
@MainActor
@Observable
final class SystemMonitor {
    let host: HostInfo
    private let sampler = SystemSampler()
    private var loop: Task<Void, Never>?

    var intervalMS = 2000 { didSet { restart() } }
    var isPaused = false

    private(set) var latest: SystemSnapshot?
    private(set) var cpuTotal = History()
    private(set) var cpuCores: [History] = []
    private(set) var memoryUsed = History()
    private(set) var swapUsed = History()
    private(set) var netIn = History()
    private(set) var netOut = History()
    private(set) var diskRead = History()
    private(set) var diskWrite = History()
    private(set) var gpu = History()
    private(set) var cpuByPID: [Int: Double] = [:]

    // Process view state
    var sort: ProcessSort = .cpu
    var sortDescending = true
    var treeMode = false
    var collapsed: Set<Int> = []
    var onlyMine = false
    var processFilter = ""
    var selectedPID: Int? { didSet { if selectedPID != oldValue { resetPIDHistory() } } }
    private(set) var pidCPU = History(capacity: 60)
    private(set) var pidMemory = History(capacity: 60)

    init() {
        host = sampler.host
        cpuCores = Array(repeating: History(), count: host.logicalCores)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let ms = self?.intervalMS ?? 2000
                try? await Task.sleep(for: .milliseconds(max(250, ms)))
            }
        }
    }

    private func restart() {
        loop?.cancel()
        loop = nil
        start()
    }

    func tick() async {
        guard !isPaused else { return }
        let sampler = sampler
        let snap = await Task.detached { sampler.sample() }.value
        apply(snap)
    }

    private func apply(_ snap: SystemSnapshot) {
        latest = snap
        cpuTotal.append(snap.cpu.total.busy)
        if cpuCores.count != snap.cpu.cores.count {
            cpuCores = Array(repeating: History(), count: snap.cpu.cores.count)
        }
        for (i, core) in snap.cpu.cores.enumerated() { cpuCores[i].append(core.busy) }
        memoryUsed.append(snap.memory.usedFraction)
        swapUsed.append(snap.memory.swapFraction)
        let external = snap.network.filter { $0.isUp && $0.name != "lo0" }
        netIn.append(external.reduce(0) { $0 + $1.inPerSecond })
        netOut.append(external.reduce(0) { $0 + $1.outPerSecond })
        diskRead.append(snap.diskRead)
        diskWrite.append(snap.diskWrite)
        gpu.append(snap.gpus.map(\.utilization).max() ?? 0)
        cpuByPID = Dictionary(snap.processes.map { ($0.pid, $0.cpuPercent) }, uniquingKeysWith: { a, _ in a })
        if let pid = selectedPID, let row = snap.processes.first(where: { $0.pid == pid }) {
            pidCPU.append(row.cpuPercent)
            pidMemory.append(Double(row.residentBytes))
        }
    }

    private func resetPIDHistory() {
        pidCPU = History(capacity: 60)
        pidMemory = History(capacity: 60)
    }

    // MARK: Processes

    var selectedProcess: ProcessRow? {
        guard let pid = selectedPID else { return nil }
        return latest?.processes.first { $0.pid == pid }
    }

    func children(of pid: Int) -> [ProcessRow] {
        latest?.processes.filter { $0.ppid == pid && $0.pid != pid } ?? []
    }

    func parent(of row: ProcessRow) -> ProcessRow? {
        latest?.processes.first { $0.pid == row.ppid }
    }

    func rows(query: String) -> [ProcessNode] {
        var rows = latest?.processes ?? []
        if onlyMine { rows = rows.filter(\.isOwn) }
        let needle = processFilter.isEmpty ? query : processFilter
        if !needle.isEmpty {
            rows = rows.filter { row in
                row.name.localizedCaseInsensitiveContains(needle)
                    || row.command.localizedCaseInsensitiveContains(needle)
                    || row.user.localizedCaseInsensitiveContains(needle)
                    || String(row.pid) == needle
            }
        }
        let order = comparator
        if treeMode && needle.isEmpty {
            return ProcessTree.flatten(rows, collapsed: collapsed, by: order)
        }
        return rows.sorted(by: order).map {
            ProcessNode(row: $0, depth: 0, hasChildren: false, treeCPU: $0.cpuPercent, treeMemory: $0.residentBytes)
        }
    }

    private var comparator: (ProcessRow, ProcessRow) -> Bool {
        let desc = sortDescending
        func by<T: Comparable>(_ key: @escaping (ProcessRow) -> T) -> (ProcessRow, ProcessRow) -> Bool {
            { lhs, rhs in
                let a = key(lhs), b = key(rhs)
                if a == b { return lhs.pid < rhs.pid }
                return desc ? a > b : a < b
            }
        }
        switch sort {
        case .cpu: return by(\.cpuPercent)
        case .memory: return by(\.residentBytes)
        case .pid: return by(\.pid)
        case .name: return by { $0.name.lowercased() }
        case .user: return by(\.user)
        case .threads: return by { $0.threads ?? -1 }
        case .time: return by(\.cpuTime)
        case .disk: return by { $0.diskReadRate + $0.diskWriteRate }
        case .state: return by(\.state)
        }
    }

    func toggleCollapse(_ pid: Int) {
        if collapsed.contains(pid) { collapsed.remove(pid) } else { collapsed.insert(pid) }
    }

    /// CPU % for display, honoring the per-core setting.
    func displayCPU(_ percent: Double, perCore: Bool) -> Double {
        perCore ? percent : percent / Double(max(1, host.logicalCores))
    }

    func cpu(for item: RunningItem) -> Double {
        item.allPIDs.reduce(0) { $0 + (cpuByPID[$1] ?? 0) }
    }
}
