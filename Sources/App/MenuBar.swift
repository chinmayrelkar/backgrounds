import SwiftUI
import BackgroundsCore

struct MenuBarLabel: View {
    let monitor: SystemMonitor

    var body: some View {
        let cpu = monitor.latest?.cpu.total.busy ?? 0
        let mem = monitor.latest?.memory.usedFraction ?? 0
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            Text("\(Int(cpu * 100))% · \(Int(mem * 100))%").monospacedDigit()
        }
        .task { monitor.start() }
    }
}

struct MenuBarPanel: View {
    let store: Store
    let monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snap = monitor.latest {
                row("CPU", Format.percent(snap.cpu.total.busy))
                HistoryGraph(values: monitor.cpuTotal.values, color: loadColor(snap.cpu.total.busy), height: 36)
                row("Memory", "\(Format.bytes(snap.memory.used)) / \(Format.bytes(snap.memory.total))")
                HistoryGraph(values: monitor.memoryUsed.values, color: pressureColor(snap.memory.pressure), height: 28)
                row("Network", "↓ \(Format.rate(monitor.netIn.last))  ↑ \(Format.rate(monitor.netOut.last))")
                row("Disk", "R \(Format.rate(snap.diskRead))  W \(Format.rate(snap.diskWrite))")
                if let b = snap.battery { row("Battery", Format.percent(b.percent) + (b.isCharging ? " ⚡︎" : "")) }
                Divider()
                Text("Top CPU").font(.caption).foregroundStyle(.secondary)
                ForEach(snap.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)) { p in
                    row(p.name, String(format: "%.1f%%", monitor.displayCPU(p.cpuPercent, perCore: store.settings.cpuPerCore)))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Divider()
            row("Running", String(store.processes.count))
            row("Login jobs", String(store.jobs.filter { !$0.isApple }.count))
            row("Listening ports", String(store.ports.count))
            row("Containers up", String(store.containers.filter(\.isRunning).count))
            Divider()
            HStack {
                Button("Open Backgrounds") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).lineLimit(1)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct SettingsView: View {
    @Bindable var store: Store
    @Bindable var monitor: SystemMonitor

    var body: some View {
        let settings = store.settings
        TabView {
            Form {
                Picker("Monitor updates every", selection: Bindable(settings).monitorIntervalMS) {
                    ForEach([500, 1000, 2000, 3000, 5000, 10000], id: \.self) { ms in
                        Text(ms < 1000 ? "\(ms) ms" : "\(ms / 1000) s").tag(ms)
                    }
                }
                Picker("Reload background lists", selection: Bindable(settings).autoRefreshSeconds) {
                    Text("Never").tag(0)
                    ForEach([5, 15, 30, 60, 300], id: \.self) { s in
                        Text(s < 60 ? "every \(s) s" : "every \(s / 60) min").tag(s)
                    }
                }
                Toggle("Process CPU % per core", isOn: Bindable(settings).cpuPerCore)
                Toggle("Show in menu bar", isOn: Bindable(settings).showMenuBar)
                Toggle("Notify when a new login job appears", isOn: Bindable(settings).notifyNewJobs)
            }
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                if settings.hidden.isEmpty {
                    Text("Nothing hidden. Right-click any row and choose Hide.").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(settings.hidden.sorted(), id: \.self) { key in
                            HStack {
                                Text(key).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Unhide") { settings.hidden.remove(key) }
                            }
                        }
                    }
                    Button("Unhide all") { settings.hidden = [] }
                }
            }
            .tabItem { Label("Hidden", systemImage: "eye.slash") }
        }
        .padding()
        .frame(width: 460, height: 320)
    }
}
