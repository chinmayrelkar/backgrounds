import SwiftUI
import BackgroundsCore

@main
struct BackgroundsApp: App {
    init() {
        if CommandLine.arguments.contains("--dump") {
            Self.dumpAndExit()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
            if Watchman.isAvailable {
                let roots = try Watchman.list()
                print("WATCHES \(roots.count)")
                for root in roots { print(root.path) }
            } else {
                print("WATCHES unavailable")
            }
            exit(0)
        } catch {
            fputs("dump failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
