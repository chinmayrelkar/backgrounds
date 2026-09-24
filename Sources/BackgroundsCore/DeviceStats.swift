import Darwin
import Foundation
import IOKit
import IOKit.ps

public struct DiskCounters: Sendable, Hashable {
    public var name: String
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
}

public struct VolumeInfo: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var total: UInt64
    public var available: UInt64
    public var isInternal: Bool

    public var used: UInt64 { total > available ? total - available : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public struct InterfaceCounters: Sendable, Hashable {
    public var name: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var isUp: Bool
}

public struct GPUSample: Sendable {
    public var name: String
    public var utilization: Double
    public var memoryInUse: UInt64?
}

public struct BatterySample: Sendable {
    public var percent: Double
    public var isCharging: Bool
    public var onAC: Bool
    /// Minutes. nil while macOS is still estimating.
    public var minutesRemaining: Int?
}

public enum DeviceStats {
    /// Cumulative bytes per physical disk, from IOBlockStorageDriver statistics.
    public static func diskCounters() -> [DiskCounters] {
        var result: [DiskCounters] = []
        forEachService("IOBlockStorageDriver") { entry in
            guard let props = properties(entry),
                  let stats = props["Statistics"] as? [String: Any]
            else { return }
            let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            var child: io_registry_entry_t = 0
            var name: String?
            if IORegistryEntryGetChildEntry(entry, kIOServicePlane, &child) == KERN_SUCCESS {
                name = properties(child)?["BSD Name"] as? String
                IOObjectRelease(child)
            }
            // Drivers with no media attached (empty card readers etc.) have no BSD name.
            guard let name else { return }
            result.append(DiskCounters(name: name, bytesRead: read, bytesWritten: write))
        }
        return result.sorted { $0.name < $1.name }
    }

    public static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            let plain = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
            return VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                available: important ?? plain ?? 0,
                isInternal: values.volumeIsInternal ?? false
            )
        }
    }

    /// 64-bit interface counters via NET_RT_IFLIST2 (getifaddrs only has 32-bit ones that wrap at 4 GB).
    public static func interfaceCounters() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return [] }
        var result: [InterfaceCounters] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuf) != nil {
                        result.append(InterfaceCounters(
                            name: String(cString: nameBuf),
                            bytesIn: info.ifm_data.ifi_ibytes,
                            bytesOut: info.ifm_data.ifi_obytes,
                            isUp: (info.ifm_flags & IFF_UP) != 0
                        ))
                    }
                }
                offset += length
            }
        }
        return result
    }

    /// IPv4/IPv6 addresses per interface name.
    public static func addresses() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: [String]] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            result[name, default: []].append(String(cString: host))
        }
        return result
    }

    /// GPU busy % from the accelerator's PerformanceStatistics. No root needed.
    public static func gpus() -> [GPUSample] {
        var result: [GPUSample] = []
        forEachService("IOAccelerator") { entry in
            guard let props = properties(entry),
                  let perf = props["PerformanceStatistics"] as? [String: Any]
            else { return }
            let util = (perf["Device Utilization %"] as? NSNumber)
                ?? (perf["GPU Activity(%)"] as? NSNumber)
                ?? (perf["Renderer Utilization %"] as? NSNumber)
            guard let util else { return }
            let memory = (perf["In use system memory"] as? NSNumber)?.uint64Value
                ?? (perf["vramUsedBytes"] as? NSNumber)?.uint64Value
            let name = (props["model"] as? String) ?? (props["IOClass"] as? String) ?? "GPU"
            result.append(GPUSample(name: name, utilization: util.doubleValue / 100, memoryInUse: memory))
        }
        return result
    }

    public static func battery() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? Double) ?? 0
            let max = (desc[kIOPSMaxCapacityKey] as? Double) ?? 100
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (desc[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return BatterySample(percent: max > 0 ? current / max : 0, isCharging: charging, onAC: onAC, minutesRemaining: minutes)
        }
        return nil
    }

    private static func forEachService(_ className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dict
    }
}
