import AppKit
import SessionBarCore
import SwiftUI

enum Level {
    static func color(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 75 ? .orange : .accentColor }
}

struct Ring: View {
    let percent: Double
    var size: CGFloat = 44
    var line: CGFloat = 5
    var tint: Color?

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: line)
            Circle()
                .trim(from: 0, to: percent / 100)
                .stroke(tint ?? Level.color(percent), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: size * 0.24, weight: .semibold))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(Int(percent.rounded())) percent used")
    }
}

struct UsageTile: View {
    let window: LimitWindow
    var size: CGFloat = 44
    var forecast: Forecast = .unknown

    var body: some View {
        let pct = window.percent()
        HStack(spacing: 10) {
            Ring(percent: pct, size: size, line: size / 8.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.label).font(.system(size: 13, weight: .semibold))
                Text(Fmt.resets(window.resetsAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                if let f = Fmt.forecast(forecast) {
                    Text(f).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        .foregroundStyle(forecast == .safeUntilReset ? Color.secondary : Color.orange)
                }
            }
        }
    }
}

/// The menu bar picture: a small ring drawn into an image (menu bar labels only take Image + Text).
enum MenuBarRing {
    static func image(percent: Double?, weekly: Bool = false, alert: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { full in
            let rect = NSRect(x: 0, y: 0, width: 16, height: 16)
            if alert {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: full.maxX - 6, y: full.maxY - 6, width: 6, height: 6)).fill()
            }
            let r = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = 2.5
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
            track.stroke()
            guard let percent, percent > 0 else { return true }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: r.width / 2, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(percent, 100) / 100), clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            (percent >= 75 || !weekly ? NSColor(Level.color(percent)) : NSColor.systemTeal).setStroke()
            arc.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }
}
