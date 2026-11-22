import Foundation

enum Formatters {
    static func bytes(_ b: UInt64) -> String {
        guard b > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(b)
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        if v >= 100 { return String(format: "%.0f %@", v, units[i]) }
        if v >= 10 { return String(format: "%.1f %@", v, units[i]) }
        return String(format: "%.2f %@", v, units[i])
    }

    static func count(_ n: Int64) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func timeAgo(_ date: Date) -> String {
        let sec = max(0, Int(Date().timeIntervalSince(date)))
        if sec < 60 { return "just now" }
        let mins = sec / 60
        if mins < 60 { return "\(mins)m ago" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h ago" }
        return "\(hrs / 24)d ago"
    }
}
