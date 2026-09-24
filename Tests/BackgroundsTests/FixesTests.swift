import Darwin
import XCTest
@testable import BackgroundsCore

/// Regression tests for the four bugs.
final class FixesTests: XCTestCase {
    // Bug 1: daemon status came from `launchctl list`, which never shows the system domain.
    func testParsesSystemDomainServices() {
        let raw = """
        system = {
        \tservices = {
        \t\t       0      - \tcom.apple.lskdd
        \t\t     621      - \tcom.apple.runningboardd
        \t\t       0     78 \tcom.example.broken
        \t\t    4242   (pe) \tcom.example.helperd
        \t}
        \tunmanaged processes = {
        \t\t     999      - \tnot.a.service
        \t}
        }
        """
        let status = Launchctl.parseSystemPrint(raw)
        XCTAssertEqual(status.count, 4)
        XCTAssertEqual(status["com.apple.runningboardd"]?.pid, 621)
        XCTAssertNil(status["com.apple.lskdd"]?.pid)
        XCTAssertEqual(status["com.apple.lskdd"]?.listed, true)
        XCTAssertEqual(status["com.example.broken"]?.lastExit, 78)
        XCTAssertEqual(status["com.example.helperd"]?.pid, 4242)
        XCTAssertNil(status["not.a.service"])
    }

    func testRealSystemDomainHasRunningServices() throws {
        let status = try Launchctl.systemStatus()
        XCTAssertGreaterThan(status.count, 50)
        XCTAssertNotNil(status["com.apple.logd"]?.pid, "logd always runs in the system domain")
    }

    func testMachineAgentsLiveInGuiDomain() {
        XCTAssertTrue(AgentScope.systemAgent.domainPrefix.hasPrefix("gui/"))
        XCTAssertEqual(AgentScope.daemon.domainPrefix, "system")
        XCTAssertFalse(AgentScope.systemAgent.controlNeedsAdmin)
        XCTAssertTrue(AgentScope.daemon.controlNeedsAdmin)
        XCTAssertTrue(AgentScope.systemAgent.needsAdmin)
    }

    // Bug 2: `command.contains(program)` let a python job claim every python process.
    func testInterpreterJobDoesNotClaimUnrelatedProcess() {
        let job = makeJob(label: "com.example.py", program: "/usr/bin/python3", pid: 111)
        let other = makeProcess(pid: 222, path: "/usr/bin/python3", command: "/usr/bin/python3 /Users/me/other.py")
        XCTAssertNil(JobMatching.job(for: other, in: [job]))
    }

    func testPIDMatchWins() {
        let job = makeJob(label: "com.example.py", program: "/usr/bin/python3", pid: 111)
        let mine = makeProcess(pid: 111, path: "/usr/bin/python3", command: "/usr/bin/python3 /Users/me/job.py")
        XCTAssertEqual(JobMatching.job(for: mine, in: [job])?.label, "com.example.py")
    }

    func testExactBinaryMatchForNonInterpreter() {
        let job = makeJob(label: "homebrew.mxcl.redis", program: "/opt/homebrew/opt/redis/bin/redis-server", pid: nil)
        let redis = makeProcess(pid: 5, path: "/opt/homebrew/opt/redis/bin/redis-server", command: "redis-server *:6379")
        let cli = makeProcess(pid: 6, path: "/opt/homebrew/opt/redis/bin/redis-cli", command: "/opt/homebrew/opt/redis/bin/redis-cli -h /opt/homebrew/opt/redis/bin/redis-server")
        XCTAssertNotNil(JobMatching.job(for: redis, in: [job]))
        XCTAssertNil(JobMatching.job(for: cli, in: [job]), "substring of the command must not match")
    }

    // Bug 3: stop sent SIGTERM once and never checked.
    func testTerminateStopsPoliteProcess() throws {
        let process = try spawn("/bin/sleep", ["30"])
        let outcome = try Signals.terminate([Int(process.processIdentifier)], grace: 2)
        process.waitUntilExit()
        XCTAssertEqual(outcome, .exited)
        XCTAssertFalse(process.isRunning)
    }

    func testTerminateEscalatesToKill() throws {
        let process = try spawn("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.1; done"])
        usleep(200_000) // let the trap install
        let outcome = try Signals.terminate([Int(process.processIdentifier)], grace: 0.5)
        process.waitUntilExit()
        XCTAssertEqual(outcome, .killed)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testTerminateGonePID() throws {
        XCTAssertEqual(try Signals.terminate([999_999]), .alreadyGone)
    }

    func testSignalOtherUserWithoutAdminThrows() throws {
        // launchd (pid 1) is root's; we must get a clear error, not silent success.
        // Probe with the exact call under test. On GitHub's runner kill(1, 0) is refused
        // but SIGCONT is not, so only a refused SIGCONT proves the premise.
        let refused = kill(1, SIGCONT) != 0 && errno == EPERM
        try XCTSkipIf(!refused, "This environment may send SIGCONT to pid 1")
        XCTAssertThrowsError(try Signals.send(SIGCONT, to: 1, allowAdmin: false)) { error in
            guard case SignalError.notPermitted(pid: 1) = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: helpers

    /// Children of the test runner become zombies until reaped, which `kill(pid, 0)` still sees.
    /// Foundation's Process reaps them, so `isAlive` flips as soon as they exit.
    private func spawn(_ path: String, _ args: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        return process
    }

    private func makeJob(label: String, program: String, pid: Int?) -> LaunchItem {
        LaunchItem(label: label, scope: .user, plistPath: "/tmp/\(label).plist", program: program, arguments: [program],
                   keepAlive: false, runAtLoad: false, startInterval: nil, calendarHint: nil,
                   pid: pid, lastExit: nil, listed: pid != nil, isEmptyPlist: false)
    }

    private func makeProcess(pid: Int, path: String, command: String) -> RunningItem {
        RunningItem(id: path, name: URL(fileURLWithPath: path).lastPathComponent, pid: pid, extraPIDs: [],
                    path: path, command: command, memoryBytes: 0, kind: .background)
    }
}
