import Charts
import SwiftUI
import BackgroundsCore

/// Rolling area graph. `maxValue` nil auto-scales to the peak, like btop's net graphs.
struct HistoryGraph: View {
    let values: [Double]
    var color: Color = .accentColor
    var maxValue: Double? = 1
    var height: CGFloat = 60

    var body: some View {
        let top = maxValue ?? max(values.max() ?? 1, 1)
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("v", min(value, top)))
                    .foregroundStyle(color.opacity(0.25))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", index), y: .value("v", min(value, top)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...max(1, values.count - 1))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        .accessibilityLabel("History graph")
    }
}

/// Horizontal meter with a label and value, for memory buckets, disks and cores.
struct Meter: View {
    let label: String
    let fraction: Double
    let value: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 90, alignment: .leading).lineLimit(1)
            ProgressView(value: min(1, max(0, fraction)))
                .tint(color)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(1)
        }
        .font(.callout)
    }
}

struct Card<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).foregroundStyle(.secondary).monospacedDigit() }
            }
            content()
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

func loadColor(_ fraction: Double) -> Color {
    switch fraction {
    case ..<0.5: .green
    case ..<0.8: .yellow
    default: .red
    }
}

struct OverviewView: View {
    let monitor: SystemMonitor

    var body: some View {
        if let snap = monitor.latest {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    cpuCard(snap)
                    memoryCard(snap)
                    networkCard(snap)
                    diskCard(snap)
                    if !snap.gpus.isEmpty { gpuCard(snap) }
                    systemCard(snap)
                }
                .padding(14)
            }
        } else {
            ProgressView("Sampling…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cpuCard(_ snap: SystemSnapshot) -> some View {
        Card(title: "CPU", trailing: Format.percent(snap.cpu.total.busy)) {
            HistoryGraph(values: monitor.cpuTotal.values, color: loadColor(snap.cpu.total.busy))
            HStack {
                Text("user \(Format.percent(snap.cpu.total.user))")
                Text("system \(Format.percent(snap.cpu.total.system))")
                Spacer()
                Text("load " + snap.load.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            let columns = snap.cpu.cores.count > 8 ? 4 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 6) {
                ForEach(Array(snap.cpu.cores.enumerated()), id: \.offset) { index, core in
                    CoreCell(
                        label: coreLabel(index),
                        values: index < monitor.cpuCores.count ? monitor.cpuCores[index].values : [],
                        busy: core.busy
                    )
                }
            }
        }
    }

    private func coreLabel(_ index: Int) -> String {
        let kind = index < monitor.host.coreKinds.count ? monitor.host.coreKinds[index] : ""
        return "\(kind)\(index)"
    }

    private func memoryCard(_ snap: SystemSnapshot) -> some View {
        let m = snap.memory
        return Card(title: "Memory", trailing: "\(Format.bytes(m.used)) / \(Format.bytes(m.total))") {
            HistoryGraph(values: monitor.memoryUsed.values, color: pressureColor(m.pressure))
            Meter(label: "App", fraction: frac(m.app, m.total), value: Format.bytes(m.app), color: .blue)
            Meter(label: "Wired", fraction: frac(m.wired, m.total), value: Format.bytes(m.wired), color: .orange)
            Meter(label: "Compressed", fraction: frac(m.compressed, m.total), value: Format.bytes(m.compressed), color: .purple)
            Meter(label: "Cached", fraction: frac(m.cached, m.total), value: Format.bytes(m.cached), color: .teal)
            Meter(label: "Available", fraction: frac(m.available, m.total), value: Format.bytes(m.available), color: .green)
            Meter(
                label: "Swap",
                fraction: m.swapFraction,
                value: m.swapTotal == 0 ? "off" : "\(Format.bytes(m.swapUsed)) / \(Format.bytes(m.swapTotal))",
                color: .pink
            )
            Text("Pressure: \(m.pressure.rawValue)").font(.caption).foregroundStyle(pressureColor(m.pressure))
        }
    }

    private func networkCard(_ snap: SystemSnapshot) -> some View {
        let active = snap.network.filter { $0.isUp && $0.name != "lo0" && ($0.totalIn > 0 || $0.totalOut > 0) }
        return Card(title: "Network") {
            HStack {
                Label(Format.rate(monitor.netIn.last), systemImage: "arrow.down").foregroundStyle(.blue)
                Spacer()
                Text("peak \(Format.rate(monitor.netIn.peak))").font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            HistoryGraph(values: monitor.netIn.values, color: .blue, maxValue: nil, height: 44)
            HStack {
                Label(Format.rate(monitor.netOut.last), systemImage: "arrow.up").foregroundStyle(.green)
                Spacer()
                Text("peak \(Format.rate(monitor.netOut.peak))").font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            HistoryGraph(values: monitor.netOut.values, color: .green, maxValue: nil, height: 44)
            ForEach(active) { net in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(net.name).bold()
                        Spacer()
                        Text("↓ \(Format.rate(net.inPerSecond))  ↑ \(Format.rate(net.outPerSecond))")
                            .monospacedDigit()
                    }
                    Text("total ↓ \(Format.bytes(net.totalIn))  ↑ \(Format.bytes(net.totalOut))"
                         + (net.addresses.isEmpty ? "" : "  ·  " + net.addresses.prefix(2).joined(separator: ", ")))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
        }
    }

    private func diskCard(_ snap: SystemSnapshot) -> some View {
        Card(title: "Disks") {
            HStack {
                Label(Format.rate(snap.diskRead), systemImage: "arrow.down.doc").foregroundStyle(.orange)
                Spacer()
                Label(Format.rate(snap.diskWrite), systemImage: "arrow.up.doc").foregroundStyle(.red)
            }
            .monospacedDigit()
            HistoryGraph(values: monitor.diskRead.values, color: .orange, maxValue: nil, height: 36)
            HistoryGraph(values: monitor.diskWrite.values, color: .red, maxValue: nil, height: 36)
            ForEach(snap.volumes) { vol in
                Meter(
                    label: vol.name,
                    fraction: vol.usedFraction,
                    value: "\(Format.bytes(vol.used)) / \(Format.bytes(vol.total))",
                    color: loadColor(vol.usedFraction)
                )
            }
        }
    }

    private func gpuCard(_ snap: SystemSnapshot) -> some View {
        let top = snap.gpus.map(\.utilization).max() ?? 0
        return Card(title: "GPU", trailing: Format.percent(top)) {
            HistoryGraph(values: monitor.gpu.values, color: .indigo)
            ForEach(Array(snap.gpus.enumerated()), id: \.offset) { _, gpu in
                Meter(
                    label: gpu.name,
                    fraction: gpu.utilization,
                    value: gpu.memoryInUse.map { Format.bytes($0) } ?? Format.percent(gpu.utilization),
                    color: .indigo
                )
            }
        }
    }

    private func systemCard(_ snap: SystemSnapshot) -> some View {
        let host = monitor.host
        return Card(title: "System") {
            LabeledContent("Model", value: host.model)
            LabeledContent("Chip", value: host.cpuName)
            LabeledContent("Cores", value: coreSummary(host))
            LabeledContent("macOS", value: host.osVersion)
            if let boot = host.bootTime {
                LabeledContent("Uptime", value: Format.duration(Date().timeIntervalSince(boot)))
            }
            LabeledContent("Processes", value: String(snap.processes.count))
            LabeledContent("Threads", value: String(snap.processes.compactMap(\.threads).reduce(0, +)) + "+")
            if let battery = snap.battery {
                LabeledContent("Battery") {
                    HStack(spacing: 6) {
                        Image(systemName: battery.isCharging ? "battery.100.bolt" : batterySymbol(battery.percent))
                        Text(Format.percent(battery.percent))
                        if let minutes = battery.minutesRemaining {
                            Text("· \(minutes / 60)h \(minutes % 60)m \(battery.isCharging ? "to full" : "left")")
                                .foregroundStyle(.secondary)
                        } else if battery.onAC {
                            Text("· on power").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .font(.callout)
    }

    private func coreSummary(_ host: HostInfo) -> String {
        let counts = Dictionary(grouping: host.coreKinds.filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        guard !counts.isEmpty else { return String(host.logicalCores) }
        return "\(host.logicalCores) (" + counts.sorted { $0.key > $1.key }.map { "\($0.value)\($0.key)" }.joined(separator: " + ") + ")"
    }

    private func batterySymbol(_ p: Double) -> String {
        switch p {
        case ..<0.15: "battery.0"
        case ..<0.4: "battery.25"
        case ..<0.65: "battery.50"
        case ..<0.9: "battery.75"
        default: "battery.100"
        }
    }

    private func frac(_ a: UInt64, _ b: UInt64) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
}

func pressureColor(_ p: MemorySample.Pressure) -> Color {
    switch p {
    case .normal: .green
    case .warning: .yellow
    case .critical: .red
    }
}

private struct CoreCell: View {
    let label: String
    let values: [Double]
    let busy: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            HistoryGraph(values: Array(values.suffix(40)), color: loadColor(busy), height: 18)
            Text(Format.percent(busy)).font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
        }
    }
}

/// Detail column for Overview: top consumers, click to jump to the process.
struct TopProcesses: View {
    let store: Store
    let monitor: SystemMonitor

    var body: some View {
        let procs = monitor.latest?.processes ?? []
        List {
            Section("Top CPU") {
                ForEach(procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8)) { row in
                    line(row, value: String(format: "%.1f%%", monitor.displayCPU(row.cpuPercent, perCore: store.settings.cpuPerCore)))
                }
            }
            Section("Top memory") {
                ForEach(procs.sorted { $0.residentBytes > $1.residentBytes }.prefix(8)) { row in
                    line(row, value: Format.bytes(row.residentBytes))
                }
            }
        }
    }

    private func line(_ row: ProcessRow, value: String) -> some View {
        Button {
            monitor.selectedPID = row.pid
            store.selectedSidebar = .processes
        } label: {
            HStack {
                Text(row.name).lineLimit(1)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
