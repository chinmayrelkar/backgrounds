import SwiftUI
import BackgroundsCore

struct ContentView: View {
    @Bindable var store: Store
    @Bindable var monitor: SystemMonitor

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedSidebar) {
                Section("System") {
                    ForEach(SidebarItem.system) { row($0) }
                }
                Section("Background") {
                    ForEach(SidebarItem.background) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            middleColumn
                .navigationTitle(store.selectedSidebar.title)
                .navigationSplitViewColumnWidth(min: 460, ideal: 620)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .searchable(text: $store.query, prompt: "Filter")
        .toolbar { toolbar }
        .task {
            monitor.intervalMS = store.settings.monitorIntervalMS
            monitor.start()
            await store.refresh()
        }
        .task(id: store.settings.autoRefreshSeconds) { await autoRefresh() }
        .onChange(of: store.settings.monitorIntervalMS) { _, new in monitor.intervalMS = new }
        .modifier(Confirmations(store: store))
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                Spacer()
                if store.sourceErrors[item] != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(store.sourceErrors[item] ?? "")
                }
                if let count = store.count(for: item) {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: item.symbol)
        }
        .tag(item)
    }

    /// Reload the background lists on a timer. 0 turns it off.
    private func autoRefresh() async {
        let seconds = store.settings.autoRefreshSeconds
        guard seconds > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { break }
            if !store.isBusy && store.pending == nil { await store.refresh() }
        }
    }

    @ViewBuilder
    private var middleColumn: some View {
        switch store.selectedSidebar {
        case .overview: OverviewView(monitor: monitor)
        case .processes: ProcessesView(store: store, monitor: monitor)
        case .running: RunningTable(store: store, monitor: monitor)
        case .jobs: JobTable(store: store)
        case .watches: WatchTable(store: store)
        case .loginItems: LoginItemTable(store: store)
        case .cron: CronTable(store: store)
        case .brew: BrewTable(store: store)
        case .containers: ContainerTable(store: store)
        case .ports: PortTable(store: store)
        case .extensions: ExtensionTable(store: store)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedSidebar {
        case .overview: TopProcesses(store: store, monitor: monitor)
        case .processes: ProcessInspector(store: store, monitor: monitor)
        case .running: RunningDetail(store: store, monitor: monitor)
        case .jobs: JobDetail(store: store)
        case .watches: WatchDetail(store: store)
        case .loginItems: LoginItemDetail(store: store)
        case .cron: CronDetail(store: store)
        case .brew: BrewDetail(store: store)
        case .containers: ContainerDetail(store: store)
        case .ports: PortDetail(store: store)
        case .extensions: ExtensionDetail(store: store)
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
        if SidebarItem.background.contains(store.selectedSidebar) {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $store.settings.showHidden) {
                    Label("Hidden", systemImage: store.settings.showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help("Show items you hid")
            }
        }
        if SidebarItem.system.contains(store.selectedSidebar) {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $monitor.isPaused) {
                    Label(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .toggleStyle(.button)
                .help("Pause sampling")
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
}

private struct Confirmations: ViewModifier {
    @Bindable var store: Store

    func body(content: Content) -> some View {
        content
            .alert("Something failed", isPresented: errorPresented) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .confirmationDialog(
                store.pending?.title ?? "",
                isPresented: pendingPresented,
                presenting: store.pending
            ) { pending in
                Button(pending.confirmLabel, role: .destructive) {
                    store.pending = nil
                    pending.action()
                }
                Button("Cancel", role: .cancel) { store.pending = nil }
            } message: { pending in
                Text(pending.message)
            }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }

    private var pendingPresented: Binding<Bool> {
        Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } })
    }
}

// MARK: Shared bits

struct StatusBadge: View {
    let state: AgentState

    var body: some View {
        Dot(color: color, text: state.title)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .loaded: .blue
        case .failed: .red
        case .emptyPlist: .orange
        case .disabled: .purple
        case .notLoaded: .secondary
        }
    }
}

struct Dot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
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

struct Mono: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }
}

/// Shown in the detail column when several rows are selected.
struct MultiSelection<Actions: View>: View {
    let count: Int
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
            Text("\(count) selected").font(.title3)
            HStack { actions() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SourceUnavailable: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

/// "Hide" / "Unhide" for the context menu, backed by the persisted ignore list.
struct HideButton: View {
    let store: Store
    let section: SidebarItem
    let ids: [String]

    var body: some View {
        let allHidden = !ids.isEmpty && ids.allSatisfy { store.isHidden(section, $0) }
        Button(allHidden ? "Unhide" : "Hide") { store.setHidden(section, ids, !allHidden) }
    }
}
