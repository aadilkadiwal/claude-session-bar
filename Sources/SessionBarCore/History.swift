import Foundation

public struct HistorySession: Identifiable, Equatable, Sendable {
    public var id: String { sessionId }
    public let sessionId: String
    public let fileURL: URL
    public var cwd: String
    public var name: String
    public var lastPrompt: String?
    public var model: String?
    public var lastActive: Date
    public var bytes: Int64
    public var shortId: String { String(sessionId.prefix(8)) }
    /// Opened and closed without a reply from Claude. Small files are read whole, so "no model
    /// seen" is reliable for them.
    public var isEmpty: Bool { model == nil && bytes < Int64(HistoryScanner.chunk) }
}

/// Reads only the head and tail of each transcript (they can be tens of MB) and caches by
/// mtime+size, so rescanning a few hundred sessions every minute costs almost nothing.
public final class HistoryScanner: @unchecked Sendable {
    private let paths: ClaudePaths
    private var cache: [URL: (stamp: String, session: HistorySession)] = [:]
    private let lock = NSLock()
    static let chunk = 128 * 1024

    public init(paths: ClaudePaths) { self.paths = paths }

    public func scan() -> [HistorySession] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let projects = (try? fm.contentsOfDirectory(at: paths.projectsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [HistorySession] = []
        lock.lock(); defer { lock.unlock() }
        var fresh: [URL: (String, HistorySession)] = [:]
        for dir in projects {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            for url in files where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = v.contentModificationDate else { continue }
                let size = Int64(v.fileSize ?? 0)
                let stamp = "\(mtime.timeIntervalSince1970)-\(size)"
                let s: HistorySession
                if let c = cache[url], c.stamp == stamp { s = c.session }
                else if let parsed = Self.parse(url: url, mtime: mtime, size: size, folderSlug: dir.lastPathComponent) { s = parsed }
                else { continue }
                fresh[url] = (stamp, s)
                out.append(s)
            }
        }
        cache = fresh
        return out.sorted { $0.lastActive > $1.lastActive }
    }

    static func parse(url: URL, mtime: Date, size: Int64, folderSlug: String) -> HistorySession? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: chunk)) ?? Data()
        var tail = Data()
        if size > Int64(chunk) {
            try? fh.seek(toOffset: UInt64(max(Int64(chunk), size - Int64(chunk))))
            tail = (try? fh.readToEnd()) ?? Data()
        }
        return parse(chunks: [head, tail], sessionId: url.deletingPathExtension().lastPathComponent,
                     url: url, mtime: mtime, size: size, folderSlug: folderSlug)
    }

    /// Later lines win, so pass chunks in file order.
    static func parse(chunks: [Data], sessionId: String, url: URL, mtime: Date, size: Int64, folderSlug: String) -> HistorySession? {
        var cwd: String?, custom: String?, agent: String?, ai: String?, prompt: String?, model: String?
        for chunk in chunks {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if cwd == nil, let c = o["cwd"] as? String { cwd = c }
                switch o["type"] as? String {
                case "custom-title": custom = (o["customTitle"] as? String) ?? custom
                case "agent-name": agent = (o["agentName"] as? String) ?? agent
                case "ai-title": ai = (o["aiTitle"] as? String) ?? ai
                case "last-prompt": prompt = (o["lastPrompt"] as? String) ?? prompt
                case "assistant":
                    if let m = (o["message"] as? [String: Any])?["model"] as? String, m != "<synthetic>" { model = m }
                default: break
                }
            }
        }
        let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = [custom, agent, ai, p.map { String($0.prefix(60)) }]
            .compactMap { $0 }.first { !$0.isEmpty } ?? String(sessionId.prefix(8))
        return HistorySession(sessionId: sessionId, fileURL: url, cwd: cwd ?? folderSlug, name: name,
                              lastPrompt: p, model: model, lastActive: mtime, bytes: size)
    }

    /// Renames a closed session the way Claude Code's /rename does: a `custom-title` line at the end.
    public static func rename(_ s: HistorySession, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let line = try JSONSerialization.data(withJSONObject: ["type": "custom-title", "customTitle": title, "sessionId": s.sessionId],
                                              options: [.withoutEscapingSlashes])
        let fh = try FileHandle(forUpdating: s.fileURL)
        defer { try? fh.close() }
        let end = try fh.seekToEnd()
        var prefix = Data()
        if end > 0 {
            try fh.seek(toOffset: end - 1)
            if try fh.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) { prefix = Data([UInt8(ascii: "\n")]) }
        }
        try fh.seekToEnd()
        try fh.write(contentsOf: prefix + line + Data([UInt8(ascii: "\n")]))
    }

    public static func trash(_ s: HistorySession) throws {
        let fm = FileManager.default
        try fm.trashItem(at: s.fileURL, resultingItemURL: nil)
        let side = s.fileURL.deletingPathExtension()
        if fm.fileExists(atPath: side.path) { try fm.trashItem(at: side, resultingItemURL: nil) }
    }
}

public enum ActiveRange: String, CaseIterable, Identifiable, Sendable {
    case any = "Any time", today = "Today", week = "Last 7 days", olderThanWeek = "Older than 7 days", olderThanMonth = "Older than 30 days"
    public var id: String { rawValue }

    public func matches(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let age = now.timeIntervalSince(d)
        switch self {
        case .any: return true
        case .today: return calendar.isDate(d, inSameDayAs: now)
        case .week: return age <= 7 * 86400
        case .olderThanWeek: return age > 7 * 86400
        case .olderThanMonth: return age > 30 * 86400
        }
    }
}

public struct SessionDetail: Equatable, Sendable {
    public var prompts = 0
    public var lastReply: String?
    public var firstAt: Date?
    public var lastAt: Date?
    public var tokens = 0
    public var duration: TimeInterval? { firstAt.flatMap { f in lastAt.map { $0.timeIntervalSince(f) } } }

    public static func load(_ url: URL) -> SessionDetail {
        guard let data = try? Data(contentsOf: url) else { return SessionDetail() }
        return parse(data)
    }

    static func parse(_ data: Data) -> SessionDetail {
        var d = SessionDetail()
        var seen = Set<String>()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = o["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            if let ts = (o["timestamp"] as? String).flatMap(iso.date(from:)) {
                d.firstAt = d.firstAt ?? ts
                d.lastAt = ts
            }
            let msg = o["message"] as? [String: Any]
            if type == "user" {
                // Real prompts only: tool results also arrive as "user" lines, as content arrays.
                if msg?["content"] is String, o["isMeta"] as? Bool != true { d.prompts += 1 }
                continue
            }
            if let id = msg?["id"] as? String, seen.insert(id).inserted, let u = msg?["usage"] as? [String: Any] {
                d.tokens += ["input_tokens", "output_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
            }
            if let parts = msg?["content"] as? [[String: Any]],
               let text = parts.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                d.lastReply = text
            }
        }
        return d
    }
}
