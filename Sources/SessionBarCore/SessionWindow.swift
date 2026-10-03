import AppKit
import Foundation

/// The iTerm tab a running session lives in, found by its tty. Lets Session Bar type a command into
/// that exact session, the same as if you typed it, and read what's on screen.
public struct SessionWindow: Sendable {
    public static let itermBundleId = "com.googlecode.iterm2"
    public let tty: String  // e.g. /dev/ttys012

    public enum Failure: LocalizedError, Equatable {
        case unsupportedHost, notFound, notAllowed, script(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedHost:
                return "This session isn't running in iTerm, so Session Bar can't type into it. Type the command in it yourself."
            case .notFound: return "Couldn't find this session's window."
            case .notAllowed:
                return "Session Bar isn't allowed to control iTerm. Turn it on in System Settings → Privacy & Security → Automation."
            case .script(let msg): return msg
            }
        }
    }

    @MainActor
    public static func find(pid: Int32) throws -> SessionWindow {
        guard let tty = tty(of: pid) else { throw Failure.notFound }
        guard ClaudeCLI.owningApp(pid: pid)?.bundleIdentifier == itermBundleId else { throw Failure.unsupportedHost }
        return SessionWindow(tty: tty)
    }

    static func tty(of pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    @MainActor public func type(_ text: String, enter: Bool = true) throws {
        try run(match: "tell s to write text \"\(esc(text))\" newline \(enter ? "YES" : "NO")")
    }

    @MainActor public func erase(_ count: Int) throws {
        guard count > 0 else { return }
        try run(match: "tell s to write text (\(Array(repeating: "(ASCII character 127)", count: count).joined(separator: " & "))) newline NO")
    }

    /// Up arrow `count` times, then Return: picks a menu item above the default one.
    @MainActor public func chooseAbove(_ count: Int) throws {
        let ups = Array(repeating: "esc & \"[A\"", count: count).joined(separator: " & ")
        try run(match: """
        set esc to ASCII character 27
        tell s to write text (\(ups)) newline NO
        delay 0.4
        tell s to write text "" newline YES
        """)
    }

    @MainActor public func screen() throws -> String { try run(match: "return contents of s") }

    @MainActor public func focus() throws { try run(match: "activate\ntell w to select\ntell t to select\ntell s to select") }

    /// Text on the prompt line (`❯ text`). nil if no prompt is visible. May be a grey suggestion.
    public static func draft(in screen: String) -> String? {
        guard let line = screen.split(separator: "\n").last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }) else { return nil }
        return line.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    @MainActor private func run(match body: String) throws -> String {
        let source = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(esc(tty))" then
                            \(body)
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "__notfound__"
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { throw Failure.notAllowed }
            throw Failure.script(error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed")
        }
        let out = result?.stringValue ?? ""
        if out == "__notfound__" { throw Failure.notFound }
        return out
    }

    private func esc(_ s: String) -> String { ClaudeCLI.appleScriptEscape(s) }
}
