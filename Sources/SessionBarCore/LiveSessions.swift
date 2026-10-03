import Foundation

public struct LiveSession: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case interactive, background }
    public enum State: String, Sendable { case busy, idle, blocked }

    public var id: String { sessionId }
    public let sessionId: String
    public var pid: Int32?
    public var cwd: String
    public var name: String
    public var kind: Kind
    public var state: State
    public var startedAt: Date
    public var bridgeSessionId: String?
    /// True when Claude Code made the name up (folder + id, e.g. "personal-a8") rather than you
    /// or the session itself naming it. The app shows the session's title instead.
    public var nameIsDerived = false

    public var isOnPhone: Bool { bridgeSessionId != nil }
    /// A background entry with no process behind it: a leftover record in `claude agents`, using
    /// nothing. `claude stop` can't stop it ("no job matching"); `claude rm` clears it, history stays.
    public var isLeftover: Bool { kind == .background && pid == nil }
    public var waitingFor: String? = nil
    public var shortId: String { String(sessionId.prefix(8)) }
    public var phoneURL: URL? { bridgeSessionId.flatMap { URL(string: "https://claude.ai/code/\($0)") } }
}

public enum LiveSessions {
    static func parsePidFile(_ data: Data) -> LiveSession? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = o["sessionId"] as? String, let cwd = o["cwd"] as? String else { return nil }
        var s = LiveSession(
            sessionId: sid,
            pid: (o["pid"] as? NSNumber)?.int32Value,
            cwd: cwd,
            name: (o["name"] as? String) ?? String(sid.prefix(8)),
            kind: (o["kind"] as? String) == "interactive" ? .interactive : .background,
            state: o["waitingFor"] is String ? .blocked : mapState(status: o["status"] as? String, state: nil),
            startedAt: date(ms: o["startedAt"]),
            bridgeSessionId: o["bridgeSessionId"] as? String,
            nameIsDerived: (o["nameSource"] as? String) == "derived" || (o["name"] as? String ?? String(sid.prefix(8))) == String(sid.prefix(8))
        )
        s.waitingFor = o["waitingFor"] as? String
        return s
    }

    /// Parses `claude agents --json`, which also lists background sessions that have no pid file.
    static func parseAgents(_ data: Data) -> [LiveSession] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let sid = o["sessionId"] as? String, let cwd = o["cwd"] as? String else { return nil }
            return LiveSession(
                sessionId: sid,
                pid: (o["pid"] as? NSNumber)?.int32Value,
                cwd: cwd,
                name: (o["name"] as? String) ?? String(sid.prefix(8)),
                kind: (o["kind"] as? String) == "interactive" ? .interactive : .background,
                state: mapState(status: o["status"] as? String, state: o["state"] as? String),
                startedAt: date(ms: o["startedAt"]),
                bridgeSessionId: nil,
                nameIsDerived: o["name"] == nil || (o["name"] as? String) == String(sid.prefix(8))
            )
        }
    }

    /// `status` (busy/idle) is what the process reports about itself, so it wins over the
    /// agent view's `state`; a background session with no live process only has `state`.
    static func mapState(status: String?, state: String?) -> LiveSession.State {
        switch status ?? state ?? "" {
        case "busy", "working", "running": return .busy
        case "idle": return .idle
        case "blocked", "waiting", "needs_input", "permission": return .blocked
        default: return .idle
        }
    }

    /// Agents list is the authority on *which* sessions are running; pid files add remote-control info.
    static func merge(agents: [LiveSession], pidFiles: [LiveSession]) -> [LiveSession] {
        let byId = Dictionary(pidFiles.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [LiveSession] = []
        for var s in agents {
            if let p = byId[s.sessionId] {
                s.bridgeSessionId = p.bridgeSessionId
                s.pid = s.pid ?? p.pid
                // The pid file knows where the name came from (nameSource); the agents list doesn't.
                s.name = p.name
                s.nameIsDerived = p.nameIsDerived
                // The pid file is rewritten on every status change; the agents list is fetched less often.
                s.state = p.state
                s.waitingFor = p.waitingFor
            }
            seen.insert(s.sessionId)
            out.append(s)
        }
        // A session that started a moment ago may be in the folder before the agents list catches up.
        out += pidFiles.filter { !seen.contains($0.sessionId) }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    public static func readPidFiles(_ paths: ClaudePaths) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap(parsePidFile)
        }
    }

    public static func load(_ paths: ClaudePaths, agentsJSON: Data?) -> [LiveSession] {
        let pid = readPidFiles(paths)
        guard let agentsJSON else { return pid.sorted { $0.startedAt > $1.startedAt } }
        // The agents list may be a minute old: drop entries whose process has since exited.
        let agents = parseAgents(agentsJSON).filter { $0.pid.map { kill($0, 0) == 0 } ?? true }
        return merge(agents: agents, pidFiles: pid)
    }

    private static func date(ms: Any?) -> Date {
        guard let n = ms as? NSNumber else { return .distantPast }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
}

/// Groups running sessions by project for a long list. The project is the first folder below the
/// folder all running sessions share (e.g. Work, Personal under ~/Projects).
public enum ProjectGroups {
    public struct Group: Sendable { public let name: String; public let sessions: [LiveSession] }

    public static func group(_ sessions: [LiveSession]) -> [Group] {
        let parts = sessions.map { $0.cwd.split(separator: "/").map(String.init) }
        var common = parts.first ?? []
        for p in parts.dropFirst() { common = Array(zip(common, p).prefix { $0 == $1 }.map(\.0)) }
        var order: [String] = []
        var byName: [String: [LiveSession]] = [:]
        for (s, p) in zip(sessions, parts) {
            let name = p.count > common.count ? p[common.count] : (p.last ?? "/")
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(s)
        }
        return order.map { Group(name: $0, sessions: byName[$0] ?? []) }
    }
}
