import AppKit
import Foundation

public struct ClaudeCLI: Sendable {
    public let executable: URL
    public let paths: ClaudePaths

    public init(executable: URL, paths: ClaudePaths) {
        self.executable = executable
        self.paths = paths
    }

    /// GUI apps start with a bare PATH, so check the usual install spots, then ask a login shell.
    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    public enum Args {
        public static let listAgents = ["agents", "--json"]
        public static func stop(_ shortId: String) -> [String] { ["stop", shortId] }
        /// Removes a background entry, even one with no process. The conversation history is kept.
        public static func remove(_ shortId: String) -> [String] { ["rm", shortId] }
        public static func newOnPhone(name: String) -> [String] {
            let n = name.trimmingCharacters(in: .whitespaces)
            return ["--bg", "--remote-control"] + (n.isEmpty ? [] : ["-n", n])
        }
    }

    public enum ShellLine {
        public static func resume(_ sessionId: String, cwd: String, phone: Bool = false) -> String {
            "cd \(quote(cwd)) && claude --resume \(quote(sessionId))" + (phone ? " --remote-control" : "")
        }
        public static func attach(_ shortId: String) -> String { "claude attach \(quote(shortId))" }
        public static func new(cwd: String, name: String) -> String {
            let n = name.trimmingCharacters(in: .whitespaces)
            return "cd \(quote(cwd)) && claude" + (n.isEmpty ? "" : " -n \(quote(n))")
        }
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public enum Failure: LocalizedError, Equatable {
        case untrusted(folder: String)
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .untrusted(let f):
                return "\((f as NSString).lastPathComponent) isn't a trusted folder yet. Open it once in iTerm or Terminal and accept the trust prompt, then try again."
            case .failed(let msg): return msg
            }
        }
    }

    /// Variables Claude Code sets inside its own sessions. Passing them on would make a new session
    /// think it is a child of another one (and skip saving its transcript).
    static func cleanEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { !$0.key.hasPrefix("CLAUDE") && $0.key != "CLAUDECODE" }
    }

    @discardableResult
    public func run(_ args: [String], cwd: String? = nil) async throws -> String {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = Self.cleanEnvironment(ProcessInfo.processInfo.environment)
        env["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        // Finished = process exited AND its output is drained. Draining while it runs keeps a large
        // output from filling the pipe; terminationHandler avoids waitUntilExit, which needs a run loop.
        let done = DispatchGroup()
        let buffer = OutputBuffer()
        done.enter(); done.enter()
        p.terminationHandler = { _ in done.leave() }
        let output: String = try await withCheckedThrowingContinuation { cont in
            do { try p.run() } catch {
                cont.resume(throwing: Failure.failed("Couldn't run claude: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().async {
                buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
                done.leave()
            }
            done.notify(queue: .global()) { cont.resume(returning: String(decoding: buffer.data, as: UTF8.self)) }
        }
        if output.contains("Workspace not trusted") { throw Failure.untrusted(folder: cwd ?? "") }
        if p.terminationStatus != 0 {
            let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(msg.isEmpty ? "claude exited with code \(p.terminationStatus)" : msg)
        }
        return output
    }

    private final class OutputBuffer: @unchecked Sendable { var data = Data() }

    public func listAgentsJSON() async -> Data? {
        guard let out = try? await run(Args.listAgents) else { return nil }
        return Data(out.utf8)
    }

    /// Stops a session. Ending the process also disconnects remote control, so it leaves the phone list.
    public func stop(_ s: LiveSession) async throws {
        if s.isLeftover { try await run(Args.remove(s.shortId)); return }
        if s.kind == .background {
            do { try await run(Args.stop(s.shortId)) } catch Failure.failed(let msg) where msg.lowercased().contains("no job") {
                // Its process exited between our refresh and the click: clear the leftover entry instead.
                try await run(Args.remove(s.shortId))
            }
            return
        }
        try signalInteractive(s)
        _ = await waitUntilGone(s)
    }

    /// Terminal sessions get SIGTERM, the same clean shutdown as closing the tab. Only sent when the
    /// pid file still names this exact session, so a recycled pid can never hit some other process.
    func signalInteractive(_ s: LiveSession) throws {
        guard let pid = s.pid else { throw Failure.failed("No process id for this session.") }
        let file = paths.sessionsDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: file), let live = LiveSessions.parsePidFile(data),
              live.sessionId == s.sessionId else { return } // already gone
        if kill(pid, SIGTERM) != 0 { throw Failure.failed("Couldn't stop process \(pid) (errno \(errno)).") }
    }

    /// True once the session's pid file is removed, which Claude Code does on clean exit.
    public func waitUntilGone(_ s: LiveSession, timeout: TimeInterval = 10) async -> Bool {
        guard let pid = s.pid else { return true }
        let file = paths.sessionsDir.appendingPathComponent("\(pid).json").path
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: file) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Turns phone access on or off for a session running in iTerm or Terminal, by typing
    /// /remote-control into it, exactly as you would. The session keeps running on the Mac.
    @MainActor
    public func setPhone(_ s: LiveSession, on: Bool) async throws {
        guard s.kind == .interactive, let pid = s.pid else { throw Failure.failed("\(s.name) has no window to type into.") }
        // Typing into a busy session or a pending question could answer it by accident.
        guard s.state == .idle else {
            throw Failure.failed("\(s.name) is \(s.state == .busy ? "working" : "waiting on a question"). Try again once it's idle.")
        }
        let win = try SessionWindow.find(pid: pid)
        if !on && win.host == .terminal {
            // Turning it off means picking Disconnect from a menu, which needs arrow keys.
            throw Failure.failed("In Terminal, type /remote-control in the session and choose Disconnect.")
        }
        try typeCommand("/remote-control", into: win, sessionName: s.name)
        if on {
            guard await waitForPhone(pid: pid, on: true, timeout: 15) else {
                throw Failure.failed("Remote control didn't start. Check the session's window.")
            }
        } else {
            // When it's already on, the command opens a menu: Disconnect sits two rows above the default.
            guard await waitFor(timeout: 5, { (try? win.screen())?.contains("Disconnect this session") == true }) else {
                throw Failure.failed("The remote control menu didn't open. Check the session's window.")
            }
            try win.chooseAbove(2)
            guard await waitForPhone(pid: pid, on: false, timeout: 8) else {
                throw Failure.failed("Couldn't confirm the disconnect. Check the session's window.")
            }
        }
    }

    @MainActor
    public func rename(_ s: LiveSession, to name: String) async throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else { return }
        guard s.kind == .interactive, let pid = s.pid else { throw Failure.failed("\(s.name) has no window to type into.") }
        guard s.state == .idle else { throw Failure.failed("\(s.name) is busy. Try again once it's idle.") }
        let win = try SessionWindow.find(pid: pid)
        try typeCommand("/rename \(title)", into: win, sessionName: s.name)
    }

    @MainActor
    public static func typingBlocker(_ s: LiveSession) -> String? {
        if s.kind == .background { return nil }   // handled by reopening in iTerm, not typing
        if s.state == .busy { return "Available when it's idle. It's working on a reply." }
        if s.state == .blocked { return "Available after you answer its question." }
        guard let pid = s.pid else { return "This session has no window." }
        switch owningApp(pid: pid)?.bundleIdentifier {
        case TerminalApp.iterm.bundleId, TerminalApp.terminal.bundleId: return nil
        case let other: return "Runs in \(other.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent } ?? "an app") that Session Bar can't type into."
        }
    }

    /// Types a command and presses Return, without ever mixing it into text you were typing.
    /// iTerm: type it, read the prompt line back; it must be exactly the command (typing replaces a grey
    /// suggestion). Anything else means there was a draft, so erase what was typed and stop.
    /// Terminal can't type without Return, so it only goes ahead when the prompt looks empty.
    @MainActor
    func typeCommand(_ command: String, into win: SessionWindow, sessionName: String) throws {
        let draftError = Failure.failed("\(sessionName) has unsent text in its prompt. Send or clear it, then try again.")
        switch win.host {
        case .iterm:
            try win.type(command, enter: false)
            Thread.sleep(forTimeInterval: 0.5)
            guard SessionWindow.draft(in: try win.screen()) == command else {
                try win.erase(command.count)
                throw draftError
            }
            try win.type("", enter: true)
        case .terminal:
            if let d = SessionWindow.draft(in: try win.screen()), !d.isEmpty, !SessionWindow.isPlaceholder(d) { throw draftError }
            try win.type(command)
        }
    }

    /// A background session has no window, so reopen it in iTerm/Terminal with remote control on:
    /// you get it on the Mac and on your phone. Same session id, same history.
    @MainActor
    public func openWithPhone(_ s: LiveSession, app: TerminalApp) async throws {
        try await stop(s)
        try openInTerminal(ShellLine.resume(s.sessionId, cwd: s.cwd, phone: true), app: app)
    }

    @MainActor
    func waitForPhone(pid: Int32, on: Bool, timeout: TimeInterval) async -> Bool {
        let file = paths.sessionsDir.appendingPathComponent("\(pid).json")
        return await waitFor(timeout: timeout) {
            let s = (try? Data(contentsOf: file)).flatMap(LiveSessions.parsePidFile)
            return s?.isOnPhone == on
        }
    }

    @MainActor
    func waitFor(timeout: TimeInterval, _ check: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return check()
    }

    public func newOnPhone(cwd: String, name: String) async throws {
        try await run(Args.newOnPhone(name: name), cwd: cwd)
    }

    @MainActor
    public func openInTerminal(_ line: String, app: TerminalApp) throws {
        if app == .iterm, app.isInstalled { return try openInITerm(line) }
        // Terminal: a self-deleting `.command` file needs no Automation permission.
        try FileManager.default.createDirectory(at: paths.appDir, withIntermediateDirectories: true)
        let url = paths.appDir.appendingPathComponent("launch-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh -l\nrm -f \"$0\"\n\(line)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Terminal", url.path]
        try open.run()
    }

    /// iTerm doesn't reliably run `.command` files handed to it, so use its AppleScript API: a new
    /// tab in the front window (a new window only when none is open), then type the line into the
    /// user's normal shell. macOS asks once for permission to control iTerm.
    @MainActor
    func openInITerm(_ line: String) throws {
        let source = """
        tell application "iTerm"
            activate
            if current window is missing value then
                set w to (create window with default profile)
            else
                set w to current window
                tell w to create tab with default profile
            end if
            tell current session of w to write text "\(Self.appleScriptEscape(line))"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            let denied = (error[NSAppleScript.errorNumber] as? Int) == -1743
            throw Failure.failed(denied
                ? "Session Bar isn't allowed to control iTerm. Turn it on in System Settings → Privacy & Security → Automation."
                : "Couldn't open iTerm: \(msg)")
        }
    }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @MainActor
    public static func focusTerminal(pid: Int32) -> Bool {
        if let win = try? SessionWindow.find(pid: pid), (try? win.focus()) != nil { return true }
        return owningApp(pid: pid)?.activate() ?? false
    }

    /// The GUI app a process runs under, found by walking up its parents (claude → zsh → login → iTerm2).
    @MainActor
    public static func owningApp(pid: Int32) -> NSRunningApplication? {
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var current = pid
        var visited = Set<Int32>()
        while current > 1, visited.insert(current).inserted {
            if let app = apps[current], app.bundleIdentifier != Bundle.main.bundleIdentifier { return app }
            guard let parent = parentPid(of: current) else { break }
            current = parent
        }
        return nil
    }

    static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
