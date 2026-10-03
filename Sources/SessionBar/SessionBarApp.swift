import SessionBarCore
import SwiftUI

@main
struct SessionBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            BarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Session Bar", id: "details") {
            DetailsView(model: model)
        }
        .defaultSize(width: 980, height: 640)
    }
}

struct BarLabel: View {
    @ObservedObject var model: AppModel
    @AppStorage("barStyle") private var barStyle = BarStyle.closest.rawValue

    var body: some View {
        let five = model.usage?.fiveHour?.percent()
        let week = model.usage?.weekly?.percent()
        let pct = { (p: Double?) in p.map { "\(Int($0.rounded()))%" } ?? "–" }
        let style = BarStyle(rawValue: barStyle) ?? .closest
        let weeklyCloser = style == .closest && (week ?? 0) > (five ?? 0)
        HStack(spacing: 4) {
            Image(nsImage: MenuBarRing.image(percent: weeklyCloser ? week : five, weekly: weeklyCloser, alert: model.needsYou))
            switch style {
            case .closest: Text(weeklyCloser ? "W \(pct(week)) · \(model.live.count)" : "\(pct(five)) · \(model.live.count)")
            case .percentAndCount: Text("\(pct(five)) · \(model.live.count)")
            case .bothLimits: Text("\(pct(five)) / \(pct(week))")
            case .ringOnly: EmptyView()
            }
        }
    }
}
