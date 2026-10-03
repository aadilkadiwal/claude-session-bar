import AppKit
import SessionBarCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirm: Confirm?
    @State private var showingNew = false
    @State private var search = ""
    @State private var collapsed = Set<String>()

    enum Confirm: Equatable {
        case stop(LiveSession), openWithPhone(LiveSession), delete(HistorySession)
        case renameLive(LiveSession), renameClosed(HistorySession)
        var sessionId: String {
            switch self {
            case .stop(let s), .openWithPhone(let s), .renameLive(let s): return s.sessionId
            case .delete(let h), .renameClosed(let h): return h.sessionId
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BannerView(model: model)
            usage
            Divider().padding(.vertical, 6)
            if showingNew {
                NewSessionPanel(model: model, isShown: $showingNew)
            } else {
                sessions
            }
            Divider().padding(.vertical, 6)
            footer
        }
        .padding(8)
        .frame(width: 370)
        .onAppear { model.menuOpen = true }
        .onDisappear { model.menuOpen = false; search = "" }
    }

    @ViewBuilder private var usage: some View {
        if let u = model.usage {
            HStack(spacing: 12) {
                if let w = u.fiveHour { UsageTile(window: w, forecast: model.forecast(w)).frame(maxWidth: .infinity, alignment: .leading) }
                if let w = u.weekly { UsageTile(window: w, forecast: model.forecast(w)).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(6)
            .contentShape(Rectangle())
            .onTapGesture { showDetails(tab: .usage) }
            HStack {
                Text(u.model ?? "")
                Spacer()
                Text("updated \(Fmt.ago(u.updatedAt))")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage limits").font(.system(size: 13, weight: .semibold))
                Text("They appear after your next Claude Code message. Claude Code sends them to the status line, and Session Bar reads them from there.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }
    }

    private func matches(_ text: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.contains { $0.lowercased().contains(q) }
    }

    private var sessions: some View {
        let running = model.live.filter { matches(model.displayName($0), $0.cwd, $0.sessionId) }
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        // Searching looks through all saved sessions; otherwise show the last five.
        let closed = searching ? Array(model.closed.filter { matches($0.name, $0.cwd, $0.sessionId, $0.lastPrompt ?? "") }.prefix(15))
                               : Array(model.closed.prefix(5))
        return VStack(alignment: .leading, spacing: 4) {
            TextField("Search sessions", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: "RUNNING NOW · \(running.count)", trailing: "newest first")
                    if running.isEmpty {
                        Text(searching ? "No running session matches." : "No Claude Code sessions running.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                    }
                    if running.count > 5 && !searching {
                        ForEach(ProjectGroups.group(running), id: \.name) { g in groupView(g) }
                    } else {
                        ForEach(running) { s in liveRow(s) }
                    }

                    if !closed.isEmpty {
                        SectionHeader(title: searching ? "CLOSED · MATCHES" : "RECENT · CLOSED").padding(.top, 6)
                        ForEach(closed) { h in closedRowWithConfirm(h) }
                    } else if searching {
                        Text("No closed session matches.").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func groupView(_ g: ProjectGroups.Group) -> some View {
        let open = !collapsed.contains(g.name)
        Button {
            if open { collapsed.insert(g.name) } else { collapsed.remove(g.name) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Text(g.name).font(.system(size: 12, weight: .semibold))
                if g.sessions.contains(where: { $0.state == .blocked }) { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                Spacer()
                Text("\(g.sessions.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open { ForEach(g.sessions) { s in liveRow(s).padding(.leading, 12) } }
    }

    @ViewBuilder private func liveRow(_ s: LiveSession) -> some View {
        let busy = model.working.contains(s.sessionId)
        VStack(spacing: 4) {
            HoverRow {
                StateDot(state: s.isLeftover ? nil : s.state)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(model.displayName(s)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if s.kind == .background { Pill(text: "BG") }
                    }
                    Text("\(Fmt.shortPath(s.cwd)) · \(stateText(s))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    IconButton(symbol: "iphone", on: s.isOnPhone, help: model.typingBlockers[s.sessionId] ?? phoneHelp(s),
                               dimmed: model.typingBlockers[s.sessionId] != nil) {
                        switch (s.isOnPhone, s.kind) {
                        case (false, .interactive): model.phoneOn(s)    // keeps running here too
                        case (true, .interactive): model.phoneOff(s)    // keeps running here
                        case (false, .background): confirm = .openWithPhone(s)
                        case (true, .background): confirm = .stop(s)    // phone is its only window
                        }
                    }
                    IconButton(symbol: s.isLeftover ? "xmark" : "stop.fill",
                               help: s.isLeftover ? "Clear this leftover entry (history is kept)" : "Stop session") {
                        if s.state == .idle && !s.isLeftover { model.stop(s) } else { confirm = .stop(s) }
                    }
                }
            } action: { model.open(s) }
            .contextMenu {
                Button("Rename…") { confirm = .renameLive(s) }
                    .disabled(s.kind == .background || model.typingBlockers[s.sessionId] != nil)
                Button(s.kind == .interactive ? "Show its window" : "Open in \(model.terminalApp.title)") { model.open(s) }
                if let url = s.phoneURL { Button("Copy phone link") { copy(url.absoluteString) } }
                Button("Copy session ID") { copy(s.sessionId) }
            }

            if let c = confirm, c.sessionId == s.sessionId { confirmBar(c) }
        }
    }

    private func closedRow(_ h: HistorySession) -> some View {
        HoverRow {
            StateDot(state: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(model.duplicateNames.contains(h.name) && h.lastPrompt?.isEmpty == false
                     ? "“\(h.lastPrompt ?? "")” · \(Fmt.folderName(h.cwd))" : Fmt.shortPath(h.cwd))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Fmt.ago(h.lastActive)).font(.system(size: 11)).foregroundStyle(.secondary)
            IconButton(symbol: "terminal", help: "Resume in \(model.terminalApp.title)") { model.resumeInTerminal(h) }
            IconButton(symbol: "trash", help: "Delete session") { confirm = .delete(h) }
        } action: { model.resumeInTerminal(h) }
        .contextMenu {
            Button("Rename…") { confirm = .renameClosed(h) }
            Button("Resume in \(model.terminalApp.title)") { model.resumeInTerminal(h) }
            Button("Copy session ID") { copy(h.sessionId) }
        }
    }

    @ViewBuilder private func closedRowWithConfirm(_ h: HistorySession) -> some View {
        VStack(spacing: 4) {
            closedRow(h)
            if let c = confirm, c.sessionId == h.sessionId { confirmBar(c) }
        }
    }

    private func phoneHelp(_ s: LiveSession) -> String {
        switch (s.isOnPhone, s.kind) {
        case (false, .interactive): return "Also open on your phone (keeps running here)"
        case (true, .interactive): return "On your phone. Click to disconnect the phone; it keeps running here."
        case (false, .background): return s.isLeftover ? "Reopen it in \(model.terminalApp.title) and on your phone"
                                                       : "Open in \(model.terminalApp.title) and on your phone"
        case (true, .background): return "On your phone only. Click to stop it."
        }
    }

    private func confirmBar(_ c: Confirm) -> some View {
        HStack(spacing: 8) {
            switch c {
            case .stop(let s):
                Text(s.isLeftover ? "It isn't running, it's a leftover entry. Clear it? Its history stays."
                     : s.state == .blocked ? "It's waiting for an answer. Stop it?"
                     : s.kind == .background && s.isOnPhone ? "It runs only on your phone. Stop it?"
                     : s.isOnPhone ? "Stop it? It also leaves your phone." : "Stop this session?")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { confirm = nil }
                Button(s.isLeftover ? "Clear" : "Stop") { confirm = nil; model.stop(s) }.keyboardShortcut(.defaultAction)
            case .openWithPhone(let s):
                Text("It has no window. Open it in \(model.terminalApp.title) with phone access on?").fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { confirm = nil }
                Button("Open") { confirm = nil; model.phoneOn(s) }.keyboardShortcut(.defaultAction)
            case .renameLive(let s):
                RenameField(initial: model.displayName(s)) { name in confirm = nil; if let name { model.rename(s, to: name) } }
            case .renameClosed(let h):
                RenameField(initial: h.name) { name in confirm = nil; if let name { model.rename(h, to: name) } }
            case .delete(let h):
                Text("Move this session to the Trash?").fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { confirm = nil }
                Button("Delete", role: .destructive) { confirm = nil; model.delete([h]) }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.1)))
    }

    private func stateText(_ s: LiveSession) -> String {
        if s.isLeftover { return "not running · leftover" }
        switch s.state {
        case .busy: return "working"
        case .idle: return "idle"
        case .blocked: return "waiting for you"
        }
    }

    private var footer: some View {
        HStack {
            Button { showingNew.toggle() } label: { Label(showingNew ? "Back" : "New session…", systemImage: showingNew ? "chevron.left" : "plus") }
            Spacer()
            Button("View details…") { showDetails(tab: .sessions) }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { Task { await model.refresh(history: true) } }
            IconButton(symbol: "power", help: "Quit Session Bar") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
    }

    private func showDetails(tab: DetailsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "detailsTab")
        openWindow(id: "details")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct NewSessionPanel: View {
    @ObservedObject var model: AppModel
    @Binding var isShown: Bool
    @State private var folder: String?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New session").font(.system(size: 13, weight: .semibold))
            Text("FOLDER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            FlowChips(items: model.recentFolders, selected: $folder)
            Button("Browse…") { browse() }.controlSize(.small)
            if let folder { Text(Fmt.shortPath(folder)).font(.system(size: 11)).foregroundStyle(.secondary) }
            Text("NAME (optional)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("e.g. fix-login", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button { start(phone: false) } label: { Label("Open in \(model.terminalApp.title)", systemImage: "terminal") }
                Button { start(phone: true) } label: { Label("Start for phone", systemImage: "iphone") }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(folder == nil || model.working.contains("new"))
            Text("Start for phone opens no window. The session shows up in the Claude app within a few seconds.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .onAppear { folder = folder ?? model.recentFolders.first }
    }

    private func start(phone: Bool) {
        guard let folder else { return }
        if phone { model.newOnPhone(folder: folder, name: name) } else { model.newInTerminal(folder: folder, name: name) }
        isShown = false
        name = ""
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

struct FlowChips: View {
    let items: [String]
    @Binding var selected: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { f in
                Button { selected = f } label: {
                    Text(Fmt.folderName(f)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(selected == f ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
                        .overlay(Capsule().stroke(selected == f ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
                .help(f)
            }
        }
    }
}

struct BannerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let b = model.banner {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(b.isError ? .orange : .green)
                Text(b.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let title = b.actionTitle, let action = b.action {
                    Button(title) { model.banner = nil; action() }.controlSize(.small)
                }
                Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill((b.isError ? Color.orange : Color.green).opacity(0.12)))
            .padding(.bottom, 6)
            .task(id: b.id) {
                guard !b.isError else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if model.banner?.id == b.id { model.banner = nil }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

struct StateDot: View {
    let state: LiveSession.State?
    var body: some View {
        Group {
            switch state {
            case .busy: Circle().fill(Color.green)
            case .idle: Circle().strokeBorder(Color.green, lineWidth: 1.5)
            case .blocked: Circle().fill(Color.orange)
            case nil: Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: 9, height: 9)
        .help(state.map { $0 == .busy ? "Working" : $0 == .idle ? "Idle" : "Waiting for you" } ?? "Closed")
    }
}

struct Pill: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
    }
}

struct IconButton: View {
    let symbol: String
    var on = false
    let help: String
    var dimmed = false
    let action: () -> Void
    var body: some View {
        Button(action: { if !dimmed { action() } }) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 26, height: 22)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.borderless)
        .opacity(dimmed ? 0.35 : 1)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct RenameField: View {
    let initial: String
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { save() }
            .onAppear { text = initial; focused = true }
        Button("Cancel") { done(nil) }
        Button("Save") { save() }.keyboardShortcut(.defaultAction)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        done(t == initial ? nil : t)
    }
}

struct HoverRow<Content: View>: View {
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}
