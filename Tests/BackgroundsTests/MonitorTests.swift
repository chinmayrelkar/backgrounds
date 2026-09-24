import XCTest
@testable import BackgroundsCore

final class MonitorTests: XCTestCase {
    func testPsDurations() {
        XCTAssertEqual(ProcessList.duration("0:01.50"), 1.5, accuracy: 0.001)
        XCTAssertEqual(ProcessList.duration("12:34.00"), 754, accuracy: 0.001)
        XCTAssertEqual(ProcessList.duration("01:02:03"), 3723, accuracy: 0.001)
        XCTAssertEqual(ProcessList.duration("2-03:00:00"), 2 * 86_400 + 3 * 3_600, accuracy: 0.001)
    }

    func testPsLineParse() throws {
        let row = try XCTUnwrap(ProcessList.parse("  544     1    -2  31    0  20048 435299200 Ss     0:12.34  1-02:03:04 /usr/libexec/logd --flag x"))
        XCTAssertEqual(row.pid, 544)
        XCTAssertEqual(row.ppid, 1)
        XCTAssertEqual(row.uid, -2)
        XCTAssertEqual(row.residentBytes, 20048 * 1024)
        XCTAssertEqual(row.state, "Ss")
        XCTAssertEqual(row.stateTitle, "sleeping")
        XCTAssertEqual(row.cpuTime, 12.34, accuracy: 0.001)
        XCTAssertEqual(row.command, "/usr/libexec/logd --flag x")
    }

    func testNegativeUIDDoesNotCrash() {
        XCTAssertEqual(ProcessList.userName(-2), "nobody")
    }

    func testCPULoadHandlesCounterWrap() {
        let old: [[UInt32]] = [[UInt32.max - 9, 0, 0, 0]]
        let new: [[UInt32]] = [[10, 0, 20, 0]] // user +20 across the wrap, idle +20
        let sample = SystemStats.cpuLoad(from: old, to: new)
        XCTAssertEqual(sample.total.busy, 0.5, accuracy: 0.001)
    }

    func testTreeFlattenAndCollapse() {
        func row(_ pid: Int, _ ppid: Int, cpu: Double) -> ProcessRow {
            var r = ProcessRow(pid: pid, ppid: ppid, uid: 501, user: "me", name: "p\(pid)", path: "", command: "",
                               state: "S", nice: 0, priority: 31, residentBytes: 100, virtualBytes: 0, cpuTime: 0, elapsed: 0)
            r.cpuPercent = cpu
            return r
        }
        let rows = [row(1, 0, cpu: 1), row(10, 1, cpu: 5), row(11, 10, cpu: 2), row(20, 1, cpu: 9)]
        let byCPU: (ProcessRow, ProcessRow) -> Bool = { $0.cpuPercent > $1.cpuPercent }
        let tree = ProcessTree.flatten(rows, by: byCPU)
        XCTAssertEqual(tree.map(\.row.pid), [1, 20, 10, 11])
        XCTAssertEqual(tree.map(\.depth), [0, 1, 1, 2])
        XCTAssertEqual(tree[0].treeCPU, 17, accuracy: 0.001)
        XCTAssertEqual(tree[0].treeMemory, 400)
        let collapsed = ProcessTree.flatten(rows, collapsed: [10], by: byCPU)
        XCTAssertEqual(collapsed.map(\.row.pid), [1, 20, 10])
    }

    func testRealSamplerProducesSaneNumbers() throws {
        let sampler = SystemSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.5)
        let s = sampler.sample()
        XCTAssertEqual(s.cpu.cores.count, sampler.host.logicalCores)
        XCTAssertTrue((0...1).contains(s.cpu.total.busy))
        XCTAssertGreaterThan(s.memory.total, 0)
        XCTAssertLessThanOrEqual(s.memory.used, s.memory.total)
        XCTAssertFalse(s.volumes.isEmpty)
        XCTAssertTrue(s.network.contains { $0.name == "lo0" })
        XCTAssertGreaterThan(s.processes.count, 50)
        let me = try XCTUnwrap(s.processes.first { $0.pid == Int(getpid()) })
        XCTAssertNotNil(me.threads, "own process should expose thread count")
        XCTAssertTrue(s.processes.contains { $0.pid == 1 }, "launchd is visible to ps")
    }

    func testHistoryCaps() {
        var h = History(capacity: 3)
        for v in 1...5 { h.append(Double(v)) }
        XCTAssertEqual(h.values, [3, 4, 5])
        XCTAssertEqual(h.peak, 5)
    }
}
