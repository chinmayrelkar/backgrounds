import Darwin
import XCTest
@testable import BackgroundsCore

/// Runs the same calls the app's buttons make, against throwaway targets only.
/// They change real machine state (launchd, crontab, docker), so they only run with BG_ACTIONS=1.
final class ActionTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BG_ACTIONS"] == "1", "Set BG_ACTIONS=1 to run")
    }

    // MARK: Login job: start, stop, disable, enable, purge

    func testLoginJobLifecycle() throws {
        let label = "com.backgrounds.actiontest.\(getpid())"
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
        let url = dir.appendingPathComponent("\(label).plist")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).log")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", "echo started; exec /bin/sleep 600"],
            "StandardOutPath": log.path,
            "KeepAlive": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        addTeardownBlock {
            _ = try? Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            _ = try? Shell.run("/bin/launchctl", ["enable", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: log)
        }

        var job = try find(label)
        XCTAssertEqual(job.state, .notLoaded)

        try Launchctl.start(job)
        job = try waitFor(label) { $0.state == .running }
        let pid = try XCTUnwrap(job.pid)
        XCTAssertTrue(Signals.isAlive(pid))
        XCTAssertEqual(Launchctl.tail(log.path)?.contains("started"), true, "log viewer reads StandardOutPath")

        // Running tab: a KeepAlive job must be unloaded, not just killed, or launchd restarts it.
        let running = RunningItem(id: "x", name: "sleep", pid: pid, extraPIDs: [], path: "/bin/sleep",
                                  command: "/bin/sleep 600", memoryBytes: 0, kind: .background)
        XCTAssertEqual(JobMatching.job(for: running, in: [job])?.label, label, "pid match finds the owning job")

        try Launchctl.stop(job)
        job = try waitFor(label) { !$0.listed }
        XCTAssertTrue(Signals.waitGone([pid], timeout: 3), "bootout ends the process")

        try Launchctl.start(job)
        job = try waitFor(label) { $0.state == .running }
        try Launchctl.disable(job)
        job = try waitFor(label) { $0.state == .disabled }
        XCTAssertFalse(job.canStart)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "disable keeps the plist")

        try Launchctl.enable(job)
        job = try waitFor(label) { $0.state == .notLoaded }

        try Launchctl.start(job)
        job = try waitFor(label) { $0.listed }
        try Launchctl.purge(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "purge deletes the plist")
        XCTAssertNil(try Launchctl.inventory().first { $0.label == label })
    }

    // MARK: Cron: add, disable, enable, remove. Restores the crontab exactly.

    func testCronLifecycle() throws {
        let before = try Cron.readRaw()
        addTeardownBlock { try? Self.restoreCrontab(before) }
        let marker = "/usr/bin/true backgrounds-actiontest-\(getpid())"
        try Cron.rewrite { lines in
            if lines.last == "" { lines.removeLast() }
            lines.append("17 3 * * * \(marker)")
        }

        var entry = try XCTUnwrap(try Cron.list().first { $0.command == marker })
        XCTAssertTrue(entry.enabled)

        try Cron.setEnabled(entry, false)
        entry = try XCTUnwrap(try Cron.list().first { $0.command == marker })
        XCTAssertFalse(entry.enabled)
        XCTAssertTrue(try Cron.readRaw().contains("# 17 3 * * * \(marker)"))

        try Cron.setEnabled(entry, true)
        entry = try XCTUnwrap(try Cron.list().first { $0.command == marker })
        XCTAssertTrue(entry.enabled)

        try Cron.remove(entry)
        XCTAssertNil(try Cron.list().first { $0.command == marker })
        XCTAssertEqual(try Cron.readRaw().trimmingCharacters(in: .whitespacesAndNewlines),
                       before.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func restoreCrontab(_ text: String) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try Shell.exec("/usr/bin/crontab", ["-r"], allowFailure: true)
        } else {
            _ = try Shell.run("/usr/bin/crontab", ["-"], input: text)
        }
    }

    // MARK: Containers: start, restart, stop, remove on a throwaway container

    func testContainerLifecycle() throws {
        try XCTSkipUnless(Containers.available.contains("docker"), "docker not installed")
        let images = try Shell.output("docker", ["images", "--format", "{{.Repository}}:{{.Tag}}"])
            .split(separator: "\n").map(String.init)
        let image = try XCTUnwrap(images.first { $0.hasPrefix("redis:") || $0.hasPrefix("postgres:") || $0.hasPrefix("nginx") },
                                  "needs a local image that runs by itself")
        let name = "backgrounds-actiontest-\(getpid())"
        _ = try Shell.run("docker", ["create", "--name", name, image] + (image.hasPrefix("postgres") ? ["-e", "POSTGRES_PASSWORD=x"] : []))
        addTeardownBlock { _ = try? Shell.run("docker", ["rm", "-f", name]) }

        func current() throws -> Container {
            try XCTUnwrap(Containers.list().items.first { $0.name == name })
        }
        var c = try current()
        XCTAssertFalse(c.isRunning)
        try Containers.perform(.start, on: c)
        c = try current()
        XCTAssertTrue(c.isRunning)
        try Containers.perform(.restart, on: c)
        XCTAssertTrue(try current().isRunning)
        try Containers.perform(.stop, on: c)
        XCTAssertFalse(try current().isRunning)
        try Containers.perform(.remove, on: c)
        XCTAssertNil(Containers.list().items.first { $0.name == name })
    }

    // MARK: Processes: pause, resume, renice, and a port going away on stop

    func testSignalsAndRenice() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        let pid = Int(process.processIdentifier)

        try Signals.send(SIGSTOP, to: pid)
        XCTAssertTrue(try waitState(pid) { $0.hasPrefix("T") }, "SIGSTOP pauses")
        try Signals.send(SIGCONT, to: pid)
        XCTAssertTrue(try waitState(pid) { !$0.hasPrefix("T") }, "SIGCONT resumes")

        try ProcessList.renice(pid, to: 10, allowAdmin: false)
        XCTAssertEqual(try ProcessList.snapshot().first { $0.pid == pid }?.nice, 10)

        XCTAssertEqual(try Signals.terminate([pid]), .exited)
    }

    func testStopFreesListeningPort() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import socket,time;s=socket.socket();s.bind(('127.0.0.1',0));s.listen();print(s.getsockname()[1],flush=True);time.sleep(60)"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        let port = try XCTUnwrap(Int(line.trimmingCharacters(in: .whitespacesAndNewlines)))

        let listening = try XCTUnwrap(try Ports.listening().first { $0.port == port })
        XCTAssertEqual(listening.pid, Int(process.processIdentifier))
        XCTAssertFalse(listening.isExposed)

        try Signals.terminate([listening.pid])
        XCTAssertNil(try Ports.listening().first { $0.port == port })
    }

    // MARK: helpers

    private func find(_ label: String) throws -> LaunchItem {
        try XCTUnwrap(try Launchctl.inventory().first { $0.label == label }, "\(label) not in inventory")
    }

    private func waitFor(_ label: String, _ ok: (LaunchItem) -> Bool) throws -> LaunchItem {
        let deadline = Date().addingTimeInterval(5)
        var last = try find(label)
        while !ok(last) && Date() < deadline {
            usleep(200_000)
            last = try find(label)
        }
        XCTAssertTrue(ok(last), "\(label) stuck in \(last.state.rawValue)")
        return last
    }

    private func waitState(_ pid: Int, _ ok: (String) -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let row = try ProcessList.snapshot().first(where: { $0.pid == pid }), ok(row.state) { return true }
            usleep(100_000)
        } while Date() < deadline
        return false
    }
}
