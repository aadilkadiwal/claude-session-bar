import Foundation

public struct ClaudePaths: Sendable {
    public let claudeDir: URL
    public let tmpDir: URL

    public init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                tmpDir: URL = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())")) {
        self.claudeDir = claudeDir
        self.tmpDir = tmpDir
    }

    public var sessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    public var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    public var fileHistoryDir: URL { claudeDir.appendingPathComponent("file-history") }
    public var sessionEnvDir: URL { claudeDir.appendingPathComponent("session-env") }
    public var debugDir: URL { claudeDir.appendingPathComponent("debug") }
    public var todosDir: URL { claudeDir.appendingPathComponent("todos") }
    public var tasksDir: URL { claudeDir.appendingPathComponent("tasks") }
    public var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    public var appDir: URL { claudeDir.appendingPathComponent("session-bar") }
    public var statusFile: URL { appDir.appendingPathComponent("status.json") }
}
