import Foundation

public struct CreatedFile: Identifiable, Equatable, Sendable {
    public enum State: Sendable { case untracked, changedSince, inGit }
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let state: State
    public var canDelete: Bool { state != .inGit }
}

public struct StorageSummary: Equatable, Sendable {
    public var conversations: Int64 = 0
    public var scratchpads: Int64 = 0
    public var undoBackups: Int64 = 0
    public var orphans: [URL] = []
    public var orphanBytes: Int64 = 0
}

public enum Leftovers {
    public static func paths(sessionId id: String, projectSlug: String, _ p: ClaudePaths) -> [URL] {
        let fm = FileManager.default
        var urls = [
            p.fileHistoryDir.appendingPathComponent(id),
            p.sessionEnvDir.appendingPathComponent(id),
            p.debugDir.appendingPathComponent("\(id).txt"),
            p.tasksDir.appendingPathComponent(id),
            p.tmpDir.appendingPathComponent(projectSlug).appendingPathComponent(id),
        ]
        let todos = (try? fm.contentsOfDirectory(atPath: p.todosDir.path)) ?? []
        urls += todos.filter { $0.hasPrefix(id) }.map { p.todosDir.appendingPathComponent($0) }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    public static func allPaths(_ s: HistorySession, _ p: ClaudePaths) -> [URL] {
        let side = s.fileURL.deletingPathExtension()
        return [s.fileURL, side].filter { FileManager.default.fileExists(atPath: $0.path) }
            + paths(sessionId: s.sessionId, projectSlug: s.fileURL.deletingLastPathComponent().lastPathComponent, p)
    }

    public static func size(_ urls: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else { total += fileSize(url); continue }
            let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            while let f = e?.nextObject() as? URL { total += fileSize(f) }
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }

    public static func createdFiles(_ s: HistorySession, _ p: ClaudePaths, isTracked: (URL) -> Bool = gitTracks) -> [CreatedFile] {
        var transcripts = [s.fileURL]
        let e = FileManager.default.enumerator(at: s.fileURL.deletingPathExtension(), includingPropertiesForKeys: nil)
        while let f = e?.nextObject() as? URL { if f.pathExtension == "jsonl" { transcripts.append(f) } }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var created = Set<String>(), lastTouch: [String: Date] = [:]
        for t in transcripts {
            guard let data = try? Data(contentsOf: t) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where line.count < 4_000_000 {
                guard line.firstRange(of: Data(#""filePath""#.utf8)) != nil,
                      let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let r = o["toolUseResult"] as? [String: Any], let path = r["filePath"] as? String else { continue }
                if r["type"] as? String == "create" { created.insert(path) }
                if let ts = (o["timestamp"] as? String).flatMap(iso.date(from:)) { lastTouch[path] = max(lastTouch[path] ?? ts, ts) }
            }
        }

        let ownRoots = [p.claudeDir.path, p.tmpDir.path, p.tmpDir.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")]
        return created.sorted().compactMap { path -> CreatedFile? in
            guard !ownRoots.contains(where: { path.hasPrefix($0 + "/") }),
                  let a = try? FileManager.default.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular
            else { return nil }
            let url = URL(fileURLWithPath: path)
            let mtime = a[.modificationDate] as? Date ?? .distantPast
            // A few seconds of slack: the write lands slightly before the transcript line is stamped.
            let state: CreatedFile.State = isTracked(url) ? .inGit
                : mtime > (lastTouch[path] ?? .distantPast).addingTimeInterval(5) ? .changedSince : .untracked
            return CreatedFile(url: url, bytes: (a[.size] as? NSNumber)?.int64Value ?? 0, state: state)
        }
    }

    public static func gitTracks(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", url.deletingLastPathComponent().path, "ls-files", "--error-unmatch", "--", url.lastPathComponent]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Skips anything touched in the last day: a new session has leftovers before its transcript.
    public static func orphans(_ p: ClaudePaths, keep: Set<String>, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        func sessionId(_ url: URL) -> String? {
            let id = String(url.lastPathComponent.prefix(36))
            return UUID(uuidString: id) == nil ? nil : id
        }

        var known = keep, candidates: [URL] = []
        for project in list(p.projectsDir) {
            let entries = list(project)
            known.formUnion(entries.filter { $0.pathExtension == "jsonl" }.compactMap(sessionId))
            candidates += entries.filter { $0.pathExtension.isEmpty && sessionId($0) != nil }
        }
        candidates += [p.fileHistoryDir, p.sessionEnvDir, p.tasksDir, p.todosDir].flatMap(list)
        candidates += list(p.debugDir).filter { $0.pathExtension == "txt" }
        candidates += list(p.tmpDir).flatMap(list)

        let dayAgo = now.addingTimeInterval(-86400)
        return candidates.filter { url in
            guard let id = sessionId(url), !known.contains(id),
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return false }
            return mtime < dayAgo
        }
    }

    public static func summary(_ p: ClaudePaths, keep: Set<String>) -> StorageSummary {
        let orphans = orphans(p, keep: keep)
        return StorageSummary(conversations: size([p.projectsDir]), scratchpads: size([p.tmpDir]),
                              undoBackups: size([p.fileHistoryDir]), orphans: orphans, orphanBytes: size(orphans))
    }

    @discardableResult
    public static func trash(_ urls: [URL]) -> Int {
        urls.filter { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) == nil }.count
    }
}
