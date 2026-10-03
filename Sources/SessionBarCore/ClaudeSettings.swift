import Foundation

/// Reads and writes `cleanupPeriodDays` in `~/.claude/settings.json` — Claude Code's own setting
/// for how long saved sessions are kept. Every other key in the file is left as it is.
public enum ClaudeSettings {
    public static let defaultRetentionDays = 30

    public static func retentionDays(_ paths: ClaudePaths) -> Int {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = o["cleanupPeriodDays"] as? NSNumber else { return defaultRetentionDays }
        return n.intValue
    }

    public enum Failure: LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't update ~/.claude/settings.json: \(why). Nothing was changed."
            }
        }
    }

    public static func setRetentionDays(_ days: Int, _ paths: ClaudePaths) throws {
        precondition(days > 0)
        let fm = FileManager.default
        var obj: [String: Any] = [:]
        if fm.fileExists(atPath: paths.settingsFile.path) {
            let data = try Data(contentsOf: paths.settingsFile)
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unreadable("it isn't a JSON object")
            }
            obj = o
            let backup = paths.settingsFile.appendingPathExtension("session-bar-backup")
            if !fm.fileExists(atPath: backup.path) { try data.write(to: backup) }
        }
        obj["cleanupPeriodDays"] = days
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: paths.settingsFile, options: .atomic)
    }
}
