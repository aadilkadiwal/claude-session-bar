import Foundation

public struct LimitWindow: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String          // five_hour, seven_day, seven_day_opus, ...
    public let usedPercent: Double  // 0...100
    public let resetsAt: Date?

    public var label: String {
        switch key {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        case "spend_limit": return "Spend limit"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Once the reset time has passed the window is empty again, even before Claude Code reports it.
    public func percent(at now: Date = Date()) -> Double {
        if let r = resetsAt, r <= now { return 0 }
        return usedPercent
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let windows: [LimitWindow]
    public let model: String?
    public let updatedAt: Date

    public func window(_ key: String) -> LimitWindow? { windows.first { $0.key == key } }
    public var fiveHour: LimitWindow? { window("five_hour") }
    public var weekly: LimitWindow? { window("seven_day") }

    static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "spend_limit"]

    public static func parse(_ data: Data, updatedAt: Date) -> UsageSnapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = o["rate_limits"] as? [String: Any] else { return nil }
        var windows: [LimitWindow] = rl.compactMap { key, value in
            guard let w = value as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitWindow(key: key, usedPercent: min(max(pct, 0), 100), resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        // Claude Code omits a window that isn't running (e.g. 5-hour after a reset): show it at 0%.
        for key in ["five_hour", "seven_day"] where !windows.contains(where: { $0.key == key }) {
            windows.append(LimitWindow(key: key, usedPercent: 0, resetsAt: nil))
        }
        windows.sort { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
        let model = (o["model"] as? [String: Any])?["display_name"] as? String
        return UsageSnapshot(windows: windows, model: model, updatedAt: updatedAt)
    }

    public static func load(_ paths: ClaudePaths) -> UsageSnapshot? {
        let url = paths.statusFile
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return parse(data, updatedAt: mtime)
    }
}
