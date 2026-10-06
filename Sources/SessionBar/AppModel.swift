import AppKit
import ServiceManagement
import SessionBarCore
import SwiftUI

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var isError = false
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var live: [LiveSession] = []
    @Published private(set) var history: [HistorySession] = []
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var working: Set<String> = []
    @Published private(set) var typingBlockers: [String: String] = [:]
    @Published var banner: Banner?
    @Published private(set) var retentionDays: Int
    @Published private(set) var refreshing = false
    var menuOpen = false { didSet { if menuOpen { Task { await refresh(history: true, agents: true) } } } }
    var detailsOpen = false

    let paths = ClaudePaths()
    let cli: ClaudeCLI?
    let notifier = Notifier()
    private let scanner: HistoryScanner
    private let usageLog: UsageLog
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var lastHistoryScan = Date.distantPast
    private var lastAgents: Data?
    private var lastAgentsFetch = Date.distantPast

    init() {
        let paths = self.paths
        scanner = HistoryScanner(paths: paths)
        usageLog = UsageLog(paths: paths)
        cli = ClaudeCLI.locate().map { ClaudeCLI(executable: $0, paths: paths) }
        retentionDays = ClaudeSettings.retentionDays(paths)
        samples = usageLog.load()
        if cli == nil {
            banner = Banner(text: "Couldn't find the claude command. Install Claude Code, then reopen Session Bar.", isError: true)
        }
        // Open at login is on by default; after the first launch it's the user's choice in Settings.
        if !UserDefaults.standard.bool(forKey: "didSetLoginDefault") {
            UserDefaults.standard.set(true, forKey: "didSetLoginDefault")
            try? SMAppService.mainApp.register()
        }
        notifier.onOpen = { [weak self] id in self?.openSession(id: id) }
        watch(paths.sessionsDir)
        watch(paths.appDir)
        // Cheap tick: re-reads the small session files and the usage snapshot (no processes started),
        // so "waiting for you" shows within seconds. `claude agents` runs only when due, see refresh().
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh(history: true, agents: true) }
    }

    var liveIds: Set<String> { Set(live.map(\.sessionId)) }
    var closed: [HistorySession] { history.filter { !liveIds.contains($0.sessionId) } }
    var needsYou: Bool { live.contains { $0.state == .blocked && !$0.isLeftover } }
    var emptySessions: [HistorySession] { closed.filter(\.isEmpty) }
    var duplicateNames: Set<String> {
        var seen = Set<String>(), dupes = Set<String>()
        for h in history where !seen.insert(h.name).inserted { dupes.insert(h.name) }
        return dupes
    }

    func forecast(_ w: LimitWindow) -> Forecast { Forecast.compute(w, samples: samples) }

    var recentFolders: [String] {
        var seen = Set<String>()
        return (live.map(\.cwd) + history.map(\.cwd))
            .filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
            .prefix(8).map { $0 }
    }

    /// Session files and usage every call. `claude agents` (which starts a process) every 5 s while
    /// a window is open, otherwise once a minute or when a session starts/stops. History once a minute.
    func refresh(history forceHistory: Bool = false, agents forceAgents: Bool = false) async {
        let agentsEvery: TimeInterval = (menuOpen || detailsOpen) ? 5 : 60
        if let cli, forceAgents || Date().timeIntervalSince(lastAgentsFetch) >= agentsEvery {
            lastAgentsFetch = Date()
            lastAgents = await cli.listAgentsJSON()
        }
        let next = LiveSessions.load(paths, agentsJSON: lastAgents)
        if next != live {
            notifier.sessionsChanged(from: live, to: next, name: displayName)
            live = next
            typingBlockers = Dictionary(uniqueKeysWithValues: next.compactMap { s in ClaudeCLI.typingBlocker(s).map { (s.sessionId, $0) } })
        }
        let u = UsageSnapshot.load(paths)
        if u != usage {
            usage = u
            if let u {
                samples = usageLog.record(u, existing: samples)
                notifier.usageChanged(u, forecast: forecast)
            }
        }
        if forceHistory || Date().timeIntervalSince(lastHistoryScan) > 60 { await refreshHistory() }
    }

    func refreshNow() async {
        refreshing = true
        defer { refreshing = false }
        await refresh(history: true, agents: true)
    }

    func refreshHistory() async {
        lastHistoryScan = Date()
        let scanner = self.scanner
        let h = await Task.detached { scanner.scan() }.value
        if h != history { history = h }
    }

    private func watch(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            let sessions = dir == self?.paths.sessionsDir
            Task { @MainActor in await self?.refresh(history: sessions, agents: sessions) }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watchers.append(src)
    }

    func openSession(id: String) {
        if let s = live.first(where: { $0.sessionId == id }) { open(s) }
        else if let h = history.first(where: { $0.sessionId == id }) { resumeInTerminal(h) }
    }

    private func perform(_ id: String, success: String? = nil, _ body: @escaping (ClaudeCLI) async throws -> Void) {
        guard let cli else { return }
        working.insert(id)
        Task {
            defer { working.remove(id) }
            do {
                try await body(cli)
                if let success { banner = Banner(text: success) }
            } catch let ClaudeCLI.Failure.untrusted(folder) {
                banner = Banner(text: ClaudeCLI.Failure.untrusted(folder: folder).errorDescription ?? "", isError: true,
                                actionTitle: "Open in iTerm") { [weak self] in
                    self?.openTerminal(ClaudeCLI.ShellLine.new(cwd: folder, name: ""))
                }
            } catch {
                banner = Banner(text: error.localizedDescription, isError: true)
            }
            await refresh(history: true)
        }
    }

    func stop(_ s: LiveSession) {
        perform(s.sessionId, success: s.isLeftover ? "Cleared \(displayName(s)). Its history is still in Recent." : "Stopped \(displayName(s)).") { try await $0.stop(s) }
    }

    /// Phone on: a terminal session gets /remote-control typed into it and keeps running on the Mac.
    /// A background session has no window, so it reopens in iTerm/Terminal with remote control on.
    func phoneOn(_ s: LiveSession) {
        let name = displayName(s)
        if s.kind == .interactive {
            perform(s.sessionId, success: "\(name) is on your phone and still open on your Mac.") { try await $0.setPhone(s, on: true) }
        } else {
            perform(s.sessionId, success: "\(name) is open in iTerm and on your phone.") { try await $0.openWithPhone(s) }
        }
    }

    func phoneOff(_ s: LiveSession) {
        perform(s.sessionId, success: "\(displayName(s)) is off your phone. It's still running on your Mac.") { try await $0.setPhone(s, on: false) }
    }

    func rename(_ s: LiveSession, to name: String) {
        perform(s.sessionId, success: "Renamed to \(name).") { try await $0.rename(s, to: name) }
    }

    func rename(_ h: HistorySession, to name: String) {
        do {
            try HistoryScanner.rename(h, to: name)
            banner = Banner(text: "Renamed to \(name).")
        } catch { banner = Banner(text: "Couldn't rename: \(error.localizedDescription)", isError: true) }
        Task { await refreshHistory() }
    }

    /// Running sessions named by Claude Code ("personal-a8") show the session's title instead,
    /// the same one the closed list uses. Names you set yourself are kept.
    func displayName(_ s: LiveSession) -> String {
        guard s.nameIsDerived, let h = history.first(where: { $0.sessionId == s.sessionId }), h.name != h.shortId else { return s.name }
        return h.name
    }

    func newOnPhone(folder: String, name: String) {
        perform("new", success: "Started a session in \(Fmt.folderName(folder)). It's on your phone now.") {
            try await $0.newOnPhone(cwd: folder, name: name)
        }
    }

    func newInTerminal(folder: String, name: String) { openTerminal(ClaudeCLI.ShellLine.new(cwd: folder, name: name)) }
    func resumeInTerminal(_ h: HistorySession) { openTerminal(ClaudeCLI.ShellLine.resume(h.sessionId, cwd: h.cwd)) }

    func open(_ s: LiveSession) {
        if s.kind == .interactive, let pid = s.pid, ClaudeCLI.focusTerminal(pid: pid) { return }
        openTerminal(ClaudeCLI.ShellLine.attach(s.shortId))
    }

    func openTerminal(_ line: String) {
        do { try cli?.openInITerm(line) } catch { banner = Banner(text: error.localizedDescription, isError: true) }
    }

    /// Only closed sessions; running ones are skipped so a live transcript is never pulled away.
    func delete(_ sessions: [HistorySession]) {
        let ids = liveIds
        var failed = 0, done = 0
        for s in sessions where !ids.contains(s.sessionId) {
            do { try HistoryScanner.trash(s); done += 1 } catch { failed += 1 }
        }
        banner = failed == 0
            ? Banner(text: "Moved \(done) session\(done == 1 ? "" : "s") to the Trash.")
            : Banner(text: "Moved \(done) to the Trash; \(failed) couldn't be moved.", isError: true)
        Task { await refreshHistory() }
    }

    func setRetention(_ days: Int) {
        do {
            try ClaudeSettings.setRetentionDays(days, paths)
            retentionDays = days
            banner = Banner(text: "Claude Code will now keep sessions for \(days) days.")
        } catch {
            banner = Banner(text: error.localizedDescription, isError: true)
        }
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = Banner(text: "Couldn't change Open at login: \(error.localizedDescription)", isError: true)
        }
        objectWillChange.send()
    }
}

enum Fmt {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func folderName(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func shortPath(_ path: String) -> String {
        var p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 4 { p = "\(parts[0])/…/\(parts[parts.count - 2])/\(parts[parts.count - 1])" }
        return p
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(d) < 60 { return "now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: now)
    }

    static func resets(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        if d <= now { return "reset" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return "resets " + f.string(from: d)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }

    static func forecast(_ f: Forecast) -> String? {
        switch f {
        case .reachesLimit(let at): return at <= Date() ? "Limit reached" : "At this pace: 100% at \(clock(at))"
        case .safeUntilReset: return "Safe until reset at this pace"
        case .unknown: return nil
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
    }

    static func model(_ id: String?) -> String {
        guard let id else { return "—" }
        // claude-opus-5-5 → Opus 5.5
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix(2).filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " \(version)")
    }
}
