import Foundation

public struct ClaudePaths: Sendable {
    public let claudeDir: URL

    public init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    public var sessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    public var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    public var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    public var appDir: URL { claudeDir.appendingPathComponent("session-bar") }
    public var statusFile: URL { appDir.appendingPathComponent("status.json") }
}
