import AppKit
import CoreImage
import SessionBarCore
import SwiftUI

enum DetailsTab: String { case sessions, usage, settings }

struct DetailsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("detailsTab") private var tab = DetailsTab.sessions.rawValue

    var body: some View {
        VStack(spacing: 0) {
            BannerView(model: model).padding([.horizontal, .top], 12)
            TabView(selection: $tab) {
                SessionsTab(model: model).tabItem { Text("Sessions") }.tag(DetailsTab.sessions.rawValue)
                UsageTab(model: model).tabItem { Text("Usage") }.tag(DetailsTab.usage.rawValue)
                SettingsTab(model: model).tabItem { Text("Settings") }.tag(DetailsTab.settings.rawValue)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { model.detailsOpen = true; Task { await model.refresh(history: true, agents: true) } }
        .onDisappear { model.detailsOpen = false }
    }
}

/// One line in the table: a running session, a saved one, or both (running sessions are saved too).
struct SessionRow: Identifiable {
    let id: String
    let live: LiveSession?
    let saved: HistorySession?
    var liveName: String?

    var name: String { liveName ?? saved?.name ?? id }
    var folder: String { live?.cwd ?? saved?.cwd ?? "" }
    var shortId: String { String(id.prefix(8)) }
    var lastActive: Date { saved?.lastActive ?? live?.startedAt ?? .distantPast }
    var bytes: Int64 { saved?.bytes ?? 0 }
    var model: String { Fmt.model(saved?.model) }
    var isClosed: Bool { live == nil }
    var status: String {
        guard let s = live else { return "Closed" }
        if s.isLeftover { return "Leftover" }
        switch s.state { case .busy: return "Working"; case .idle: return "Idle"; case .blocked: return "Waiting" }
    }
}

enum SessionFilter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", phone = "On phone", background = "Background", closed = "Closed"
    var id: String { rawValue }
    func matches(_ r: SessionRow) -> Bool {
        switch self {
        case .all: return true
        case .running: return r.live != nil
        case .phone: return r.live?.isOnPhone == true
        case .background: return r.live?.kind == .background
        case .closed: return r.isClosed
        }
    }
}

struct SessionsTab: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var filter = SessionFilter.all
    @State private var range = ActiveRange.any
    @State private var selection = Set<String>()
    @State private var checked = Set<String>()
    @State private var pendingDelete: [HistorySession]?
    @State private var renaming: SessionRow?
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActive, order: .reverse)]

    private var allRows: [SessionRow] {
        let saved = Dictionary(model.history.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let live = model.live.map { SessionRow(id: $0.sessionId, live: $0, saved: saved[$0.sessionId], liveName: model.displayName($0)) }
        let closed = model.closed.map { SessionRow(id: $0.sessionId, live: nil, saved: $0) }
        return live + closed
    }

    private var rows: [SessionRow] {
        let q = search.lowercased()
        let sorted = allRows
            .filter { filter.matches($0) && range.matches($0.lastActive) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.folder.lowercased().contains(q) || $0.id.hasPrefix(q) }
            .sorted(using: sortOrder)
        // Running sessions stay on top whatever the column sort.
        return sorted.filter { $0.live != nil } + sorted.filter { $0.live == nil }
    }

    private var visibleClosed: [HistorySession] { rows.filter(\.isClosed).compactMap(\.saved) }
    private var checkedSessions: [HistorySession] { model.closed.filter { checked.contains($0.sessionId) } }

    private var allVisibleChecked: Binding<Bool> {
        Binding(
            get: { !visibleClosed.isEmpty && visibleClosed.allSatisfy { checked.contains($0.sessionId) } },
            set: { on in
                let ids = Set(visibleClosed.map(\.sessionId))
                if on { checked.formUnion(ids) } else { checked.subtract(ids) }
            })
    }

    private func isChecked(_ id: String) -> Binding<Bool> {
        Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search name, folder or session ID", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("", selection: $filter) {
                    ForEach(SessionFilter.allCases) { f in Text("\(f.rawValue) \(allRows.filter(f.matches).count)").tag(f) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack(spacing: 14) {
                Toggle("Select all closed (\(visibleClosed.count))", isOn: allVisibleChecked)
                    .toggleStyle(.checkbox)
                    .disabled(visibleClosed.isEmpty)
                let empty = model.emptySessions
                if !empty.isEmpty {
                    Button { pendingDelete = empty } label: {
                        Label("\(empty.count) empty session\(empty.count == 1 ? "" : "s") · \(Fmt.bytes(empty.reduce(0) { $0 + $1.bytes })) · Clean up", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                    .help("Sessions you opened and closed without a reply from Claude")
                }
                Spacer()
                Picker("Last active", selection: $range) {
                    ForEach(ActiveRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            .font(.system(size: 12))

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { r in
                    if r.isClosed {
                        Toggle("", isOn: isChecked(r.id)).toggleStyle(.checkbox).labelsHidden()
                    }
                }.width(22)
                TableColumn("Status") { r in
                    HStack(spacing: 6) { StateDot(state: r.live?.isLeftover == true ? nil : r.live?.state); Text(r.status) }
                }.width(min: 80, ideal: 90)
                TableColumn("Name", value: \.name) { r in
                    HStack(spacing: 4) {
                        Text(r.name).lineLimit(1).help(r.saved?.lastPrompt.map { "Last prompt: \($0)" } ?? r.name)
                        if r.live?.isOnPhone == true { Image(systemName: "iphone").foregroundStyle(Color.accentColor).help("On your phone") }
                        if r.live?.kind == .background { Pill(text: "BG") }
                    }
                }.width(min: 150, ideal: 200)
                TableColumn("Folder", value: \.folder) { r in Text(Fmt.shortPath(r.folder)).lineLimit(1).help(r.folder) }
                    .width(min: 110, ideal: 160)
                TableColumn("Session ID") { r in Text(r.shortId).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                    .width(80)
                TableColumn("Model") { r in Text(r.model) }.width(min: 70, ideal: 80)
                TableColumn("Last active", value: \.lastActive) { r in Text(Fmt.ago(r.lastActive)) }.width(min: 80, ideal: 90)
                TableColumn("Size", value: \.bytes) { r in Text(Fmt.bytes(r.bytes)).monospacedDigit() }.width(64)
                TableColumn("") { r in
                    if r.isClosed, let h = r.saved {
                        Button { pendingDelete = [h] } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Delete this session")
                    }
                }.width(28)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let r = allRows.first(where: { ids.first == $0.id }) { actions(for: r) }
            } primaryAction: { ids in
                if let r = allRows.first(where: { ids.first == $0.id }) { open(r) }
            }

            if let r = renaming {
                HStack(spacing: 8) {
                    Text("Rename \(r.name):").lineLimit(1)
                    RenameField(initial: r.name) { name in
                        renaming = nil
                        guard let name else { return }
                        if let s = r.live { model.rename(s, to: name) } else if let h = r.saved { model.rename(h, to: name) }
                    }
                }
                .font(.system(size: 12)).controlSize(.small)
            } else if selection.count == 1, let r = allRows.first(where: { selection.contains($0.id) }) {
                Inspector(row: r) { actions(for: r) }
            }

            bottomBar.font(.system(size: 12))
        }
        // Forget ticks for sessions that no longer exist (deleted here or by Claude Code's cleanup).
        .onChange(of: model.history.count) { checked.formIntersection(Set(model.closed.map(\.sessionId))) }
    }

    @ViewBuilder private var bottomBar: some View {
        HStack {
            if let pending = pendingDelete {
                Text("Move \(pending.count) session\(pending.count == 1 ? "" : "s") (\(Fmt.bytes(pending.reduce(0) { $0 + $1.bytes }))) to the Trash?")
                Spacer()
                Button("Cancel") { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    model.delete(pending)
                    checked.subtract(pending.map(\.sessionId))
                    pendingDelete = nil
                }.keyboardShortcut(.defaultAction)
            } else {
                let picked = checkedSessions
                Text(picked.isEmpty ? "\(rows.count) sessions · tick closed ones to delete several at once · double-click to open"
                     : "\(picked.count) checked · \(Fmt.bytes(picked.reduce(0) { $0 + $1.bytes }))")
                    .foregroundStyle(.secondary)
                Spacer()
                if !picked.isEmpty { Button("Clear") { checked.removeAll() } }
                Button("Delete checked…", role: .destructive) { pendingDelete = picked }
                    .disabled(picked.isEmpty)
                    .help("Moves the files to the Trash. Running sessions can't be ticked.")
            }
        }
    }

    @ViewBuilder private func actions(for r: SessionRow) -> some View {
        Button("Rename…") { renaming = r }
            .disabled(r.live.map { $0.kind == .background || model.typingBlockers[$0.sessionId] != nil } ?? false)
        if let s = r.live {
            Button(s.kind == .interactive ? "Show its window" : "Open in \(model.terminalApp.title)") { model.open(s) }
            if s.isOnPhone, s.kind == .interactive { Button("Disconnect phone (keep running)") { model.phoneOff(s) } }
            if !s.isOnPhone { Button(s.kind == .interactive ? "Also open on phone" : "Open in \(model.terminalApp.title) + phone") { model.phoneOn(s) } }
            if let url = s.phoneURL {
                Button("Copy phone link") { copy(url.absoluteString) }
                Button("Open on claude.ai") { NSWorkspace.shared.open(url) }
            }
            Button(s.isLeftover ? "Clear leftover entry" : "Stop") { model.stop(s) }
        } else if let h = r.saved {
            Button("Resume in \(model.terminalApp.title)") { model.resumeInTerminal(h) }
            Button("Delete…", role: .destructive) { pendingDelete = [h] }
            Button("Show file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([h.fileURL]) }
        }
        Button("Copy session ID") { copy(r.id) }
    }

    private func open(_ r: SessionRow) {
        if let s = r.live { model.open(s) } else if let h = r.saved { model.resumeInTerminal(h) }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct Inspector<Actions: View>: View {
    let row: SessionRow
    @ViewBuilder let actions: Actions
    @State private var detail: SessionDetail?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let d = detail {
                    GridRow { Text("Activity").foregroundStyle(.secondary)
                        Text([d.prompts > 0 ? "\(d.prompts) prompt\(d.prompts == 1 ? "" : "s")" : "no prompts",
                              d.duration.map { "ran \(Fmt.duration($0))" },
                              d.tokens > 0 ? "\(Fmt.tokens(d.tokens)) tokens" : nil].compactMap { $0 }.joined(separator: " · ")) }
                }
                GridRow { Text("Session ID").foregroundStyle(.secondary)
                    HStack { Text(row.id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button { copy(row.id) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy") } }
                GridRow { Text("Folder").foregroundStyle(.secondary); Text(row.folder).textSelection(.enabled) }
                if let p = row.saved?.lastPrompt {
                    GridRow { Text("Last prompt").foregroundStyle(.secondary); Text(p).lineLimit(2).textSelection(.enabled) }
                }
                if let reply = detail?.lastReply {
                    GridRow { Text("Last reply").foregroundStyle(.secondary); Text(reply).lineLimit(3).textSelection(.enabled) }
                }
                if let s = row.live {
                    GridRow { Text("Running").foregroundStyle(.secondary)
                        Text("\(s.kind == .background ? "In the background" : "In a terminal") since \(Fmt.ago(s.startedAt))\(s.isOnPhone ? " · on your phone" : "")") }
                }
            }
            Spacer()
            if let url = row.live?.phoneURL, let qr = QRCode.image(url.absoluteString) {
                VStack(spacing: 2) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 84, height: 84)
                    Text("Scan to open").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .trailing) { actions }.buttonStyle(.bordered).controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .task(id: row.id) {
            detail = nil
            guard let url = row.saved?.fileURL else { return }
            detail = await Task.detached { SessionDetail.load(url) }.value
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

struct UsageTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let u = model.usage {
                    HStack(alignment: .top, spacing: 36) {
                        ForEach(u.windows) { w in
                            VStack(spacing: 6) {
                                Ring(percent: w.percent(), size: 96, line: 10)
                                Text(w.label).font(.system(size: 13, weight: .semibold))
                                Text(Fmt.resets(w.resetsAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                                if let f = Fmt.forecast(model.forecast(w)) {
                                    Text(f).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center)
                                        .foregroundStyle(model.forecast(w) == .safeUntilReset ? Color.secondary : Color.orange)
                                }
                            }
                            .frame(width: 150)
                        }
                    }
                    Text("Updated \(Fmt.ago(u.updatedAt))\(u.model.map { " · \($0)" } ?? ""). These are the same numbers /usage shows. They refresh whenever any Claude Code session is active.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("The pace line compares your usage over the last hour (5-hour limit) or day (weekly) and appears once there are 10 minutes of readings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text("No usage numbers yet. Send a message in any Claude Code session and they'll appear here. If they still don't, re-run the installer so the status line hook is set up.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @AppStorage("barStyle") private var barStyle = BarStyle.closest.rawValue
    @AppStorage(Notifier.Key.waiting) private var notifyWaiting = true
    @AppStorage(Notifier.Key.finished) private var notifyFinished = true
    @AppStorage(Notifier.Key.limits) private var notifyLimits = true
    @StateObject private var updater = Updater()
    @State private var cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var confirmCleanup = false

    private var old: [HistorySession] { model.closed.filter { $0.lastActive < cutoff } }

    var body: some View {
        Form {
            Section {
                Picker("Keep session history for", selection: Binding(get: { model.retentionDays }, set: { model.setRetention($0) })) {
                    ForEach(Retention.choices(current: model.retentionDays), id: \.self) { d in
                        Text(Retention.label(d)).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                Text("Claude Code deletes saved sessions older than this on its own (setting: cleanupPeriodDays). 30 days is the most Session Bar offers.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("History") }

            Section {
                DatePicker("Delete closed sessions last used before", selection: $cutoff, displayedComponents: .date)
                HStack {
                    Text("\(old.count) session\(old.count == 1 ? "" : "s") · \(Fmt.bytes(old.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                    Spacer()
                    if confirmCleanup {
                        Text("Move them to the Trash?")
                        Button("Cancel") { confirmCleanup = false }
                        Button("Delete", role: .destructive) { model.delete(old); confirmCleanup = false }
                    } else {
                        Button("Clean up…", role: .destructive) { confirmCleanup = true }.disabled(old.isEmpty)
                    }
                }
            } header: { Text("Clean up now") } footer: {
                Text("This frees space on your Mac. Sessions listed on claude.ai or in the phone app are kept on Anthropic's servers and aren't affected.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Toggle("A session is waiting for your answer", isOn: $notifyWaiting)
                Toggle("A session finishes a task that took over a minute", isOn: $notifyFinished)
                Toggle("A usage limit passes 80% and 95%", isOn: $notifyLimits)
            } header: { Text("Notify me when") } footer: {
                Text("If your notch app already announces sessions, switch the first two off here to avoid double alerts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Picker("Menu bar shows", selection: $barStyle) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Open sessions in", selection: $model.terminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.isInstalled ? app.title : "\(app.title) (not installed)").tag(app).disabled(!app.isInstalled)
                    }
                }
                Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            } header: { Text("App") }

            Section {
                LabeledContent("Usage snapshot", value: FileManager.default.fileExists(atPath: model.paths.statusFile.path)
                               ? "received \(model.usage.map { Fmt.ago($0.updatedAt) } ?? "—")" : "not received yet")
                LabeledContent("claude command", value: model.cli?.executable.path ?? "not found")
            } header: { Text("Status") }

            Section {
                HStack {
                    Text(updater.status)
                    Spacer()
                    if updater.updatesAvailable > 0 {
                        Button("Update now") { updater.update() }.buttonStyle(.borderedProminent).disabled(updater.busy)
                    } else {
                        Button("Check for updates") { updater.check() }.disabled(updater.busy)
                    }
                }
            } header: { Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")") }
        }
        .formStyle(.grouped)
        .onAppear { updater.check() }
    }
}

enum Retention {
    static let presets = [7, 14, 30]
    static func choices(current: Int) -> [Int] { presets.contains(current) || current > 30 ? presets : (presets + [current]).sorted() }
    static func label(_ d: Int) -> String { d == 7 ? "1 week" : d == 14 ? "2 weeks" : "\(d) days" }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case closest, percentAndCount, bothLimits, ringOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .closest: return "Closest limit · running sessions"
        case .percentAndCount: return "5-hour % · running sessions"
        case .bothLimits: return "5-hour % / weekly %"
        case .ringOnly: return "Ring only"
        }
    }
}
