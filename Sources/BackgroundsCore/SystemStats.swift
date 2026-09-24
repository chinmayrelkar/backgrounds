import Darwin
import Foundation

public struct CoreLoad: Sendable, Hashable {
    public var user: Double
    public var system: Double
    public var nice: Double
    public var idle: Double

    public static let zero = CoreLoad(user: 0, system: 0, nice: 0, idle: 1)

    /// 0...1
    public var busy: Double { min(1, max(0, user + system + nice)) }
}

public struct CPUSample: Sendable {
    public var total: CoreLoad
    public var cores: [CoreLoad]
}

public struct MemorySample: Sendable {
    public var total: UInt64
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var pressure: Pressure

    public enum Pressure: String, Sendable {
        case normal, warning, critical
    }

    public var available: UInt64 { total > used ? total - used : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    public var swapFraction: Double { swapTotal == 0 ? 0 : Double(swapUsed) / Double(swapTotal) }
}

public struct HostInfo: Sendable {
    public var model: String
    public var cpuName: String
    public var logicalCores: Int
    public var coreKinds: [String]
    public var memory: UInt64
    public var osVersion: String
    public var bootTime: Date?
}

public enum SystemStats {
    public static func host() -> HostInfo {
        let logical = Int(sysctlInt("hw.logicalcpu") ?? Int64(ProcessInfo.processInfo.activeProcessorCount))
        // Apple silicon splits cores into perf levels (P then E). Label each core by its level.
        var kinds: [String] = []
        let levels = Int(sysctlInt("hw.nperflevels") ?? 0)
        for level in 0..<levels {
            let name = sysctlString("hw.perflevel\(level).name") ?? "L\(level)"
            let count = Int(sysctlInt("hw.perflevel\(level).logicalcpu") ?? 0)
            kinds += Array(repeating: String(name.prefix(1)), count: count)
        }
        if kinds.count != logical { kinds = Array(repeating: "", count: logical) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return HostInfo(
            model: sysctlString("hw.model") ?? "Mac",
            cpuName: sysctlString("machdep.cpu.brand_string") ?? "CPU",
            logicalCores: logical,
            coreKinds: kinds,
            memory: UInt64(sysctlInt("hw.memsize") ?? 0),
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            bootTime: bootTime()
        )
    }

    public static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        return n == 3 ? loads : [0, 0, 0]
    }

    public static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Raw per-core tick counters: [user, system, idle, nice] per core.
    public static func cpuTicks() -> [[UInt32]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return [] }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let base = core * stride
            return [
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ]
        }
    }

    /// Load between two tick snapshots. Counters are 32-bit and wrap, so subtract with &-.
    public static func cpuLoad(from old: [[UInt32]], to new: [[UInt32]]) -> CPUSample {
        guard old.count == new.count, !new.isEmpty else {
            return CPUSample(total: .zero, cores: Array(repeating: .zero, count: new.count))
        }
        var sums = [Double](repeating: 0, count: 4)
        let cores: [CoreLoad] = zip(old, new).map { before, after in
            let d = (0..<4).map { Double(after[$0] &- before[$0]) }
            for i in 0..<4 { sums[i] += d[i] }
            return load(d)
        }
        return CPUSample(total: load(sums), cores: cores)
    }

    private static func load(_ d: [Double]) -> CoreLoad {
        let all = d.reduce(0, +)
        guard all > 0 else { return .zero }
        return CoreLoad(user: d[0] / all, system: d[1] / all, nice: d[3] / all, idle: d[2] / all)
    }

    /// Same buckets Activity Monitor uses: used = app + wired + compressed.
    public static func memory() -> MemorySample {
        let total = UInt64(sysctlInt("hw.memsize") ?? 0)
        let page = UInt64(sysctlInt("hw.pagesize") ?? 16_384)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let pressure: MemorySample.Pressure = switch sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
        guard kr == KERN_SUCCESS else {
            return MemorySample(total: total, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: total,
                                swapTotal: swap.xsu_total, swapUsed: swap.xsu_used, pressure: pressure)
        }
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let used = min(total, app + wired + compressed)
        return MemorySample(
            total: total,
            used: used,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            free: UInt64(stats.free_count) * page,
            swapTotal: swap.xsu_total,
            swapUsed: swap.xsu_used,
            pressure: pressure
        )
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; sysctl writes only `size` bytes.
        if size == MemoryLayout<Int32>.size { return Int64(Int32(truncatingIfNeeded: value)) }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
