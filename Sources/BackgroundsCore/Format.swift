import Foundation

public enum Format {
    public static func bytes(_ value: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(clamping: value))
    }

    public static func rate(_ perSecond: Double) -> String {
        bytes(UInt64(max(0, perSecond))) + "/s"
    }

    public static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", fraction * 100)
    }

    /// "3d 4h", "2h 5m", "4m 10s".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60, sec = s % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}
