import AppKit
import Foundation
import Observation
import BackgroundsCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case processes
    case running
    case jobs
    case loginItems
    case cron
    case brew
    case containers
    case ports
    case extensions
    case watches

    var id: String { rawValue }

    static let system: [SidebarItem] = [.overview, .processes]
    static let background: [SidebarItem] = [.running, .jobs, .loginItems, .cron, .brew, .containers, .ports, .extensions, .watches]

    var title: String {
        switch self {
        case .overview: "Overview"
        case .processes: "Processes"
        case .running: "Running"
        case .jobs: "Login jobs"
        case .loginItems: "Login items"
        case .cron: "Cron"
        case .brew: "Brew services"
        case .containers: "Containers"
        case .ports: "Ports"
        case .extensions: "Extensions"
        case .watches: "Watches"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .processes: "list.bullet.indent"
        case .running: "play.circle"
        case .jobs: "clock.arrow.circlepath"
        case .loginItems: "person.crop.circle.badge.checkmark"
        case .cron: "calendar.badge.clock"
        case .brew: "mug"
        case .containers: "shippingbox"
        case .ports: "network"
        case .extensions: "puzzlepiece.extension"
        case .watches: "eye"
        }
    }
}

/// A destructive action waiting for the user to confirm.
struct PendingConfirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var action: () -> Void
}

@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var autoRefreshSeconds: Int { didSet { defaults.set(autoRefreshSeconds, forKey: "autoRefreshSeconds") } }
    var monitorIntervalMS: Int { didSet { defaults.set(monitorIntervalMS, forKey: "monitorIntervalMS") } }
    var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "showMenuBar") } }
    var notifyNewJobs: Bool { didSet { defaults.set(notifyNewJobs, forKey: "notifyNewJobs") } }
    /// Process CPU % as share of one core (on) or of the whole machine (off, btop's default).
    var cpuPerCore: Bool { didSet { defaults.set(cpuPerCore, forKey: "cpuPerCore") } }
    var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    var hidden: Set<String> { didSet { defaults.set(Array(hidden).sorted(), forKey: "hidden") } }

    init() {
        defaults.register(defaults: [
            "autoRefreshSeconds": 15,
            "monitorIntervalMS": 2000,
            "showMenuBar": true,
            "notifyNewJobs": true,
            "cpuPerCore": true,
            "showHidden": false,
        ])
        autoRefreshSeconds = defaults.integer(forKey: "autoRefreshSeconds")
        monitorIntervalMS = defaults.integer(forKey: "monitorIntervalMS")
        showMenuBar = defaults.bool(forKey: "showMenuBar")
        notifyNewJobs = defaults.bool(forKey: "notifyNewJobs")
        cpuPerCore = defaults.bool(forKey: "cpuPerCore")
        showHidden = defaults.bool(forKey: "showHidden")
        hidden = Set(defaults.stringArray(forKey: "hidden") ?? [])
    }
}

@MainActor
@Observable
final class Store {
    var settings = AppSettings()

    var processes: [RunningItem] = []
    var jobs: [LaunchItem] = []
    var watches: [WatchRoot] = []
    var loginItems: [LoginItem] = []
    var cron: [CronEntry] = []
    var brew: [BrewService] = []
    var containers: [Container] = []
    var ports: [ListeningPort] = []
    var extensions: [SystemExtension] = []

    var watchmanAvailable = true
    var brewAvailable = true
    var containerEngines: [String] = []
    var sourceErrors: [SidebarItem: String] = [:]
    /// Login items need System Events, which pops an Automation prompt. Only ask once the user opens it.
    var loginItemsRequested = false

    var selectedSidebar: SidebarItem = .running {
        didSet {
            if selectedSidebar == .loginItems && !loginItemsRequested {
                loginItemsRequested = true
                Task { await refreshLoginItems() }
            }
        }
    }
    var selectedProcessIDs: Set<RunningItem.ID> = []
    var selectedJobIDs: Set<LaunchItem.ID> = []
    var selectedWatchIDs: Set<WatchRoot.ID> = []
    var selectedLoginItemIDs: Set<LoginItem.ID> = []
    var selectedCronIDs: Set<CronEntry.ID> = []
    var selectedBrewIDs: Set<BrewService.ID> = []
    var selectedContainerIDs: Set<Container.ID> = []
    var selectedPortIDs: Set<ListeningPort.ID> = []
    var selectedExtensionIDs: Set<SystemExtension.ID> = []

    var query = ""
    var showApple = false
    var isBusy = false
    var status: String?
    var errorMessage: String?
    var pending: PendingConfirm?

    private let notifier = Notifier()

    // MARK: Hide list

    func hideKey(_ section: SidebarItem, _ id: String) -> String { "\(section.rawValue):\(id)" }

    func isHidden(_ section: SidebarItem, _ id: String) -> Bool {
        settings.hidden.contains(hideKey(section, id))
    }

    func setHidden(_ section: SidebarItem, _ ids: [String], _ hidden: Bool) {
        for id in ids {
            let key = hideKey(section, id)
            if hidden { settings.hidden.insert(key) } else { settings.hidden.remove(key) }
        }
    }

    private func visible<T>(_ items: [T], _ section: SidebarItem, id: (T) -> String, hay: (T) -> [String?]) -> [T] {
        items.filter { item in
            if !settings.showHidden && isHidden(section, id(item)) { return false }
            if query.isEmpty { return true }
            return hay(item).compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: Visible lists

    var visibleProcesses: [RunningItem] {
        visible(processes, .running, id: \.id) { [$0.name, $0.path, $0.command] }
    }

    var visibleJobs: [LaunchItem] {
        visible(jobs.filter { showApple || !$0.isApple }, .jobs, id: \.id) {
            [$0.label, $0.program, $0.plistPath, $0.arguments.joined(separator: " ")]
        }
    }

    var visibleWatches: [WatchRoot] { visible(watches, .watches, id: \.id) { [$0.path] } }
    var visibleLoginItems: [LoginItem] { visible(loginItems, .loginItems, id: \.id) { [$0.name, $0.path] } }
    var visibleCron: [CronEntry] { visible(cron, .cron, id: { String($0.id) }) { [$0.schedule, $0.command] } }
    var visibleBrew: [BrewService] { visible(brew, .brew, id: \.id) { [$0.name, $0.status, $0.file] } }
    var visibleContainers: [Container] {
        visible(containers, .containers, id: \.id) { [$0.name, $0.image, $0.project, $0.ports, $0.engine] }
    }
    var visiblePorts: [ListeningPort] {
        visible(ports, .ports, id: \.id) { [$0.address, $0.command, String($0.pid)] }
    }
    var visibleExtensions: [SystemExtension] {
        visible(extensions, .extensions, id: \.id) { [$0.name, $0.bundleID, $0.category, $0.teamID] }
    }

    func count(for sidebar: SidebarItem) -> Int? {
        switch sidebar {
        case .overview, .processes: nil
        case .running: visibleProcesses.count
        case .jobs: visibleJobs.count
        case .watches: visibleWatches.count
        case .loginItems: loginItemsRequested ? visibleLoginItems.count : nil
        case .cron: visibleCron.count
        case .brew: visibleBrew.count
        case .containers: visibleContainers.count
        case .ports: visiblePorts.count
        case .extensions: visibleExtensions.count
        }
    }

    // MARK: Selection helpers

    var selectedProcesses: [RunningItem] { processes.filter { selectedProcessIDs.contains($0.id) } }
    var selectedJobs: [LaunchItem] { jobs.filter { selectedJobIDs.contains($0.id) } }
    var selectedWatches: [WatchRoot] { watches.filter { selectedWatchIDs.contains($0.id) } }
    var selectedLoginItems: [LoginItem] { loginItems.filter { selectedLoginItemIDs.contains($0.id) } }
    var selectedCron: [CronEntry] { cron.filter { selectedCronIDs.contains($0.id) } }
    var selectedBrew: [BrewService] { brew.filter { selectedBrewIDs.contains($0.id) } }
    var selectedContainers: [Container] { containers.filter { selectedContainerIDs.contains($0.id) } }
    var selectedPorts: [ListeningPort] { ports.filter { selectedPortIDs.contains($0.id) } }
    var selectedExtensions: [SystemExtension] { extensions.filter { selectedExtensionIDs.contains($0.id) } }

    func loginJob(for process: RunningItem) -> LaunchItem? {
        JobMatching.job(for: process, in: jobs)
    }

    // MARK: Refresh

    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        async let jobsTask = Task.detached { try Launchctl.inventory() }.value
        async let procsTask = Task.detached { try UserProcesses.inventory() }.value
        async let watchTask = Task.detached { () -> (Bool, [WatchRoot]) in
            guard Watchman.isAvailable else { return (false, []) }
            return (true, (try? Watchman.list()) ?? [])
        }.value
        async let cronTask = Task.detached { Result { try Cron.list() } }.value
        async let brewTask = Task.detached { (BrewServices.isAvailable, Result { try BrewServices.list() }) }.value
        async let containerTask = Task.detached { (Containers.available, Containers.list()) }.value
        async let portsTask = Task.detached { Result { try Ports.listening() } }.value
        async let extTask = Task.detached { Result { try Extensions.list() } }.value

        do {
            let loadedJobs = try await jobsTask
            let loadedProcs = try await procsTask
            notifyNewJobs(loadedJobs)
            jobs = loadedJobs
            processes = loadedProcs
        } catch {
            errorMessage = error.localizedDescription
        }
        (watchmanAvailable, watches) = await watchTask
        cron = take(await cronTask, .cron) ?? cron
        let (hasBrew, brewResult) = await brewTask
        brewAvailable = hasBrew
        brew = take(brewResult, .brew) ?? brew
        let (engines, containerResult) = await containerTask
        containerEngines = engines
        containers = containerResult.items
        sourceErrors[.containers] = containerResult.errors.isEmpty ? nil : containerResult.errors.joined(separator: "\n")
        ports = take(await portsTask, .ports) ?? ports
        extensions = take(await extTask, .extensions) ?? extensions
        if loginItemsRequested { await refreshLoginItems() }
        pruneSelections()
        status = Self.clock.string(from: Date())
    }

    func refreshLoginItems() async {
        let result = await Task.detached { Result { try LoginItems.list() } }.value
        loginItems = take(result, .loginItems) ?? loginItems
    }

    private func take<T>(_ result: Result<T, Error>, _ section: SidebarItem) -> T? {
        switch result {
        case .success(let value):
            sourceErrors[section] = nil
            return value
        case .failure(let error):
            sourceErrors[section] = error.localizedDescription
            return nil
        }
    }

    private func pruneSelections() {
        selectedProcessIDs.formIntersection(processes.map(\.id))
        selectedJobIDs.formIntersection(jobs.map(\.id))
        selectedWatchIDs.formIntersection(watches.map(\.id))
        selectedLoginItemIDs.formIntersection(loginItems.map(\.id))
        selectedCronIDs.formIntersection(cron.map(\.id))
        selectedBrewIDs.formIntersection(brew.map(\.id))
        selectedContainerIDs.formIntersection(containers.map(\.id))
        selectedPortIDs.formIntersection(ports.map(\.id))
        selectedExtensionIDs.formIntersection(extensions.map(\.id))
    }

    private func notifyNewJobs(_ loaded: [LaunchItem]) {
        let fresh = notifier.recordJobs(loaded.filter { !$0.isApple }.map(\.id))
        guard settings.notifyNewJobs, !fresh.isEmpty else { return }
        let labels = loaded.filter { fresh.contains($0.id) }.map(\.label)
        notifier.post(
            title: labels.count == 1 ? "New login job" : "\(labels.count) new login jobs",
            body: labels.prefix(5).joined(separator: "\n")
        )
    }

    // MARK: Running

    func stop(processes items: [RunningItem]) async {
        let owned = items.map { ($0, loginJob(for: $0)) }
        await mutate(items.count == 1 ? "Stopped \(items[0].name)" : "Stopped \(items.count) processes") {
            for (process, job) in owned {
                // A KeepAlive job would restart a killed process, so unload the job instead.
                if let job, job.canStop {
                    try Launchctl.stop(job)
                } else {
                    try UserProcesses.stop(process)
                }
            }
        }
    }

    /// Only meaningful when a login job owns the process; the UI offers Stop otherwise.
    func purge(processes items: [RunningItem]) async {
        let owned = items.compactMap { loginJob(for: $0) }
        await mutate("Purged \(owned.count) login job\(owned.count == 1 ? "" : "s")") {
            for job in owned { try Launchctl.purge(job) }
        }
    }

    // MARK: Jobs

    func stop(jobs items: [LaunchItem]) async {
        await mutate(plural("Stopped", items.map(\.label))) { for job in items where job.canStop { try Launchctl.stop(job) } }
    }

    func start(jobs items: [LaunchItem]) async {
        await mutate(plural("Started", items.map(\.label))) {
            for job in items {
                if job.disabled { try Launchctl.enable(job) }
                try Launchctl.start(job)
            }
        }
    }

    func disable(jobs items: [LaunchItem]) async {
        await mutate(plural("Disabled", items.map(\.label))) { for job in items { try Launchctl.disable(job) } }
    }

    func enable(jobs items: [LaunchItem]) async {
        await mutate(plural("Enabled", items.map(\.label))) { for job in items { try Launchctl.enable(job) } }
    }

    func purge(jobs items: [LaunchItem]) async {
        await mutate(plural("Purged", items.map(\.label))) { for job in items { try Launchctl.purge(job) } }
        selectedJobIDs = []
    }

    // MARK: Watches

    func drop(_ roots: [WatchRoot]) async {
        await mutate(plural("Dropped", roots.map(\.path))) { for root in roots { try Watchman.drop(root) } }
        selectedWatchIDs = []
    }

    func dropAllWatches() async {
        await mutate("Dropped all watches") { try Watchman.dropAll() }
        selectedWatchIDs = []
    }

    // MARK: Other sources

    func remove(loginItems items: [LoginItem]) async {
        await mutate(plural("Removed", items.map(\.name))) { for item in items { try LoginItems.remove(item) } }
        selectedLoginItemIDs = []
        await refreshLoginItems()
    }

    /// Cron ids are line numbers, so edit from the bottom up to keep earlier lines in place.
    func remove(cron items: [CronEntry]) async {
        let ordered = items.sorted { $0.line > $1.line }
        await mutate(plural("Removed", items.map(\.command))) { for entry in ordered { try Cron.remove(entry) } }
        selectedCronIDs = []
    }

    func setEnabled(cron items: [CronEntry], _ enabled: Bool) async {
        await mutate(plural(enabled ? "Enabled" : "Disabled", items.map(\.command))) {
            for entry in items { try Cron.setEnabled(entry, enabled) }
        }
    }

    func perform(_ action: BrewServices.Action, brew items: [BrewService]) async {
        await mutate(plural(action.rawValue.capitalized + "ed", items.map(\.name))) {
            for service in items { try BrewServices.perform(action, on: service) }
        }
    }

    func perform(_ action: Containers.Action, containers items: [Container]) async {
        let verb = switch action {
        case .start: "Started"
        case .stop: "Stopped"
        case .restart: "Restarted"
        case .remove: "Removed"
        }
        await mutate(plural(verb, items.map(\.name))) {
            for container in items { try Containers.perform(action, on: container) }
        }
        if action == .remove { selectedContainerIDs = [] }
    }

    func stop(ports items: [ListeningPort]) async {
        let pids = Array(Set(items.map(\.pid)))
        await mutate("Stopped \(pids.count) process\(pids.count == 1 ? "" : "es")") {
            try Signals.terminate(pids)
        }
    }

    // MARK: Finder

    func reveal(_ paths: [String]) {
        let urls = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else {
            errorMessage = "Not on disk:\n" + paths.joined(separator: "\n")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: Plumbing

    func confirm(_ title: String, _ message: String, _ label: String, _ action: @escaping () async -> Void) {
        pending = PendingConfirm(title: title, message: message, confirmLabel: label) {
            Task { await action() }
        }
    }

    private func plural(_ verb: String, _ names: [String]) -> String {
        names.count == 1 ? "\(verb) \(names[0])" : "\(verb) \(names.count) items"
    }

    private func mutate(_ success: String, _ work: @escaping @Sendable () throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await Task.detached(operation: work).value
            status = success
        } catch {
            if let shell = error as? ShellError, case .cancelled = shell { return }
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}
