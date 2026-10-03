import Foundation
import SessionBarCore

/// Checks the source checkout the installer built from (path saved in ~/.claude/session-bar/source-path)
/// for new commits on its remote, and updates by pulling them and re-running the installer.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var status = "Checking…"
    @Published private(set) var updatesAvailable = 0
    @Published private(set) var busy = false

    private var source: String? {
        (try? String(contentsOf: ClaudePaths().appDir.appendingPathComponent("source-path"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func check() {
        guard let src = source, FileManager.default.fileExists(atPath: src + "/.git") else {
            status = "Installed from a folder without git; re-run install.sh to update."
            return
        }
        busy = true
        Task {
            defer { busy = false }
            guard (try? await Self.git(src, "rev-parse", "--abbrev-ref", "@{u}")) != nil else {
                status = "Up to date with your local copy (not published to GitHub yet)."
                return
            }
            _ = try? await Self.git(src, "fetch", "--quiet")
            let count = Int((try? await Self.git(src, "rev-list", "--count", "HEAD..@{u}")) ?? "0") ?? 0
            updatesAvailable = count
            status = count == 0 ? "Up to date." : "Update available: \(count) new change\(count == 1 ? "" : "s")."
        }
    }

    /// The installer quits and reopens the app, so this is the last thing it does.
    func update() {
        guard let src = source else { return }
        busy = true
        status = "Updating… Session Bar will restart."
        Task {
            do {
                _ = try await Self.git(src, "pull", "--ff-only", "--quiet")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [src + "/install.sh"]
                p.currentDirectoryURL = URL(fileURLWithPath: src)
                try p.run()
            } catch {
                status = "Update failed: \(error.localizedDescription)"
                busy = false
            }
        }
    }

    private static func git(_ dir: String, _ args: String...) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(p.terminationStatus)) }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
