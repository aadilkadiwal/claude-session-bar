import AppKit

public enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case iterm, terminal

    public var id: String { rawValue }
    public var title: String { self == .iterm ? "iTerm" : "Terminal" }
    public var bundleId: String { self == .iterm ? "com.googlecode.iterm2" : "com.apple.Terminal" }

    @MainActor public var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
    @MainActor public var isInstalled: Bool { appURL != nil }

    public static let defaultsKey = "terminalApp"
    @MainActor public static var preferred: TerminalApp {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey), let app = TerminalApp(rawValue: raw) { return app }
        return TerminalApp.iterm.isInstalled ? .iterm : .terminal
    }
}
