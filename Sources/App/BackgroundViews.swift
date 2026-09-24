import SwiftUI
import BackgroundsCore

// MARK: Running

struct RunningTable: View {
    @Bindable var store: Store
    let monitor: SystemMonitor

    var body: some View {
        Table(store.visibleProcesses, selection: $store.selectedProcessIDs) {
            TableColumn("Name") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(item.kind == .app ? "app" : "background")
                        if store.loginJob(for: item) != nil { Text("· login job") }
                        if store.isHidden(.running, item.id) { Text("· hidden") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            TableColumn("PID") { item in
                Text(item.extraPIDs.isEmpty ? String(item.pid) : "\(item.pid) +\(item.extraPIDs.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("CPU") { item in
                Text(String(format: "%.1f%%", monitor.displayCPU(monitor.cpu(for: item), perCore: store.settings.cpuPerCore)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(60)
            TableColumn("Memory") { item in
                Text("\(item.memoryMB) MB")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)
        }
        .contextMenu(forSelectionType: RunningItem.ID.self) { ids in
            let items = store.processes.filter { ids.contains($0.id) }
            if !items.isEmpty { RunningActions(store: store, items: items) }
        }
        .overlay {
            if store.visibleProcesses.isEmpty {
                ContentUnavailableView("Nothing user-started is running", systemImage: "tray")
            }
        }
    }
}

struct RunningActions: View {
    let store: Store
    let items: [RunningItem]

    var body: some View {
        Button("Stop") { Task { await store.stop(processes: items) } }
        // Purge only means something when a login job would bring it back.
        let owned = items.compactMap { store.loginJob(for: $0) }
        if !owned.isEmpty {
            Button("Purge login job…", role: .destructive) {
                store.confirm(
                    owned.count == 1 ? "Purge this login job?" : "Purge \(owned.count) login jobs?",
                    "Unload and delete:\n" + owned.map(\.plistPath).joined(separator: "\n"),
                    "Purge"
                ) { await store.purge(processes: items) }
            }
        }
        Divider()
        Button("Reveal in Finder") { store.reveal(items.map(\.path)) }
        HideButton(store: store, section: .running, ids: items.map(\.id))
    }
}

struct RunningDetail: View {
    let store: Store
    let monitor: SystemMonitor

    var body: some View {
        let items = store.selectedProcesses
        if items.count > 1 {
            MultiSelection(count: items.count) {
                Button("Stop all") { Task { await store.stop(processes: items) } }
            }
        } else if let item = items.first {
            let job = store.loginJob(for: item)
            Form {
                Section {
                    HStack {
                        Button("Stop") { Task { await store.stop(processes: [item]) } }
                        Button("Reveal") { store.reveal([item.path]) }
                        Spacer()
                        if job != nil {
                            Button("Purge…", role: .destructive) {
                                store.confirm("Purge this login job?", "Unload and delete:\n\(job!.plistPath)", "Purge") {
                                    await store.purge(processes: [item])
                                }
                            }
                        }
                    }
                }
                Section("Running") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Kind", value: item.kind == .app ? "app" : "background")
                    LabeledContent("PID", value: String(item.pid))
                    if !item.extraPIDs.isEmpty {
                        LabeledContent("Other PIDs", value: item.extraPIDs.map(String.init).joined(separator: ", "))
                    }
                    LabeledContent("CPU", value: String(format: "%.1f%%", monitor.displayCPU(monitor.cpu(for: item), perCore: store.settings.cpuPerCore)))
                    LabeledContent("Memory", value: "\(item.memoryMB) MB")
                }
                Section("Command") { Mono(item.command) }
                if let job {
                    Section("Login job") {
                        LabeledContent("Label", value: job.label)
                        Mono(job.plistPath)
                        Text("Stop unloads this job, since it would restart the process. Purge deletes it for good.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("No login job owns this, so it won't come back by itself after Stop.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select something running", systemImage: "play.circle")
        }
    }
}

// MARK: Login jobs

struct JobTable: View {
    @Bindable var store: Store

    var body: some View {
        Table(store.visibleJobs, selection: $store.selectedJobIDs) {
            TableColumn("Status") { item in StatusBadge(state: item.state) }
                .width(min: 90, ideal: 110)
            TableColumn("Name") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).lineLimit(1)
                    if let program = item.program {
                        Text(URL(fileURLWithPath: program).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            TableColumn("PID") { item in
                Text(item.pid.map(String.init) ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(60)
            TableColumn("Starts") { item in
                HStack(spacing: 6) {
                    if item.keepAlive { Flag("stays up") }
                    if item.runAtLoad { Flag("at login") }
                    if let interval = item.startInterval { Flag("every \(interval)s") }
                    if let cal = item.calendarHint { Flag(cal) }
                    if item.scope == .daemon { Flag("daemon") }
                }
            }
        }
        .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
            let items = store.jobs.filter { ids.contains($0.id) }
            if !items.isEmpty { JobActions(store: store, items: items) }
        }
        .overlay {
            if store.visibleJobs.isEmpty {
                ContentUnavailableView("No login jobs", systemImage: "tray")
            }
        }
    }
}

struct JobActions: View {
    let store: Store
    let items: [LaunchItem]

    var body: some View {
        if items.contains(where: \.canStop) {
            Button("Stop") { Task { await store.stop(jobs: items.filter(\.canStop)) } }
        }
        if items.contains(where: { !$0.listed && !$0.isEmptyPlist }) {
            Button("Start") { Task { await store.start(jobs: items.filter { !$0.listed && !$0.isEmptyPlist }) } }
        }
        if items.contains(where: { !$0.disabled && !$0.isEmptyPlist }) {
            Button("Disable (keep plist)") { Task { await store.disable(jobs: items.filter { !$0.disabled }) } }
        }
        if items.contains(where: \.disabled) {
            Button("Enable") { Task { await store.enable(jobs: items.filter(\.disabled)) } }
        }
        Divider()
        Button("Reveal plist in Finder") { store.reveal(items.map(\.plistPath)) }
        if items.count == 1 {
            Button("Open plist") { store.open(items[0].plistPath) }
        }
        HideButton(store: store, section: .jobs, ids: items.map(\.id))
        Divider()
        Button("Purge…", role: .destructive) {
            store.confirm(
                items.count == 1 ? "Purge this login job?" : "Purge \(items.count) login jobs?",
                "Unload and delete:\n" + items.map(\.plistPath).joined(separator: "\n") + "\n\nThis cannot be undone.",
                "Purge"
            ) { await store.purge(jobs: items) }
        }
    }
}

struct JobDetail: View {
    let store: Store

    var body: some View {
        let items = store.selectedJobs
        if items.count > 1 {
            MultiSelection(count: items.count) { JobActions(store: store, items: items) }
        } else if let item = items.first {
            Form {
                Section {
                    HStack {
                        if item.canStop { Button("Stop") { Task { await store.stop(jobs: [item]) } } }
                        if !item.listed && !item.isEmptyPlist { Button("Start") { Task { await store.start(jobs: [item]) } } }
                        if item.disabled {
                            Button("Enable") { Task { await store.enable(jobs: [item]) } }
                        } else if !item.isEmptyPlist {
                            Button("Disable") { Task { await store.disable(jobs: [item]) } }
                                .help("Unload and keep it from loading at login. The plist stays.")
                        }
                        Spacer()
                        Button("Purge…", role: .destructive) {
                            store.confirm("Purge this login job?", "Unload and delete:\n\(item.plistPath)\n\nThis cannot be undone.", "Purge") {
                                await store.purge(jobs: [item])
                            }
                        }
                    }
                }
                Section("Login job") {
                    LabeledContent("Name", value: item.label)
                    LabeledContent("State") { StatusBadge(state: item.state) }
                    LabeledContent("Where", value: item.scope.title)
                    if let pid = item.pid { LabeledContent("PID", value: String(pid)) }
                    if let reason = item.exitDescription { LabeledContent("Last exit", value: reason) }
                }
                Section("Program") {
                    LabeledContent("Binary", value: item.program ?? "—")
                    if item.arguments.count > 1 {
                        LabeledContent("Args") {
                            Text(item.arguments.dropFirst().joined(separator: " ")).textSelection(.enabled)
                        }
                    }
                    LabeledContent("Stays up", value: item.keepAlive ? "yes" : "no")
                    LabeledContent("At login", value: item.runAtLoad ? "yes" : "no")
                    if let interval = item.startInterval { LabeledContent("Interval", value: "\(interval)s") }
                    if let cal = item.calendarHint { LabeledContent("Calendar", value: cal) }
                }
                Section("Plist") {
                    Mono(item.plistPath)
                    HStack {
                        Button("Reveal") { store.reveal([item.plistPath]) }
                        Button("Open") { store.open(item.plistPath) }
                    }
                    if item.scope.controlNeedsAdmin {
                        Text("Stop, start and disable need an admin password.").foregroundStyle(.secondary)
                    } else if item.scope.needsAdmin {
                        Text("Purge needs an admin password.").foregroundStyle(.secondary)
                    }
                }
                ForEach(item.logPaths, id: \.self) { path in
                    LogSection(store: store, path: path, isError: path == item.stderrPath && path != item.stdoutPath)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a login job", systemImage: "clock")
        }
    }
}

struct LogSection: View {
    let store: Store
    let path: String
    let isError: Bool
    @State private var text: String?

    var body: some View {
        Section(isError ? "Error log" : "Log") {
            Mono(path)
            if let text {
                ScrollView {
                    Text(text.isEmpty ? "(empty)" : text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            } else {
                Text("Not on disk yet.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Reload") { load() }
                Button("Open") { store.open(path) }.disabled(text == nil)
            }
        }
        .task(id: path) { load() }
    }

    private func load() { text = Launchctl.tail(path) }
}

// MARK: Watches

struct WatchTable: View {
    @Bindable var store: Store

    var body: some View {
        if !store.watchmanAvailable {
            SourceUnavailable(title: "watchman not installed", symbol: "eye.slash", message: "Install with Homebrew to manage leftover watches.")
        } else {
            Table(store.visibleWatches, selection: $store.selectedWatchIDs) {
                TableColumn("Path") { root in
                    Text(root.path).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("On disk") { root in
                    Text(root.exists ? "yes" : "missing")
                        .foregroundStyle(root.exists ? Color.secondary : Color.orange)
                }
                .width(80)
            }
            .contextMenu(forSelectionType: WatchRoot.ID.self) { ids in
                let roots = store.watches.filter { ids.contains($0.id) }
                if !roots.isEmpty {
                    Button("Reveal in Finder") { store.reveal(roots.map(\.path)) }
                    HideButton(store: store, section: .watches, ids: roots.map(\.id))
                    Divider()
                    Button("Drop…", role: .destructive) { confirmDrop(roots) }
                }
            }
            .overlay {
                if store.visibleWatches.isEmpty {
                    ContentUnavailableView("No leftover watches", systemImage: "eye")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button("Drop all…", role: .destructive) {
                        store.confirm("Drop every leftover watch?", "watchman will stop watching \(store.watches.count) roots.", "Drop all") {
                            await store.dropAllWatches()
                        }
                    }
                    .disabled(store.watches.isEmpty || store.isBusy)
                }
                .padding(10)
            }
        }
    }

    private func confirmDrop(_ roots: [WatchRoot]) {
        store.confirm(roots.count == 1 ? "Drop this watch?" : "Drop \(roots.count) watches?", roots.map(\.path).joined(separator: "\n"), "Drop") {
            await store.drop(roots)
        }
    }
}

struct WatchDetail: View {
    let store: Store

    var body: some View {
        let roots = store.selectedWatches
        if roots.count > 1 {
            MultiSelection(count: roots.count) {
                Button("Drop all selected", role: .destructive) {
                    store.confirm("Drop \(roots.count) watches?", roots.map(\.path).joined(separator: "\n"), "Drop") {
                        await store.drop(roots)
                    }
                }
            }
        } else if let root = roots.first {
            Form {
                Section("Watch") {
                    Mono(root.path)
                    LabeledContent("On disk", value: root.exists ? "yes" : "missing")
                    HStack {
                        Button("Reveal") { store.reveal([root.path]) }.disabled(!root.exists)
                        Spacer()
                        Button("Drop…", role: .destructive) {
                            store.confirm("Drop this watch?", root.path, "Drop") { await store.drop([root]) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a watch", systemImage: "eye")
        }
    }
}
