import Foundation

public struct UsageSample: Codable, Equatable, Sendable {
    public let at: Date
    public let key: String        // five_hour, seven_day, ...
    public let percent: Double
    public let resetsAt: Date?
}

/// "At this pace you'll reach 100% at 3:40 PM" — worked out from recent readings in the same window.
public enum Forecast: Equatable, Sendable {
    case reachesLimit(at: Date)   // before the window resets
    case safeUntilReset           // won't reach 100% before the reset at this pace
    case unknown                  // not enough readings yet, or usage isn't rising

    static func lookback(for key: String) -> TimeInterval { key == "five_hour" ? 3600 : 24 * 3600 }

    public static func compute(_ window: LimitWindow, samples: [UsageSample], now: Date = Date()) -> Forecast {
        let pct = window.percent(at: now)
        if pct >= 100 { return .reachesLimit(at: now) }
        // Same window only: readings from before the last reset describe a different period.
        let recent = samples
            .filter { $0.key == window.key && $0.resetsAt == window.resetsAt && $0.at >= now.addingTimeInterval(-lookback(for: window.key)) }
            .sorted { $0.at < $1.at }
        guard let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= 10 * 60,     // at least 10 minutes of data
              last.percent > first.percent else { return .unknown }
        let perSecond = (last.percent - first.percent) / last.at.timeIntervalSince(first.at)
        let eta = now.addingTimeInterval((100 - pct) / perSecond)
        if let reset = window.resetsAt, eta >= reset { return .safeUntilReset }
        return .reachesLimit(at: eta)
    }
}

/// Small append-only log of readings (`~/.claude/session-bar/usage-log.jsonl`), trimmed to 8 days:
/// one weekly window plus a day. Nothing older is kept.
public struct UsageLog: Sendable {
    public let url: URL
    public static let keep: TimeInterval = 8 * 24 * 3600

    public init(paths: ClaudePaths) { url = paths.appDir.appendingPathComponent("usage-log.jsonl") }

    public func load(now: Date = Date()) -> [UsageSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? dec.decode(UsageSample.self, from: Data($0)) }
            .filter { $0.at >= now.addingTimeInterval(-Self.keep) }
    }

    @discardableResult
    public func record(_ snapshot: UsageSnapshot, existing: [UsageSample], now: Date = Date()) -> [UsageSample] {
        let added = snapshot.windows
            .map { UsageSample(at: snapshot.updatedAt, key: $0.key, percent: $0.usedPercent, resetsAt: $0.resetsAt) }
            .filter { s in existing.last(where: { $0.key == s.key }).map { $0.percent != s.percent || $0.resetsAt != s.resetsAt } ?? true }
        guard !added.isEmpty else { return existing }
        let fresh = (existing + added).filter { $0.at >= now.addingTimeInterval(-Self.keep) }
        let enc = JSONEncoder()
        let text = fresh.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
        return fresh
    }
}
