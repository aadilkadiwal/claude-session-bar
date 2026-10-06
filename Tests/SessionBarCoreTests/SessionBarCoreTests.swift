import XCTest
@testable import SessionBarCore

final class SessionBarCoreTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    func tempClaudeDir() throws -> ClaudePaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return ClaudePaths(claudeDir: dir)
    }

    // MARK: Live sessions

    func testMergeAddsPhoneInfoAndSortsNewestFirst() throws {
        let agents = LiveSessions.parseAgents(try fixture("agents.json"))
        let pid = try XCTUnwrap(LiveSessions.parsePidFile(try fixture("pidfile.json")))
        let merged = LiveSessions.merge(agents: agents, pidFiles: [pid])

        XCTAssertEqual(merged.map(\.shortId), ["12000003", "a0000001", "eb000002"])
        let personal = merged[1]
        XCTAssertTrue(personal.isOnPhone)
        XCTAssertEqual(personal.phoneURL?.absoluteString, "https://claude.ai/code/session_01TESTbridgeAAAAAAAAAAAA")
        XCTAssertEqual(personal.kind, .interactive)
        XCTAssertEqual(personal.state, .busy)
        XCTAssertFalse(merged[0].isOnPhone)
        XCTAssertTrue(personal.nameIsDerived, "pid file says Claude Code made the name up")
        XCTAssertFalse(merged[2].nameIsDerived, "\"unclear input handling\" is a real name")
    }

    func testShortIdNameCountsAsDerived() throws {
        let bg = #"{"pid":83489,"sessionId":"f0000004-0000-4000-8000-000000000004","cwd":"/p","kind":"bg","name":"f0000004","nameSource":null}"#
        XCTAssertEqual(LiveSessions.parsePidFile(Data(bg.utf8))?.nameIsDerived, true)
        let named = #"{"pid":1,"sessionId":"aaaaaaaa-1","cwd":"/p","name":"fix-login","nameSource":"user"}"#
        XCTAssertEqual(LiveSessions.parsePidFile(Data(named.utf8))?.nameIsDerived, false)
    }

    func testDraftDetectionOnPromptLine() {
        let idle = "  Claude Code v2.1\n────\n❯ \n────\n  ⏵⏵ auto mode on"
        XCTAssertEqual(SessionWindow.draft(in: idle), "")
        let typed = "────\n❯ half a message\n────"
        XCTAssertEqual(SessionWindow.draft(in: typed), "half a message")
        XCTAssertNil(SessionWindow.draft(in: "no prompt here"))
        XCTAssertEqual(SessionWindow.draft(in: "❯ /remote-control\n  ⎿  done\n❯ "), "", "only the last prompt line counts")
    }

    func testStateMapping() throws {
        let byId = Dictionary(uniqueKeysWithValues: LiveSessions.parseAgents(try fixture("agents.json")).map { ($0.shortId, $0) })
        XCTAssertEqual(byId["12000003"]?.state, .idle, "process status beats agent-view state")
        XCTAssertEqual(byId["eb000002"]?.state, .blocked, "no live process: fall back to state")
        XCTAssertEqual(byId["eb000002"]?.kind, .background)
        XCTAssertEqual(byId["eb000002"]?.isLeftover, true, "background entry with no process")
        XCTAssertEqual(byId["12000003"]?.isLeftover, false, "background with a live pid")
        XCTAssertEqual(byId["a0000001"]?.isLeftover, false)
    }

    func testPidFileOnlySessionStillListed() throws {
        let pid = try XCTUnwrap(LiveSessions.parsePidFile(try fixture("pidfile.json")))
        XCTAssertEqual(LiveSessions.merge(agents: [], pidFiles: [pid]).count, 1)
    }

    func testLoadFallsBackToPidFilesWhenCLIFails() throws {
        let paths = try tempClaudeDir()
        try FileManager.default.createDirectory(at: paths.sessionsDir, withIntermediateDirectories: true)
        try fixture("pidfile.json").write(to: paths.sessionsDir.appendingPathComponent("30601.json"))
        try Data("junk".utf8).write(to: paths.sessionsDir.appendingPathComponent("1.json"))
        XCTAssertEqual(LiveSessions.load(paths, agentsJSON: nil).map(\.name), ["personal-a8"])
    }

    // MARK: History

    func testHistoryParsePicksLatestTitleCwdAndModel() throws {
        let data = try fixture("transcript.jsonl")
        let s = try XCTUnwrap(HistoryScanner.parse(chunks: [data], sessionId: "aaaaaaaa-1111-2222-3333-444444444444",
                                                   url: URL(fileURLWithPath: "/x.jsonl"), mtime: Date(), size: 1, folderSlug: "slug"))
        XCTAssertEqual(s.name, "Login bug fix")
        XCTAssertEqual(s.cwd, "/Users/me/Projects/demo app")
        XCTAssertEqual(s.model, "claude-sonnet-5-5", "synthetic messages are ignored")
        XCTAssertEqual(s.lastPrompt, "fix the login bug please")
        XCTAssertEqual(s.shortId, "aaaaaaaa")
    }

    func testCustomTitleBeatsAITitleAndFallbacks() {
        func name(_ lines: String) -> String? {
            HistoryScanner.parse(chunks: [Data(lines.utf8)], sessionId: "bbbbbbbb-0000", url: URL(fileURLWithPath: "/x"),
                                 mtime: Date(), size: 1, folderSlug: "-Users-me-proj")?.name
        }
        XCTAssertEqual(name(#"{"type":"custom-title","customTitle":"Mine"}"# + "\n" + #"{"type":"ai-title","aiTitle":"AI"}"#), "Mine")
        XCTAssertEqual(name(#"{"type":"last-prompt","lastPrompt":"only a prompt"}"#), "only a prompt")
        XCTAssertEqual(name(""), "bbbbbbbb")
    }

    func testScannerReadsFoldersAndUsesCache() throws {
        let paths = try tempClaudeDir()
        let proj = paths.projectsDir.appendingPathComponent("-Users-me-demo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("aaaaaaaa-1111-2222-3333-444444444444.jsonl")
        try fixture("transcript.jsonl").write(to: file)
        try FileManager.default.createDirectory(at: proj.appendingPathComponent("aaaaaaaa-1111-2222-3333-444444444444/subagents"), withIntermediateDirectories: true)

        let scanner = HistoryScanner(paths: paths)
        XCTAssertEqual(scanner.scan().map(\.name), ["Login bug fix"])
        XCTAssertEqual(scanner.scan().count, 1, "subagent folders are not sessions")
    }

    func testSessionDetailCountsPromptsTokensAndLastReply() throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"first question"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:05.000Z","message":{"id":"m1","content":[{"type":"text","text":"answer one"}],"usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:06.000Z","message":{"id":"m1","content":[{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"user","timestamp":"2026-10-01T10:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"user","isMeta":true,"timestamp":"2026-10-01T10:00:08.000Z","message":{"role":"user","content":"<meta>"}}"#,
            #"{"type":"user","timestamp":"2026-10-01T10:20:00.000Z","message":{"role":"user","content":"second question"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:30:00.000Z","message":{"id":"m2","content":[{"type":"text","text":"final answer"}],"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3}}}"#,
        ].joined(separator: "\n")
        let d = SessionDetail.parse(Data(lines.utf8))
        XCTAssertEqual(d.prompts, 2, "tool results and meta lines aren't prompts")
        XCTAssertEqual(d.tokens, 21, "m1 counted once (15) + m2 (6)")
        XCTAssertEqual(d.lastReply, "final answer")
        XCTAssertEqual(d.duration ?? 0, 1800, accuracy: 0.5)
    }

    func testRenameClosedSessionAppendsCustomTitle() throws {
        let paths = try tempClaudeDir()
        let file = paths.claudeDir.appendingPathComponent("aaaaaaaa-1111-2222-3333-444444444444.jsonl")
        var data = try fixture("transcript.jsonl")
        data.removeLast() // no trailing newline: rename must still start a fresh line
        try data.write(to: file)
        let h = try XCTUnwrap(HistoryScanner.parse(url: file, mtime: Date(), size: Int64(data.count), folderSlug: "x"))
        try HistoryScanner.rename(h, to: "Login fix (renamed)")
        let again = try XCTUnwrap(HistoryScanner.parse(url: file, mtime: Date(), size: 1, folderSlug: "x"))
        XCTAssertEqual(again.name, "Login fix (renamed)")
        XCTAssertFalse(again.isEmpty)
    }

    func testEmptySessionDetection() {
        let s = HistoryScanner.parse(chunks: [Data(#"{"type":"last-prompt","sessionId":"x"}"#.utf8)], sessionId: "eeeeeeee",
                                     url: URL(fileURLWithPath: "/x"), mtime: Date(), size: 300, folderSlug: "x")
        XCTAssertEqual(s?.isEmpty, true)
    }

    func testWaitingForMarksSessionBlocked() {
        let json = #"{"pid":5,"sessionId":"wwwwwwww-1","cwd":"/p","kind":"interactive","status":"busy","waitingFor":"permission to run Bash"}"#
        let s = LiveSessions.parsePidFile(Data(json.utf8))
        XCTAssertEqual(s?.state, .blocked)
        XCTAssertEqual(s?.waitingFor, "permission to run Bash")
    }

    func testProjectGroupsUseFirstFolderBelowCommonPath() {
        func s(_ cwd: String) -> LiveSession {
            LiveSession(sessionId: UUID().uuidString, pid: 1, cwd: cwd, name: "x", kind: .interactive, state: .idle, startedAt: Date(), bridgeSessionId: nil)
        }
        let groups = ProjectGroups.group([s("/u/P/Work/ClientA/web"), s("/u/P/Personal"), s("/u/P/Work/ClientA/api"), s("/u/P/Personal/notes")])
        XCTAssertEqual(groups.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(groups.map(\.sessions.count), [2, 2])
    }

    // MARK: Forecast

    func window(_ pct: Double, resets: Date?) -> LimitWindow { LimitWindow(key: "five_hour", usedPercent: pct, resetsAt: resets) }

    func testForecastReachesLimitBeforeReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3 * 3600)
        // 40% → 60% over 30 minutes = 40%/hour; 40% left → 1 hour.
        let samples = [UsageSample(at: now.addingTimeInterval(-1800), key: "five_hour", percent: 40, resetsAt: reset),
                       UsageSample(at: now, key: "five_hour", percent: 60, resetsAt: reset)]
        XCTAssertEqual(Forecast.compute(window(60, resets: reset), samples: samples, now: now), .reachesLimit(at: now.addingTimeInterval(3600)))
    }

    func testForecastSafeUnknownAndOtherPeriod() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(1800)
        let slow = [UsageSample(at: now.addingTimeInterval(-3000), key: "five_hour", percent: 10, resetsAt: reset),
                    UsageSample(at: now, key: "five_hour", percent: 12, resetsAt: reset)]
        XCTAssertEqual(Forecast.compute(window(12, resets: reset), samples: slow, now: now), .safeUntilReset)
        let tooShort = [UsageSample(at: now.addingTimeInterval(-120), key: "five_hour", percent: 10, resetsAt: reset),
                        UsageSample(at: now, key: "five_hour", percent: 30, resetsAt: reset)]
        XCTAssertEqual(Forecast.compute(window(30, resets: reset), samples: tooShort, now: now), .unknown, "under 10 minutes of data")
        let oldPeriod = [UsageSample(at: now.addingTimeInterval(-1800), key: "five_hour", percent: 5, resetsAt: now.addingTimeInterval(-60)),
                         UsageSample(at: now, key: "five_hour", percent: 30, resetsAt: reset)]
        XCTAssertEqual(Forecast.compute(window(30, resets: reset), samples: oldPeriod, now: now), .unknown, "readings before a reset don't count")
    }

    func testUsageLogSkipsRepeatsAndTrimsOld() throws {
        let paths = try tempClaudeDir()
        let log = UsageLog(paths: paths)
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let old = UsageSample(at: now.addingTimeInterval(-9 * 86400), key: "five_hour", percent: 1, resetsAt: nil)
        let snap = UsageSnapshot(windows: [LimitWindow(key: "five_hour", usedPercent: 20, resetsAt: reset)], model: nil, updatedAt: now)
        var all = log.record(snap, existing: [old], now: now)
        XCTAssertEqual(all.map(\.percent), [20], "9-day-old reading dropped")
        all = log.record(snap, existing: all, now: now)
        XCTAssertEqual(all.count, 1, "unchanged reading not stored twice")
        XCTAssertEqual(log.load(now: now).map(\.percent), [20])
    }

    func testTrashRemovesTranscriptAndSideFolder() throws {
        let paths = try tempClaudeDir()
        let file = paths.claudeDir.appendingPathComponent("cccccccc.jsonl")
        let side = paths.claudeDir.appendingPathComponent("cccccccc")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        try HistoryScanner.trash(HistorySession(sessionId: "cccccccc", fileURL: file, cwd: "/", name: "x",
                                                lastPrompt: nil, model: nil, lastActive: Date(), bytes: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: side.path))
    }

    func testActiveRange() {
        let now = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let hoursAgo = { (h: Double) in now.addingTimeInterval(-h * 3600) }
        XCTAssertTrue(ActiveRange.today.matches(hoursAgo(2), now: now, calendar: cal))
        XCTAssertFalse(ActiveRange.today.matches(hoursAgo(13), now: now, calendar: cal), "yesterday")
        XCTAssertTrue(ActiveRange.week.matches(hoursAgo(24 * 6), now: now))
        XCTAssertFalse(ActiveRange.week.matches(hoursAgo(24 * 8), now: now))
        XCTAssertTrue(ActiveRange.olderThanWeek.matches(hoursAgo(24 * 8), now: now))
        XCTAssertFalse(ActiveRange.olderThanMonth.matches(hoursAgo(24 * 29), now: now))
        XCTAssertTrue(ActiveRange.olderThanMonth.matches(hoursAgo(24 * 31), now: now))
        XCTAssertTrue(ActiveRange.any.matches(.distantPast, now: now))
    }

    // MARK: Usage

    func testUsageParse() throws {
        let u = try XCTUnwrap(UsageSnapshot.parse(try fixture("status.json"), updatedAt: Date()))
        XCTAssertEqual(u.windows.map(\.key), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertEqual(u.fiveHour?.usedPercent ?? 0, 42.4, accuracy: 0.01)
        XCTAssertEqual(u.weekly?.label, "Weekly")
        XCTAssertEqual(u.model, "Opus 5.5 (1M context)")
        let opus = try XCTUnwrap(u.window("seven_day_opus"))
        XCTAssertEqual(opus.usedPercent, 100, "clamped")
        XCTAssertEqual(opus.percent(), 0, "reset time has passed")
    }

    func testUsageFillsInactiveMainWindow() throws {
        let u = try XCTUnwrap(UsageSnapshot.parse(Data(#"{"rate_limits":{"seven_day":{"used_percentage":12}}}"#.utf8), updatedAt: Date()))
        XCTAssertEqual(u.windows.map(\.key), ["five_hour", "seven_day"])
        XCTAssertEqual(u.fiveHour?.usedPercent, 0)
        XCTAssertNil(u.fiveHour?.resetsAt)
    }

    func testUsageWithoutLimitsIsNil() {
        XCTAssertNil(UsageSnapshot.parse(Data(#"{"model":{},"rate_limits":null}"#.utf8), updatedAt: Date()))
        XCTAssertNil(UsageSnapshot.parse(Data(#"{"rate_limits":{}}"#.utf8), updatedAt: Date()))
    }

    // MARK: Settings

    func testRetentionWritePreservesOtherKeysAndBacksUp() throws {
        let paths = try tempClaudeDir()
        try Data(#"{"model":"opus","hooks":{"Stop":[{"matcher":""}]}}"#.utf8).write(to: paths.settingsFile)
        XCTAssertEqual(ClaudeSettings.retentionDays(paths), 30)

        try ClaudeSettings.setRetentionDays(180, paths)
        XCTAssertEqual(ClaudeSettings.retentionDays(paths), 180)
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.settingsFile)) as? [String: Any]
        XCTAssertEqual(o?["model"] as? String, "opus")
        XCTAssertNotNil(o?["hooks"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.settingsFile.path + ".session-bar-backup"))
    }

    func testRetentionRefusesBrokenSettings() throws {
        let paths = try tempClaudeDir()
        try Data("{ not json".utf8).write(to: paths.settingsFile)
        XCTAssertThrowsError(try ClaudeSettings.setRetentionDays(90, paths))
        XCTAssertEqual(try String(contentsOf: paths.settingsFile, encoding: .utf8), "{ not json")
    }

    // MARK: CLI

    func testArgsAndShellLines() {
        XCTAssertEqual(ClaudeCLI.ShellLine.resume("id1", cwd: "/p", phone: true), "cd '/p' && claude --resume 'id1' --remote-control")
        XCTAssertEqual(ClaudeCLI.Args.newOnPhone(name: "  "), ["--bg", "--remote-control"])
        XCTAssertEqual(ClaudeCLI.Args.remove("eb000002"), ["rm", "eb000002"])
        XCTAssertEqual(ClaudeCLI.Args.newOnPhone(name: "notes"), ["--bg", "--remote-control", "-n", "notes"])
        XCTAssertEqual(ClaudeCLI.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ClaudeCLI.ShellLine.new(cwd: "/a b", name: "x y"), "cd '/a b' && claude -n 'x y'")
        XCTAssertEqual(ClaudeCLI.ShellLine.resume("id1", cwd: "/p"), "cd '/p' && claude --resume 'id1'")
    }

    func testAppleScriptEscape() {
        XCTAssertEqual(ClaudeCLI.appleScriptEscape(#"cd '/a "b"' && x\y"#), #"cd '/a \"b\"' && x\\y"#)
    }

    func testCleanEnvironmentDropsClaudeSessionMarkers() {
        let env = ClaudeCLI.cleanEnvironment(["CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "HOME": "/h", "PATH": "/bin"])
        XCTAssertEqual(Set(env.keys), ["HOME", "PATH"])
    }

    /// Real end-to-end run against the installed `claude`. Opt in with
    /// SESSION_BAR_INTEGRATION=/path/to/a/trusted/folder swift test
    func testIntegrationNewOnPhoneThenStop() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SESSION_BAR_INTEGRATION"] else {
            throw XCTSkip("set SESSION_BAR_INTEGRATION to a trusted folder to run")
        }
        let cli = ClaudeCLI(executable: try XCTUnwrap(ClaudeCLI.locate()), paths: ClaudePaths())
        let name = "sb-it-\(UUID().uuidString.prefix(6))"
        try await cli.newOnPhone(cwd: dir, name: name)

        var found: LiveSession?
        for _ in 0..<40 where found == nil {
            try await Task.sleep(nanoseconds: 500_000_000)
            found = LiveSessions.load(cli.paths, agentsJSON: await cli.listAgentsJSON()).first { $0.name == name }
            if found?.isOnPhone == false { found = nil }
        }
        let s = try XCTUnwrap(found, "new session never appeared with remote control on")
        XCTAssertEqual(s.kind, .background)

        try await cli.stop(s)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = LiveSessions.load(cli.paths, agentsJSON: await cli.listAgentsJSON())
        XCTAssertFalse(after.contains { $0.sessionId == s.sessionId }, "session still running after stop")

        // Leave no trace: drop the background record and the transcript.
        _ = try? await cli.run(["rm", s.shortId])
        for h in HistoryScanner(paths: cli.paths).scan() where h.sessionId == s.sessionId { try? HistoryScanner.trash(h) }
    }
}
