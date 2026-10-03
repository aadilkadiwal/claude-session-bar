import Foundation
import SessionBarCore
import UserNotifications

/// macOS notifications: a session needs you, a long task finished, a usage limit is getting close.
/// Each kind can be switched off in Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Key {
        static let waiting = "notifyWaiting", finished = "notifyFinished", limits = "notifyLimits"
        static let fired = "firedLimitWarnings"
    }
    static let thresholds: [Double] = [80, 95]
    /// A reply shorter than this isn't worth a "finished" notification.
    static let longTask: TimeInterval = 60

    var onOpen: ((String) -> Void)?
    private var busySince: [String: Date] = [:]
    private var asked = false

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Key.waiting: true, Key.finished: true, Key.limits: true])
        UNUserNotificationCenter.current().delegate = self
    }

    private func enabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    func sessionsChanged(from old: [LiveSession], to new: [LiveSession], name: (LiveSession) -> String) {
        let before = Dictionary(old.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        for s in new where !s.isLeftover {
            let prev = before[s.sessionId]
            if s.state == .busy, prev?.state != .busy { busySince[s.sessionId] = now }
            if s.state == .blocked, prev != nil, prev?.state != .blocked, enabled(Key.waiting) {
                post(id: "wait-\(s.sessionId)", title: name(s), body: Self.waitingText(s.waitingFor), sessionId: s.sessionId)
            }
            if s.state == .idle, prev?.state == .busy, let start = busySince[s.sessionId],
               now.timeIntervalSince(start) >= Self.longTask, enabled(Key.finished) {
                post(id: "done-\(s.sessionId)", title: name(s), body: "Finished · took \(Fmt.duration(now.timeIntervalSince(start)))", sessionId: s.sessionId)
            }
            if s.state != .busy { busySince[s.sessionId] = nil }
        }
    }

    static func waitingText(_ waitingFor: String?) -> String {
        guard let w = waitingFor, !w.isEmpty, w != "input needed" else { return "is waiting for your answer" }
        return "is waiting: \(w)"
    }

    /// One warning per threshold per window period (the reset time identifies the period).
    func usageChanged(_ u: UsageSnapshot, forecast: (LimitWindow) -> Forecast) {
        guard enabled(Key.limits) else { return }
        var fired = Set(UserDefaults.standard.stringArray(forKey: Key.fired) ?? [])
        for w in [u.fiveHour, u.weekly].compactMap({ $0 }) {
            let pct = w.percent()
            guard let t = Self.thresholds.last(where: { pct >= $0 }) else { continue }
            let key = "\(w.key)-\(Int(t))-\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
            guard fired.insert(key).inserted else { continue }
            var body = Fmt.resets(w.resetsAt).capitalized
            if case .reachesLimit(let at) = forecast(w) { body += " · at this pace you'll reach 100% at \(Fmt.clock(at))" }
            post(id: key, title: "\(w.label) limit at \(Int(pct.rounded()))%", body: body, sessionId: nil)
        }
        UserDefaults.standard.set(Array(fired.suffix(40)), forKey: Key.fired)
    }

    private func post(id: String, title: String, body: String, sessionId: String?) {
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let sessionId { content.userInfo = ["sessionId": sessionId] }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionId"] as? String
        Task { @MainActor in
            if let id { self.onOpen?(id) }
            completionHandler()
        }
    }
}
