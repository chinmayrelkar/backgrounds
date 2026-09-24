import SwiftUI
import BackgroundsCore

private struct ErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.orange.opacity(0.1))
        }
    }
}

// MARK: Login items

struct LoginItemTable: View {
    @Bindable var store: Store

    var body: some View {
        Table(store.visibleLoginItems, selection: $store.selectedLoginItemIDs) {
            TableColumn("Name") { item in Text(item.name) }
            TableColumn("Path") { item in
                Text(item.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Hidden") { item in Text(item.hidden ? "yes" : "no").foregroundStyle(.secondary) }
                .width(60)
        }
        .contextMenu(forSelectionType: LoginItem.ID.self) { ids in
            let items = store.loginItems.filter { ids.contains($0.id) }
            if !items.isEmpty {
                Button("Reveal in Finder") { store.reveal(items.map(\.path)) }
                HideButton(store: store, section: .loginItems, ids: items.map(\.id))
                Divider()
                Button("Remove from login…", role: .destructive) { confirmRemove(store, items) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ErrorBanner(message: store.sourceErrors[.loginItems]) }
        .overlay {
            if store.visibleLoginItems.isEmpty && store.sourceErrors[.loginItems] == nil {
                ContentUnavailableView(
                    "No login items",
                    systemImage: "person.crop.circle",
                    description: Text("Apps set to open at login show up here. macOS may ask to let Backgrounds control System Events.")
                )
            }
        }
    }
}

@MainActor
private func confirmRemove(_ store: Store, _ items: [LoginItem]) {
    store.confirm(
        items.count == 1 ? "Stop \(items[0].name) opening at login?" : "Remove \(items.count) login items?",
        "The apps stay installed. They just won't open when you log in.",
        "Remove"
    ) { await store.remove(loginItems: items) }
}

struct LoginItemDetail: View {
    let store: Store

    var body: some View {
        let items = store.selectedLoginItems
        if items.count > 1 {
            MultiSelection(count: items.count) {
                Button("Remove all selected", role: .destructive) { confirmRemove(store, items) }
            }
        } else if let item = items.first {
            Form {
                Section("Login item") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Opens hidden", value: item.hidden ? "yes" : "no")
                    Mono(item.path)
                    HStack {
                        Button("Reveal") { store.reveal([item.path]) }
                        Spacer()
                        Button("Remove…", role: .destructive) { confirmRemove(store, [item]) }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a login item", systemImage: "person.crop.circle")
        }
    }
}

// MARK: Cron

struct CronTable: View {
    @Bindable var store: Store

    var body: some View {
        Table(store.visibleCron, selection: $store.selectedCronIDs) {
            TableColumn("On") { entry in
                Dot(color: entry.enabled ? .green : .secondary, text: entry.enabled ? "on" : "off")
            }
            .width(60)
            TableColumn("Schedule") { entry in Text(entry.schedule).font(.system(.body, design: .monospaced)) }
                .width(min: 110, ideal: 130)
            TableColumn("Command") { entry in Text(entry.command).lineLimit(1).truncationMode(.middle) }
        }
        .contextMenu(forSelectionType: CronEntry.ID.self) { ids in
            let items = store.cron.filter { ids.contains($0.id) }
            if !items.isEmpty { CronActions(store: store, items: items) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ErrorBanner(message: store.sourceErrors[.cron]) }
        .overlay {
            if store.visibleCron.isEmpty && store.sourceErrors[.cron] == nil {
                ContentUnavailableView("No cron jobs", systemImage: "calendar")
            }
        }
    }
}

struct CronActions: View {
    let store: Store
    let items: [CronEntry]

    var body: some View {
        if items.contains(where: { !$0.enabled }) {
            Button("Enable") { Task { await store.setEnabled(cron: items.filter { !$0.enabled }, true) } }
        }
        if items.contains(where: \.enabled) {
            Button("Disable (comment out)") { Task { await store.setEnabled(cron: items.filter(\.enabled), false) } }
        }
        HideButton(store: store, section: .cron, ids: items.map { String($0.id) })
        Divider()
        Button("Remove…", role: .destructive) {
            store.confirm(
                items.count == 1 ? "Remove this cron job?" : "Remove \(items.count) cron jobs?",
                items.map(\.raw).joined(separator: "\n"),
                "Remove"
            ) { await store.remove(cron: items) }
        }
    }
}

struct CronDetail: View {
    let store: Store

    var body: some View {
        let items = store.selectedCron
        if items.count > 1 {
            MultiSelection(count: items.count) { CronActions(store: store, items: items) }
        } else if let entry = items.first {
            Form {
                Section("Cron job") {
                    LabeledContent("Schedule", value: entry.schedule)
                    LabeledContent("Enabled", value: entry.enabled ? "yes" : "no (commented out)")
                    LabeledContent("Line", value: String(entry.line + 1))
                }
                Section("Command") { Mono(entry.command) }
                Section { HStack { CronActions(store: store, items: [entry]) } }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a cron job", systemImage: "calendar")
        }
    }
}

// MARK: Brew services

struct BrewTable: View {
    @Bindable var store: Store

    var body: some View {
        if !store.brewAvailable {
            SourceUnavailable(title: "Homebrew not installed", symbol: "mug", message: "brew services only exist with Homebrew.")
        } else {
            Table(store.visibleBrew, selection: $store.selectedBrewIDs) {
                TableColumn("Status") { service in
                    Dot(color: brewColor(service), text: service.status)
                }
                .width(min: 90, ideal: 100)
                TableColumn("Service") { service in Text(service.name) }
                TableColumn("User") { service in Text(service.user ?? "—").foregroundStyle(.secondary) }
                    .width(90)
            }
            .contextMenu(forSelectionType: BrewService.ID.self) { ids in
                let items = store.brew.filter { ids.contains($0.id) }
                if !items.isEmpty { BrewActions(store: store, items: items) }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ErrorBanner(message: store.sourceErrors[.brew]) }
            .overlay {
                if store.visibleBrew.isEmpty && store.sourceErrors[.brew] == nil {
                    ContentUnavailableView("No brew services", systemImage: "mug")
                }
            }
        }
    }
}

private func brewColor(_ service: BrewService) -> Color {
    switch service.status {
    case "started": .green
    case "scheduled": .blue
    case "error": .red
    default: .secondary
    }
}

struct BrewActions: View {
    let store: Store
    let items: [BrewService]

    var body: some View {
        Button("Start") { Task { await store.perform(.start, brew: items) } }
        Button("Stop") { Task { await store.perform(.stop, brew: items) } }
        Button("Restart") { Task { await store.perform(.restart, brew: items) } }
        Divider()
        let files = items.compactMap(\.file)
        if !files.isEmpty { Button("Reveal plist in Finder") { store.reveal(files) } }
        HideButton(store: store, section: .brew, ids: items.map(\.id))
    }
}

struct BrewDetail: View {
    let store: Store

    var body: some View {
        let items = store.selectedBrew
        if items.count > 1 {
            MultiSelection(count: items.count) { BrewActions(store: store, items: items) }
        } else if let service = items.first {
            Form {
                Section("Service") {
                    LabeledContent("Name", value: service.name)
                    LabeledContent("Status") { Dot(color: brewColor(service), text: service.status) }
                    if let user = service.user { LabeledContent("User", value: user) }
                    if let code = service.exitCode { LabeledContent("Last exit", value: LaunchItem.describeExit(code)) }
                    if let file = service.file { Mono(file) }
                }
                Section {
                    HStack {
                        Button("Start") { Task { await store.perform(.start, brew: [service]) } }
                        Button("Stop") { Task { await store.perform(.stop, brew: [service]) } }
                        Button("Restart") { Task { await store.perform(.restart, brew: [service]) } }
                    }
                    Text("Stop also keeps it from starting at login.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a service", systemImage: "mug")
        }
    }
}

// MARK: Containers

struct ContainerTable: View {
    @Bindable var store: Store

    var body: some View {
        if store.containerEngines.isEmpty {
            SourceUnavailable(title: "No container engine", symbol: "shippingbox", message: "Install Docker, OrbStack or Podman to see containers.")
        } else {
            Table(store.visibleContainers, selection: $store.selectedContainerIDs) {
                TableColumn("State") { c in Dot(color: c.isRunning ? .green : .secondary, text: c.state) }
                    .width(min: 80, ideal: 90)
                TableColumn("Name") { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).lineLimit(1)
                        Text(c.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                TableColumn("Project") { c in Text(c.project ?? "—").foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 100)
                TableColumn("Ports") { c in Text(c.ports).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .contextMenu(forSelectionType: Container.ID.self) { ids in
                let items = store.containers.filter { ids.contains($0.id) }
                if !items.isEmpty { ContainerActions(store: store, items: items) }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ErrorBanner(message: store.sourceErrors[.containers]) }
            .overlay {
                if store.visibleContainers.isEmpty && store.sourceErrors[.containers] == nil {
                    ContentUnavailableView("No containers", systemImage: "shippingbox")
                }
            }
        }
    }
}

struct ContainerActions: View {
    let store: Store
    let items: [Container]

    var body: some View {
        if items.contains(where: { !$0.isRunning }) {
            Button("Start") { Task { await store.perform(.start, containers: items.filter { !$0.isRunning }) } }
        }
        if items.contains(where: \.isRunning) {
            Button("Stop") { Task { await store.perform(.stop, containers: items.filter(\.isRunning)) } }
            Button("Restart") { Task { await store.perform(.restart, containers: items.filter(\.isRunning)) } }
        }
        HideButton(store: store, section: .containers, ids: items.map(\.id))
        Divider()
        Button("Remove…", role: .destructive) {
            store.confirm(
                items.count == 1 ? "Remove \(items[0].name)?" : "Remove \(items.count) containers?",
                "Only stopped containers can be removed. Images and volumes stay.",
                "Remove"
            ) { await store.perform(.remove, containers: items) }
        }
    }
}

struct ContainerDetail: View {
    let store: Store

    var body: some View {
        let items = store.selectedContainers
        if items.count > 1 {
            MultiSelection(count: items.count) { ContainerActions(store: store, items: items) }
        } else if let c = items.first {
            Form {
                Section("Container") {
                    LabeledContent("Name", value: c.name)
                    LabeledContent("State") { Dot(color: c.isRunning ? .green : .secondary, text: c.state) }
                    LabeledContent("Status", value: c.status)
                    LabeledContent("Image", value: c.image)
                    if let project = c.project { LabeledContent("Compose project", value: project) }
                    LabeledContent("Engine", value: c.engine)
                    LabeledContent("ID") { Mono(String(c.containerID.prefix(12))) }
                }
                if !c.ports.isEmpty { Section("Ports") { Mono(c.ports) } }
                Section { HStack { ContainerActions(store: store, items: [c]) } }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a container", systemImage: "shippingbox")
        }
    }
}

// MARK: Ports

struct PortTable: View {
    @Bindable var store: Store

    var body: some View {
        Table(store.visiblePorts, selection: $store.selectedPortIDs) {
            TableColumn("Port") { p in
                Text(p.port.map(String.init) ?? "?").monospacedDigit()
            }
            .width(60)
            TableColumn("Address") { p in
                HStack(spacing: 6) {
                    Text(p.address).font(.system(.body, design: .monospaced))
                    if p.isExposed { Flag("all interfaces") }
                }
            }
            TableColumn("Process") { p in Text(p.command) }
            TableColumn("PID") { p in Text(String(p.pid)).foregroundStyle(.secondary).monospacedDigit() }
                .width(60)
        }
        .contextMenu(forSelectionType: ListeningPort.ID.self) { ids in
            let items = store.ports.filter { ids.contains($0.id) }
            if !items.isEmpty { PortActions(store: store, items: items) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ErrorBanner(message: store.sourceErrors[.ports]) }
        .overlay {
            if store.visiblePorts.isEmpty && store.sourceErrors[.ports] == nil {
                ContentUnavailableView("Nothing listening", systemImage: "network")
            }
        }
    }
}

struct PortActions: View {
    let store: Store
    let items: [ListeningPort]

    var body: some View {
        if items.count == 1, let port = items.first?.port {
            Button("Open http://localhost:\(port)") {
                if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
            }
        }
        HideButton(store: store, section: .ports, ids: items.map(\.id))
        Divider()
        Button("Stop process…", role: .destructive) {
            let names = Set(items.map { "\($0.command) (\($0.pid))" }).sorted()
            store.confirm("Stop what's listening?", names.joined(separator: "\n"), "Stop") {
                await store.stop(ports: items)
            }
        }
    }
}

struct PortDetail: View {
    let store: Store

    var body: some View {
        let items = store.selectedPorts
        if items.count > 1 {
            MultiSelection(count: items.count) { PortActions(store: store, items: items) }
        } else if let p = items.first {
            Form {
                Section("Listening") {
                    LabeledContent("Address", value: p.address)
                    LabeledContent("Protocol", value: p.proto)
                    LabeledContent("Reachable", value: p.isExposed ? "from the network" : "this Mac only")
                    LabeledContent("Process", value: p.command)
                    LabeledContent("PID", value: String(p.pid))
                    LabeledContent("User", value: p.user)
                }
                Section { HStack { PortActions(store: store, items: [p]) } }
                Section {
                    Text("Only your own processes are visible without admin.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a port", systemImage: "network")
        }
    }
}

// MARK: Extensions

struct ExtensionTable: View {
    @Bindable var store: Store

    var body: some View {
        Table(store.visibleExtensions, selection: $store.selectedExtensionIDs) {
            TableColumn("State") { e in Dot(color: e.active ? .green : .secondary, text: e.active ? "active" : "inactive") }
                .width(min: 80, ideal: 90)
            TableColumn("Name") { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name)
                    Text(e.bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }
            TableColumn("Kind") { e in Text(e.category).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: SystemExtension.ID.self) { ids in
            let items = store.extensions.filter { ids.contains($0.id) }
            if !items.isEmpty {
                Button("Open in System Settings") { NSWorkspace.shared.open(Extensions.settingsURL) }
                HideButton(store: store, section: .extensions, ids: items.map(\.id))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ErrorBanner(message: store.sourceErrors[.extensions]) }
        .overlay {
            if store.visibleExtensions.isEmpty && store.sourceErrors[.extensions] == nil {
                ContentUnavailableView("No system extensions", systemImage: "puzzlepiece.extension")
            }
        }
    }
}

struct ExtensionDetail: View {
    let store: Store

    var body: some View {
        if let e = store.selectedExtensions.first {
            Form {
                Section("Extension") {
                    LabeledContent("Name", value: e.name)
                    LabeledContent("Bundle", value: e.bundleID)
                    LabeledContent("Version", value: e.version)
                    LabeledContent("Team", value: e.teamID)
                    LabeledContent("Kind", value: e.category)
                    LabeledContent("State", value: e.state)
                }
                Section {
                    Text("macOS only lets System Settings or the owning app remove extensions.")
                        .foregroundStyle(.secondary)
                    Button("Open in System Settings") { NSWorkspace.shared.open(Extensions.settingsURL) }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select an extension", systemImage: "puzzlepiece.extension")
        }
    }
}
