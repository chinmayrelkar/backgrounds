import Foundation

public struct DiskRate: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var readPerSecond: Double
    public var writePerSecond: Double
    public var totalRead: UInt64
    public var totalWritten: UInt64
}

public struct NetRate: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var inPerSecond: Double
    public var outPerSecond: Double
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var addresses: [String]
    public var isUp: Bool
}

public struct SystemSnapshot: Sendable {
    public var date: Date
    public var cpu: CPUSample
    public var load: [Double]
    public var memory: MemorySample
    public var disks: [DiskRate]
    public var volumes: [VolumeInfo]
    public var network: [NetRate]
    public var gpus: [GPUSample]
    public var battery: BatterySample?
    public var processes: [ProcessRow]

    public var diskRead: Double { disks.reduce(0) { $0 + $1.readPerSecond } }
    public var diskWrite: Double { disks.reduce(0) { $0 + $1.writePerSecond } }
}

/// Everything btop samples, in one call. Keeps last counters so rates are real deltas.
public final class SystemSampler: @unchecked Sendable {
    public let host = SystemStats.host()
    private let processes = ProcessSampler()
    private var ticks: [[UInt32]] = []
    private var disks: [String: DiskCounters] = [:]
    private var nets: [String: InterfaceCounters] = [:]
    private var last: Date?
    private var volumeCache: (Date, [VolumeInfo])?
    private let lock = NSLock()

    public init() {
        ticks = SystemStats.cpuTicks()
    }

    public func sample(includeProcesses: Bool = true) -> SystemSnapshot {
        let procs = includeProcesses ? ((try? processes.sample()) ?? []) : []
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let wall = max(0.001, last.map { now.timeIntervalSince($0) } ?? 1)
        let hasPrevious = last != nil

        let newTicks = SystemStats.cpuTicks()
        let cpu = SystemStats.cpuLoad(from: ticks, to: newTicks)
        ticks = newTicks

        let diskNow = DeviceStats.diskCounters()
        let diskRates = diskNow.map { counter -> DiskRate in
            let old = disks[counter.name]
            func rate(_ new: UInt64, _ prev: UInt64?) -> Double {
                guard hasPrevious, let prev, new >= prev else { return 0 }
                return Double(new - prev) / wall
            }
            return DiskRate(
                name: counter.name,
                readPerSecond: rate(counter.bytesRead, old?.bytesRead),
                writePerSecond: rate(counter.bytesWritten, old?.bytesWritten),
                totalRead: counter.bytesRead,
                totalWritten: counter.bytesWritten
            )
        }
        disks = Dictionary(diskNow.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        let addresses = DeviceStats.addresses()
        let netNow = DeviceStats.interfaceCounters()
        let netRates = netNow.map { counter -> NetRate in
            let old = nets[counter.name]
            func rate(_ new: UInt64, _ prev: UInt64?) -> Double {
                guard hasPrevious, let prev, new >= prev else { return 0 }
                return Double(new - prev) / wall
            }
            return NetRate(
                name: counter.name,
                inPerSecond: rate(counter.bytesIn, old?.bytesIn),
                outPerSecond: rate(counter.bytesOut, old?.bytesOut),
                totalIn: counter.bytesIn,
                totalOut: counter.bytesOut,
                addresses: addresses[counter.name] ?? [],
                isUp: counter.isUp
            )
        }
        nets = Dictionary(netNow.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // Volume capacity barely moves; statfs on network mounts can be slow.
        let volumes: [VolumeInfo]
        if let cache = volumeCache, now.timeIntervalSince(cache.0) < 30 {
            volumes = cache.1
        } else {
            volumes = DeviceStats.volumes()
            volumeCache = (now, volumes)
        }

        last = now
        return SystemSnapshot(
            date: now,
            cpu: cpu,
            load: SystemStats.loadAverage(),
            memory: SystemStats.memory(),
            disks: diskRates,
            volumes: volumes,
            network: netRates,
            gpus: DeviceStats.gpus(),
            battery: DeviceStats.battery(),
            processes: procs
        )
    }
}

/// Fixed-size history for graphs.
public struct History: Sendable {
    public private(set) var values: [Double] = []
    public let capacity: Int

    public init(capacity: Int = 120) { self.capacity = capacity }

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var last: Double { values.last ?? 0 }
    public var peak: Double { values.max() ?? 0 }
}
