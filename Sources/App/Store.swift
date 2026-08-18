import Foundation
import Observation
import BackgroundsCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case running
    case jobs
    case watches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running: "Running"
        case .jobs: "Login jobs"
        case .watches: "Watches"
        }
    }

    var symbol: String {
        switch self {
        case .running: "play.circle"
        case .jobs: "clock.arrow.circlepath"
        case .watches: "eye"
        }
    }
}

@MainActor
@Observable
final class Store {
    var processes: [RunningItem] = []
    var jobs: [LaunchItem] = []
    var watches: [WatchRoot] = []
    var watchmanAvailable = true
    var selectedSidebar: SidebarItem = .running
    var selectedProcessID: RunningItem.ID?
    var selectedJobID: LaunchItem.ID?
    var selectedWatchID: WatchRoot.ID?
    var query = ""
    var showApple = false
    var isBusy = false
    var status: String?
    var errorMessage: String?

    var selectedProcess: RunningItem? {
        processes.first { $0.id == selectedProcessID }
    }

    var selectedJob: LaunchItem? {
        jobs.first { $0.id == selectedJobID }
    }

    var selectedWatch: WatchRoot? {
        watches.first { $0.id == selectedWatchID }
    }

    var visibleProcesses: [RunningItem] {
        guard !query.isEmpty else { return processes }
        return processes.filter { item in
            [item.name, item.path, item.command].joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    var visibleJobs: [LaunchItem] {
        jobs.filter { item in
            if !showApple && item.isApple { return false }
            if query.isEmpty { return true }
            let hay = [item.label, item.program, item.plistPath, item.arguments.joined(separator: " ")]
                .compactMap { $0 }
                .joined(separator: " ")
            return hay.localizedCaseInsensitiveContains(query)
        }
    }

    var visibleWatches: [WatchRoot] {
        if query.isEmpty { return watches }
        return watches.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    func count(for sidebar: SidebarItem) -> Int {
        switch sidebar {
        case .running: visibleProcesses.count
        case .jobs: visibleJobs.count
        case .watches: visibleWatches.count
        }
    }

    func loginJob(for process: RunningItem) -> LaunchItem? {
        jobs.first { job in
            guard let program = job.program else { return false }
            return process.path == program || process.command.contains(program)
        }
    }

    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let loadedJobs = try await Task.detached { try Launchctl.inventory() }.value
            let loadedProcs = try await Task.detached { try UserProcesses.inventory() }.value
            let roots: [WatchRoot]
            let available: Bool
            if Watchman.isAvailable {
                available = true
                roots = (try? await Task.detached { try Watchman.list() }.value) ?? []
            } else {
                available = false
                roots = []
            }
            jobs = loadedJobs
            processes = loadedProcs
            watches = roots
            watchmanAvailable = available
            if selectedProcessID == nil {
                selectedProcessID = visibleProcesses.first?.id
            }
            status = Self.clock.string(from: Date())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(process: RunningItem) async {
        if let job = loginJob(for: process), job.canStop {
            await mutate("Stopped \(process.name)") { try Launchctl.stop(job) }
            return
        }
        await mutate("Stopped \(process.name)") { try UserProcesses.stop(process) }
    }

    func stop(job: LaunchItem) async {
        await mutate("Stopped \(job.label)") { try Launchctl.stop(job) }
    }

    func start(job: LaunchItem) async {
        await mutate("Started \(job.label)") { try Launchctl.start(job) }
    }

    func purge(job: LaunchItem) async {
        await mutate("Purged \(job.label)") { try Launchctl.purge(job) }
        selectedJobID = nil
    }

    func purge(process: RunningItem) async {
        if let job = loginJob(for: process) {
            await mutate("Purged \(process.name)") { try Launchctl.purge(job) }
            return
        }
        await stop(process: process)
    }

    func drop(_ root: WatchRoot) async {
        await mutate("Dropped \(root.path)") { try Watchman.drop(root) }
        selectedWatchID = nil
    }

    func dropAllWatches() async {
        await mutate("Dropped all watches") { try Watchman.dropAll() }
        selectedWatchID = nil
    }

    private func mutate(_ success: String, _ work: @escaping @Sendable () throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await Task.detached(operation: work).value
            status = success
            await refresh()
        } catch {
            if let shell = error as? ShellError, case .cancelled = shell { return }
            errorMessage = error.localizedDescription
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}
