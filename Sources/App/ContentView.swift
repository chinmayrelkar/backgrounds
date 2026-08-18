import SwiftUI
import BackgroundsCore

struct ContentView: View {
    @State private var store = Store()
    @State private var pendingJobPurge: LaunchItem?
    @State private var pendingProcessPurge: RunningItem?
    @State private var pendingDrop: WatchRoot?
    @State private var confirmDropAll = false

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $store.selectedSidebar) { item in
                Label {
                    HStack {
                        Text(item.title)
                        Spacer()
                        Text("\(store.count(for: item))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: item.symbol)
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } content: {
            middleColumn
                .navigationTitle(store.selectedSidebar.title)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
                .toolbar { detailToolbar }
        }
        .searchable(text: $store.query, prompt: "Filter")
        .toolbar { toolbar }
        .task { await store.refresh() }
        .modifier(Confirmations(
            store: store,
            pendingJobPurge: $pendingJobPurge,
            pendingProcessPurge: $pendingProcessPurge,
            pendingDrop: $pendingDrop,
            confirmDropAll: $confirmDropAll
        ))
    }

    @ViewBuilder
    private var middleColumn: some View {
        switch store.selectedSidebar {
        case .running:
            ProcessTable(
                store: store,
                onStop: { item in Task { await store.stop(process: item) } },
                onPurge: { pendingProcessPurge = $0 }
            )
        case .jobs:
            JobTable(
                store: store,
                onStop: { item in Task { await store.stop(job: item) } },
                onStart: { item in Task { await store.start(job: item) } },
                onPurge: { pendingJobPurge = $0 }
            )
        case .watches:
            WatchTable(
                store: store,
                onDrop: { pendingDrop = $0 },
                onDropAll: { confirmDropAll = true }
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedSidebar {
        case .running:
            if let item = store.selectedProcess {
                ProcessDetail(
                    item: item,
                    job: store.loginJob(for: item),
                    onStop: { Task { await store.stop(process: item) } },
                    onPurge: { pendingProcessPurge = item }
                )
            } else {
                ContentUnavailableView("Select something running", systemImage: "play.circle")
            }
        case .jobs:
            if let job = store.selectedJob {
                JobDetail(
                    item: job,
                    onStop: { Task { await store.stop(job: job) } },
                    onStart: { Task { await store.start(job: job) } },
                    onPurge: { pendingJobPurge = job }
                )
            } else {
                ContentUnavailableView("Select a login job", systemImage: "clock")
            }
        case .watches:
            if let watch = store.selectedWatch {
                WatchDetail(root: watch)
            } else {
                ContentUnavailableView("Select a watch", systemImage: "eye")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if store.selectedSidebar == .jobs {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $store.showApple) { Text("Apple") }
                    .toggleStyle(.button)
                    .help("Show Apple login jobs")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(store.isBusy)
            .help(store.status.map { "Last refresh \($0)" } ?? "Reload")
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        switch store.selectedSidebar {
        case .running:
            if let item = store.selectedProcess {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Stop") { Task { await store.stop(process: item) } }
                    Button("Purge…", role: .destructive) { pendingProcessPurge = item }
                }
            }
        case .jobs:
            if let job = store.selectedJob {
                ToolbarItemGroup(placement: .primaryAction) {
                    if job.canStop {
                        Button("Stop") { Task { await store.stop(job: job) } }
                    }
                    if job.canStart {
                        Button("Start") { Task { await store.start(job: job) } }
                    }
                    Button("Purge…", role: .destructive) { pendingJobPurge = job }
                }
            }
        case .watches:
            if let watch = store.selectedWatch {
                ToolbarItem(placement: .primaryAction) {
                    Button("Drop…", role: .destructive) { pendingDrop = watch }
                }
            }
        }
    }

}

private struct Confirmations: ViewModifier {
    var store: Store
    @Binding var pendingJobPurge: LaunchItem?
    @Binding var pendingProcessPurge: RunningItem?
    @Binding var pendingDrop: WatchRoot?
    @Binding var confirmDropAll: Bool

    func body(content: Content) -> some View {
        content
            .alert("Something failed", isPresented: errorPresented) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .confirmationDialog(
                "Purge this login job?",
                isPresented: jobPurgePresented,
                presenting: pendingJobPurge
            ) { item in
                Button("Purge", role: .destructive) {
                    Task { await store.purge(job: item) }
                    pendingJobPurge = nil
                }
                Button("Cancel", role: .cancel) { pendingJobPurge = nil }
            } message: { item in
                Text("Unload and delete:\n\(item.plistPath)\n\nThis cannot be undone.")
            }
            .confirmationDialog(
                "Stop and remove this?",
                isPresented: processPurgePresented,
                presenting: pendingProcessPurge
            ) { item in
                Button("Purge", role: .destructive) {
                    Task { await store.purge(process: item) }
                    pendingProcessPurge = nil
                }
                Button("Cancel", role: .cancel) { pendingProcessPurge = nil }
            } message: { item in
                if let job = store.loginJob(for: item) {
                    Text("This also deletes the login job:\n\(job.plistPath)")
                } else {
                    Text("No login job. This just stops \(item.name).")
                }
            }
            .confirmationDialog(
                "Drop this watch?",
                isPresented: dropPresented,
                presenting: pendingDrop
            ) { root in
                Button("Drop", role: .destructive) {
                    Task { await store.drop(root) }
                    pendingDrop = nil
                }
                Button("Cancel", role: .cancel) { pendingDrop = nil }
            } message: { root in
                Text(root.path)
            }
            .confirmationDialog("Drop every leftover watch?", isPresented: $confirmDropAll) {
                Button("Drop all", role: .destructive) {
                    Task { await store.dropAllWatches() }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }

    private var jobPurgePresented: Binding<Bool> {
        Binding(get: { pendingJobPurge != nil }, set: { if !$0 { pendingJobPurge = nil } })
    }

    private var processPurgePresented: Binding<Bool> {
        Binding(get: { pendingProcessPurge != nil }, set: { if !$0 { pendingProcessPurge = nil } })
    }

    private var dropPresented: Binding<Bool> {
        Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } })
    }
}

struct ProcessTable: View {
    @Bindable var store: Store
    var onStop: (RunningItem) -> Void
    var onPurge: (RunningItem) -> Void

    var body: some View {
        Table(store.visibleProcesses, selection: $store.selectedProcessID) {
            TableColumn("Name") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    Text(item.kind == .app ? "app" : "background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn("PID") { item in
                Text(extraPID(item))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("Memory") { item in
                Text("\(item.memoryMB) MB")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)
        }
        .contextMenu(forSelectionType: RunningItem.ID.self) { ids in
            if let item = store.visibleProcesses.first(where: { ids.contains($0.id) }) {
                Button("Stop") { onStop(item) }
                Button("Purge…", role: .destructive) { onPurge(item) }
            }
        }
        .overlay {
            if store.visibleProcesses.isEmpty {
                ContentUnavailableView("Nothing user-started is running", systemImage: "tray")
            }
        }
    }

    private func extraPID(_ item: RunningItem) -> String {
        if item.extraPIDs.isEmpty { return String(item.pid) }
        return "\(item.pid) +\(item.extraPIDs.count)"
    }
}

struct JobTable: View {
    @Bindable var store: Store
    var onStop: (LaunchItem) -> Void
    var onStart: (LaunchItem) -> Void
    var onPurge: (LaunchItem) -> Void

    var body: some View {
        Table(store.visibleJobs, selection: $store.selectedJobID) {
            TableColumn("Status") { item in
                StatusBadge(state: item.state)
            }
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
                }
            }
        }
        .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
            if let item = store.visibleJobs.first(where: { ids.contains($0.id) }) {
                if item.canStop { Button("Stop") { onStop(item) } }
                if item.canStart { Button("Start") { onStart(item) } }
                Divider()
                Button("Purge…", role: .destructive) { onPurge(item) }
            }
        }
        .overlay {
            if store.visibleJobs.isEmpty {
                ContentUnavailableView("No login jobs", systemImage: "tray")
            }
        }
    }
}

struct WatchTable: View {
    @Bindable var store: Store
    var onDrop: (WatchRoot) -> Void
    var onDropAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !store.watchmanAvailable {
                ContentUnavailableView(
                    "watchman not installed",
                    systemImage: "eye.slash",
                    description: Text("Install with Homebrew to manage leftover watches.")
                )
            } else {
                Table(store.visibleWatches, selection: $store.selectedWatchID) {
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
                    if let root = store.visibleWatches.first(where: { ids.contains($0.id) }) {
                        Button("Drop…", role: .destructive) { onDrop(root) }
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
                        Button("Drop all…", role: .destructive, action: onDropAll)
                            .disabled(store.watches.isEmpty || store.isBusy)
                    }
                    .padding(10)
                }
            }
        }
    }
}

struct ProcessDetail: View {
    let item: RunningItem
    let job: LaunchItem?
    var onStop: () -> Void
    var onPurge: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Stop", action: onStop)
                    Spacer()
                    Button("Purge…", role: .destructive, action: onPurge)
                }
            }
            Section("Running") {
                LabeledContent("Name", value: item.name)
                LabeledContent("Kind", value: item.kind == .app ? "app" : "background")
                LabeledContent("PID", value: String(item.pid))
                if !item.extraPIDs.isEmpty {
                    LabeledContent("Other PIDs", value: item.extraPIDs.map(String.init).joined(separator: ", "))
                }
                LabeledContent("Memory", value: "\(item.memoryMB) MB")
            }
            Section("Command") {
                Text(item.command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let job {
                Section("Login job") {
                    LabeledContent("Label", value: job.label)
                    Text(job.plistPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Purge will delete this job so it does not come back at login.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

struct JobDetail: View {
    let item: LaunchItem
    var onStop: () -> Void
    var onStart: () -> Void
    var onPurge: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    if item.canStop { Button("Stop", action: onStop) }
                    if item.canStart { Button("Start", action: onStart) }
                    Spacer()
                    Button("Purge…", role: .destructive, action: onPurge)
                }
            }
            Section("Login job") {
                LabeledContent("Name", value: item.label)
                LabeledContent("State") { StatusBadge(state: item.state) }
                LabeledContent("Where", value: item.scope.title)
                if let pid = item.pid {
                    LabeledContent("PID", value: String(pid))
                }
                if let code = item.lastExit {
                    LabeledContent("Last exit", value: String(code))
                }
            }
            Section("Program") {
                LabeledContent("Binary", value: item.program ?? "—")
                if item.arguments.count > 1 {
                    LabeledContent("Args") {
                        Text(item.arguments.dropFirst().joined(separator: " "))
                            .textSelection(.enabled)
                    }
                }
                Toggle("Stays up", isOn: .constant(item.keepAlive)).disabled(true)
                Toggle("At login", isOn: .constant(item.runAtLoad)).disabled(true)
                if let interval = item.startInterval {
                    LabeledContent("Interval", value: "\(interval)s")
                }
                if let cal = item.calendarHint {
                    LabeledContent("Calendar", value: cal)
                }
            }
            Section("Plist") {
                Text(item.plistPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if item.scope.needsAdmin {
                    Text("Stop and purge need an admin password.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

struct WatchDetail: View {
    let root: WatchRoot

    var body: some View {
        Form {
            Section("Watch") {
                Text(root.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                LabeledContent("On disk", value: root.exists ? "yes" : "missing")
            }
        }
        .formStyle(.grouped)
    }
}

struct StatusBadge: View {
    let state: AgentState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.title)
        }
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .loaded: .blue
        case .failed: .red
        case .emptyPlist: .orange
        case .notLoaded: .secondary
        }
    }
}

struct Flag: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
