import SwiftUI
import BackgroundsCore

@main
struct BackgroundsApp: App {
    @State private var store = Store()
    @State private var monitor = SystemMonitor()

    init() {
        if CommandLine.arguments.contains("--dump") {
            Self.dumpAndExit()
        }
    }

    var body: some Scene {
        Window("Backgrounds", id: "main") {
            ContentView(store: store, monitor: monitor)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("View") {
                Button("Reload") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                Button(monitor.isPaused ? "Resume Monitor" : "Pause Monitor") { monitor.isPaused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: $store.settings.showMenuBar) {
            MenuBarPanel(store: store, monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, monitor: monitor)
        }
    }

    private static func dumpAndExit() -> Never {
        do {
            let procs = try UserProcesses.inventory()
            print("RUNNING \(procs.count)")
            for item in procs {
                print("\(item.kind.rawValue)\t\(item.pid)\t\(item.memoryMB)MB\t\(item.name)\t\(item.path)")
            }
            let jobs = try Launchctl.inventory()
            print("JOBS \(jobs.count)")
            for item in jobs where !item.isApple {
                print("\(item.scope.rawValue)\t\(item.state.rawValue)\t\(item.label)\t\(item.plistPath)")
            }
            let daemons = jobs.filter { $0.scope == .daemon }
            print("DAEMONS listed=\(daemons.filter(\.listed).count) of \(daemons.count)")
            if Watchman.isAvailable {
                let roots = try Watchman.list()
                print("WATCHES \(roots.count)")
                for root in roots { print(root.path) }
            } else {
                print("WATCHES unavailable")
            }
            dump("LOGIN ITEMS") { try LoginItems.list().map { "\($0.name)\t\($0.path)" } }
            dump("CRON") { try Cron.list().map { "\($0.enabled ? "on" : "off")\t\($0.schedule)\t\($0.command)" } }
            dump("BREW") { try BrewServices.list().map { "\($0.status)\t\($0.name)" } }
            let containers = Containers.list()
            print("CONTAINERS \(containers.items.count)")
            for c in containers.items { print("\(c.engine)\t\(c.state)\t\(c.name)\t\(c.image)") }
            for e in containers.errors { print("  error: \(e)") }
            dump("PORTS") { try Ports.listening().map { "\($0.address)\t\($0.pid)\t\($0.command)" } }
            dump("EXTENSIONS") { try Extensions.list().map { "\($0.category)\t\($0.name)\t\($0.state)" } }
            dumpSystem()
            exit(0)
        } catch {
            fputs("dump failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func dump(_ title: String, _ lines: () throws -> [String]) {
        do {
            let rows = try lines()
            print("\(title) \(rows.count)")
            rows.forEach { print($0) }
        } catch {
            print("\(title) error: \(error.localizedDescription)")
        }
    }

    private static func dumpSystem() {
        let sampler = SystemSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 1)
        let s = sampler.sample()
        let host = sampler.host
        print("HOST \(host.model) \(host.cpuName) cores=\(host.logicalCores) kinds=\(host.coreKinds.joined()) os=\(host.osVersion)")
        print(String(format: "CPU total=%.1f%% cores=%@", s.cpu.total.busy * 100,
                     s.cpu.cores.map { String(format: "%.0f", $0.busy * 100) }.joined(separator: ",")))
        print("LOAD \(s.load.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        let m = s.memory
        print("MEM used=\(Format.bytes(m.used)) of \(Format.bytes(m.total)) app=\(Format.bytes(m.app)) wired=\(Format.bytes(m.wired)) compressed=\(Format.bytes(m.compressed)) cached=\(Format.bytes(m.cached)) swap=\(Format.bytes(m.swapUsed))/\(Format.bytes(m.swapTotal)) pressure=\(m.pressure.rawValue)")
        for d in s.disks { print("DISK \(d.name) r=\(Format.rate(d.readPerSecond)) w=\(Format.rate(d.writePerSecond))") }
        for v in s.volumes { print("VOL \(v.name) \(Format.bytes(v.used))/\(Format.bytes(v.total)) \(v.path)") }
        for n in s.network where n.isUp && (n.totalIn > 0 || n.totalOut > 0) {
            print("NET \(n.name) in=\(Format.rate(n.inPerSecond)) out=\(Format.rate(n.outPerSecond)) \(n.addresses.joined(separator: ","))")
        }
        for g in s.gpus { print(String(format: "GPU %@ %.0f%%", g.name, g.utilization * 100)) }
        if let b = s.battery { print(String(format: "BATTERY %.0f%% charging=%@", b.percent * 100, b.isCharging ? "yes" : "no")) } else { print("BATTERY none") }
        print("PROCS \(s.processes.count)")
        for p in s.processes.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(5) {
            print(String(format: "%6d %5.1f%% %@ threads=%@ %@", p.pid, p.cpuPercent, Format.bytes(p.residentBytes), p.threads.map(String.init) ?? "-", p.name))
        }
    }
}
