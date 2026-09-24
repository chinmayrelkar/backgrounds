import SwiftUI
import BackgroundsCore

/// Every process on the machine, btop's process box: sortable, tree view, filter, signals.
struct ProcessesView: View {
    @Bindable var store: Store
    @Bindable var monitor: SystemMonitor
    @State private var selection: Set<Int> = []
    @State private var sortOrder = [KeyPathComparator(\ProcessNode.row.cpuPercent, order: .reverse)]

    var body: some View {
        let nodes = monitor.rows(query: store.query)
        let perCore = store.settings.cpuPerCore
        Table(nodes, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \ProcessNode.row.name) { node in
                HStack(spacing: 4) {
                    if monitor.treeMode {
                        Color.clear.frame(width: CGFloat(node.depth) * 12, height: 1)
                        if node.hasChildren {
                            Button {
                                monitor.toggleCollapse(node.row.pid)
                            } label: {
                                Image(systemName: monitor.collapsed.contains(node.row.pid) ? "chevron.right" : "chevron.down")
                                    .font(.caption2)
                                    .frame(width: 12)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Color.clear.frame(width: 12, height: 1)
                        }
                    }
                    Text(node.row.name).lineLimit(1)
                        .foregroundStyle(node.row.state.hasPrefix("Z") ? .secondary : .primary)
                }
                .help(node.row.command)
            }
            .width(min: 160, ideal: 220)
            TableColumn("PID", value: \ProcessNode.row.pid) { node in
                Text(String(node.row.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("User", value: \ProcessNode.row.user) { node in
                Text(node.row.user).foregroundStyle(node.row.isOwn ? .primary : .secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 80)
            TableColumn("CPU", value: \ProcessNode.row.cpuPercent) { node in
                let cpu = monitor.displayCPU(monitor.treeMode ? node.treeCPU : node.row.cpuPercent, perCore: perCore)
                Text(String(format: "%.1f", cpu))
                    .monospacedDigit()
                    .foregroundStyle(cpu >= (perCore ? 50 : 50.0 / Double(monitor.host.logicalCores)) ? .red : .primary)
            }
            .width(55)
            TableColumn("Memory", value: \ProcessNode.row.residentBytes) { node in
                Text(Format.bytes(monitor.treeMode ? node.treeMemory : node.row.residentBytes)).monospacedDigit()
            }
            .width(75)
            TableColumn("Threads", value: \ProcessNode.threadSortKey) { node in
                Text(node.row.threads.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(55)
            TableColumn("State", value: \ProcessNode.row.state) { node in
                Text(node.row.stateTitle).foregroundStyle(.secondary)
            }
            .width(65)
            TableColumn("Time", value: \ProcessNode.row.cpuTime) { node in
                Text(Format.duration(node.row.cpuTime)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("Disk", value: \ProcessNode.diskSortKey) { node in
                let rate = node.row.diskReadRate + node.row.diskWriteRate
                Text(rate > 0 ? Format.rate(rate) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(75)
        }
        .contextMenu(forSelectionType: Int.self) { pids in
            let rows = (monitor.latest?.processes ?? []).filter { pids.contains($0.pid) }
            if !rows.isEmpty { SignalMenu(store: store, rows: rows) }
        }
        .onChange(of: sortOrder) { _, order in applySort(order) }
        .onChange(of: selection) { _, pids in
            monitor.selectedPID = pids.count == 1 ? pids.first : nil
        }
        .onAppear {
            if let pid = monitor.selectedPID { selection = [pid] }
        }
        .safeAreaInset(edge: .top, spacing: 0) { controls }
        .overlay {
            if monitor.latest == nil { ProgressView("Sampling…") }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $monitor.treeMode) { Label("Tree", systemImage: "list.bullet.indent") }
                .toggleStyle(.button)
                .help("Group by parent process. Turns off while filtering.")
            Toggle(isOn: $monitor.onlyMine) { Label("Mine", systemImage: "person") }
                .toggleStyle(.button)
                .help("Only processes you own")
            Toggle(isOn: $store.settings.cpuPerCore) { Text("Per core") }
                .toggleStyle(.button)
                .help("On: 100% is one core. Off: 100% is the whole CPU.")
            if monitor.treeMode {
                Button("Collapse all") {
                    monitor.collapsed = Set((monitor.latest?.processes ?? []).map(\.ppid))
                }
                Button("Expand all") { monitor.collapsed = [] }
            }
            Spacer()
            Text("\(monitor.latest?.processes.count ?? 0) processes")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func applySort(_ order: [KeyPathComparator<ProcessNode>]) {
        guard let first = order.first else { return }
        let map: [PartialKeyPath<ProcessNode>: ProcessSort] = [
            \ProcessNode.row.cpuPercent: .cpu,
            \ProcessNode.row.residentBytes: .memory,
            \ProcessNode.row.pid: .pid,
            \ProcessNode.row.name: .name,
            \ProcessNode.row.user: .user,
            \ProcessNode.threadSortKey: .threads,
            \ProcessNode.row.cpuTime: .time,
            \ProcessNode.diskSortKey: .disk,
            \ProcessNode.row.state: .state,
        ]
        monitor.sort = map[first.keyPath] ?? .cpu
        monitor.sortDescending = first.order == .reverse
    }
}

extension ProcessNode {
    var threadSortKey: Int { row.threads ?? -1 }
    var diskSortKey: Double { row.diskReadRate + row.diskWriteRate }
}

/// Stop plus every signal btop offers, for one or more processes.
struct SignalMenu: View {
    let store: Store
    let rows: [ProcessRow]

    var body: some View {
        let others = rows.filter { !$0.isOwn }
        Button("Stop (TERM, then KILL)") {
            confirm("Stop", detail: "SIGTERM, then SIGKILL after 3 seconds.") {
                try Signals.terminate(rows.map(\.pid), allowAdmin: !others.isEmpty)
            }
        }
        Menu("Send signal") {
            ForEach(Signals.all) { sig in
                Button("\(sig.name) — \(sig.meaning)") {
                    confirm(sig.name, detail: sig.meaning) {
                        for row in rows { try Signals.send(sig.number, to: row.pid, allowAdmin: !row.isOwn) }
                    }
                }
            }
        }
        Menu("Priority") {
            ForEach([-20, -10, -5, 0, 5, 10, 20], id: \.self) { value in
                Button(value == 0 ? "0 (normal)" : value < 0 ? "\(value) (higher, needs admin)" : "+\(value) (lower)") {
                    run("Set priority \(value)") {
                        for row in rows { try ProcessList.renice(row.pid, to: value) }
                    }
                }
            }
        }
        Divider()
        Button("Reveal in Finder") { store.reveal(rows.map(\.path)) }
        Button("Copy command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rows.map(\.command).joined(separator: "\n"), forType: .string)
        }
    }

    private func confirm(_ verb: String, detail: String, _ work: @escaping @Sendable () throws -> Void) {
        let names = rows.prefix(8).map { "\($0.name) (\($0.pid)) · \($0.user)" }.joined(separator: "\n")
        let more = rows.count > 8 ? "\n+\(rows.count - 8) more" : ""
        let admin = rows.contains { !$0.isOwn } ? "\n\nSome belong to another user. macOS will ask for your password." : ""
        store.confirm("\(verb) \(rows.count == 1 ? rows[0].name : "\(rows.count) processes")?", detail + "\n\n" + names + more + admin, verb) {
            await runAsync(verb, work)
        }
    }

    private func run(_ label: String, _ work: @escaping @Sendable () throws -> Void) {
        Task { await runAsync(label, work) }
    }

    @MainActor
    private func runAsync(_ label: String, _ work: @escaping @Sendable () throws -> Void) async {
        do {
            try await Task.detached(operation: work).value
            store.status = label
        } catch {
            if let shell = error as? ShellError, case .cancelled = shell { return }
            store.errorMessage = error.localizedDescription
        }
    }
}

/// btop's detailed process view: graphs, stats, parent/children, actions.
struct ProcessInspector: View {
    let store: Store
    let monitor: SystemMonitor

    var body: some View {
        if let row = monitor.selectedProcess {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.title3).bold()
                        Text("PID \(row.pid) · \(row.user) · \(row.stateTitle)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Menu("Actions") { SignalMenu(store: store, rows: [row]) }
                            .fixedSize()
                        Spacer()
                    }
                }
                Section("CPU") {
                    LabeledContent("Now", value: String(format: "%.1f%%", monitor.displayCPU(row.cpuPercent, perCore: store.settings.cpuPerCore)))
                    HistoryGraph(values: monitor.pidCPU.values, color: .accentColor, maxValue: nil, height: 50)
                    LabeledContent("CPU time", value: Format.duration(row.cpuTime))
                    LabeledContent("Priority / nice", value: "\(row.priority) / \(row.nice)")
                    if let threads = row.threads { LabeledContent("Threads", value: String(threads)) }
                }
                Section("Memory") {
                    LabeledContent("Resident", value: Format.bytes(row.residentBytes))
                    HistoryGraph(values: monitor.pidMemory.values, color: .blue, maxValue: nil, height: 50)
                    LabeledContent("Virtual", value: Format.bytes(row.virtualBytes))
                    if let total = monitor.latest?.memory.total, total > 0 {
                        LabeledContent("Share", value: Format.percent(Double(row.residentBytes) / Double(total), digits: 1))
                    }
                }
                if let read = row.diskReadBytes, let write = row.diskWriteBytes {
                    Section("Disk") {
                        LabeledContent("Read", value: "\(Format.bytes(read)) · \(Format.rate(row.diskReadRate))")
                        LabeledContent("Written", value: "\(Format.bytes(write)) · \(Format.rate(row.diskWriteRate))")
                    }
                }
                Section("Process") {
                    LabeledContent("Started", value: Format.duration(row.elapsed) + " ago")
                    if let parent = monitor.parent(of: row) {
                        LabeledContent("Parent") {
                            Button("\(parent.name) (\(parent.pid))") { monitor.selectedPID = parent.pid }
                                .buttonStyle(.link)
                        }
                    }
                    let kids = monitor.children(of: row.pid)
                    if !kids.isEmpty {
                        LabeledContent("Children", value: String(kids.count))
                    }
                    Mono(row.path)
                }
                Section("Command") { Mono(row.command) }
                if !row.isOwn {
                    Section {
                        Text("Owned by \(row.user). Threads and disk I/O need admin to read; signals will ask for your password.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a process", systemImage: "list.bullet.indent", description: Text("Right-click rows to send signals or change priority."))
        }
    }
}
