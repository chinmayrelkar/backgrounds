import XCTest
@testable import BackgroundsCore

final class SourcesTests: XCTestCase {
    func testDisabledLabels() {
        let raw = """
        disabled services = {
        \t"com.docker.helper" => enabled
        \t"com.example.off" => disabled
        \t"com.example.legacy" => true
        }
        """
        XCTAssertEqual(Launchctl.parseDisabled(raw), ["com.example.off", "com.example.legacy"])
    }

    func testPlistLogPathsAndDisabledState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID()).plist")
        let plist: [String: Any] = [
            "Label": "com.example.logs",
            "Program": "/usr/local/bin/thing",
            "StandardOutPath": "~/Library/Logs/thing.log",
            "StandardErrorPath": "~/Library/Logs/thing.log",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var item = try Launchctl.parsePlist(url, scope: .user)
        XCTAssertEqual(item.stdoutPath, NSHomeDirectory() + "/Library/Logs/thing.log")
        XCTAssertEqual(item.logPaths.count, 1, "same file for out and err is shown once")
        item.disabled = true
        XCTAssertEqual(item.state, .disabled)
        XCTAssertFalse(item.canStart)
    }

    func testDescribeExit() {
        XCTAssertEqual(LaunchItem.describeExit(0), "exited cleanly")
        XCTAssertEqual(LaunchItem.describeExit(-9), "killed by SIGKILL")
        XCTAssertEqual(LaunchItem.describeExit(78), "exit 78 (bad config)")
    }

    func testTailStartsAtLineBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID()).log")
        try (1...500).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let text = try XCTUnwrap(Launchctl.tail(url.path, maxBytes: 100))
        XCTAssertTrue(text.hasPrefix("line "), text)
        XCTAssertTrue(text.hasSuffix("line 500"))
    }

    func testCronParse() {
        let raw = """
        SHELL=/bin/bash
        # nightly backup at five
        0 5 * * * /Users/me/bin/backup --quiet
        #*/15 * * * * /usr/bin/true
        @reboot /Users/me/bin/start-thing
        MAILTO=""

        """
        let entries = Cron.parse(raw)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].schedule, "0 5 * * *")
        XCTAssertEqual(entries[0].command, "/Users/me/bin/backup --quiet")
        XCTAssertEqual(entries[0].line, 2)
        XCTAssertFalse(entries[1].enabled)
        XCTAssertEqual(entries[1].schedule, "*/15 * * * *")
        XCTAssertEqual(entries[2].schedule, "@reboot")
    }

    func testBrewParse() throws {
        let raw = """
        [{"name":"redis","status":"started","user":"me","file":"/x/homebrew.mxcl.redis.plist","exit_code":0},
         {"name":"nginx","status":"none","user":null,"file":null,"exit_code":null}]
        """
        let services = try BrewServices.parse(raw)
        XCTAssertEqual(services.map(\.name), ["redis", "nginx"])
        XCTAssertTrue(services[0].isRunning)
        XCTAssertFalse(services[1].isRunning)
        XCTAssertNil(services[1].exitCode)
    }

    func testContainerParse() {
        let raw = """
        {"ID":"55ed82bc278f","Names":"litellm-local","Image":"litellm:main","State":"running","Status":"Up 3 minutes","Ports":"0.0.0.0:4000->4000/tcp","Labels":"a=b,com.docker.compose.project=litellm,c=d"}
        {"ID":"a4a70307f723","Names":"old","Image":"redis","State":"exited","Status":"Exited (0)","Ports":"","Labels":""}
        not json
        """
        let items = Containers.parse(raw, engine: "docker")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].project, "litellm")
        XCTAssertTrue(items[0].isRunning)
        XCTAssertNil(items[1].project)
    }

    func testPortsParse() {
        let raw = "p856\ncGoogle Chrome\nLme\nf199\nPTCP\nn127.0.0.1:9222\np59882\ncOrbStack Helper\nLme\nf10\nPTCP\nn*:80\nf11\nPTCP\nn[::]:80\n"
        let ports = Ports.parse(raw)
        XCTAssertEqual(ports.count, 3)
        XCTAssertEqual(ports.first?.port, 80)
        XCTAssertTrue(ports.first?.isExposed ?? false)
        let chrome = ports.first { $0.pid == 856 }
        XCTAssertEqual(chrome?.command, "Google Chrome")
        XCTAssertEqual(chrome?.isExposed, false)
    }

    func testExtensionsParse() {
        let raw = """
        3 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings')
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tJ6S6Q257EK\tch.protonvpn.mac.WireGuard-Extension (6.4.0/2903266)\tProton VPN WireGuard\t[activated enabled]
        --- com.apple.system_extension.driver_extension (Go to 'System Settings')
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tG43BCU2T37\torg.pqrs.Karabiner (1.8.0/1.8.0)\tKarabiner\t[terminated waiting to uninstall on reboot]
        """
        let items = Extensions.parse(raw)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].bundleID, "ch.protonvpn.mac.WireGuard-Extension")
        XCTAssertEqual(items[0].version, "6.4.0/2903266")
        XCTAssertEqual(items[0].category, "network extension")
        XCTAssertTrue(items[0].active)
        XCTAssertFalse(items[1].enabled)
        XCTAssertEqual(items[1].state, "terminated waiting to uninstall on reboot")
    }

    func testLoginItemsParse() throws {
        let items = try LoginItems.parse(#"[{"name":"b, with comma","path":"/Applications/B.app","hidden":false},{"name":"A","path":"","hidden":true}]"#)
        XCTAssertEqual(items.map(\.name), ["A", "b, with comma"])
        XCTAssertTrue(items[0].hidden)
    }

    func testShellDrainsLargeStderrWithoutDeadlock() throws {
        // >64 KB on stderr would block the child forever if we read stdout to EOF first.
        let result = try Shell.exec("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo done"])
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertEqual(result.stderr.count, 300_000)
    }
}
