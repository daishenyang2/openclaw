import AppKit
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette

enum CoworkPalette {
    static let background = Color(nsColor: NSColor.textBackgroundColor)
    static let surface = Color.primary.opacity(0.03)
    static let surfaceElevated = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.08)
    static let accent = Color.accentColor
    static let working = Color.orange
    static let success = Color.green
    static let muted = Color.secondary
    /// Warm peach tint for user chat bubbles; keeps contrast in both light
    /// and dark mode while avoiding the heavy accent-color fill.
    static let userBubble = Color(red: 0.99, green: 0.91, blue: 0.82).opacity(0.55)
}

// MARK: - Focus

@MainActor
@Observable
final class CoworkWindowFocus {
    var searchFocusTick: Int = 0
    var requestNewTask: Int = 0
}

// MARK: - Tab state

@MainActor
@Observable
final class CoworkTabBook {
    struct OpenTab: Identifiable, Hashable {
        let id = UUID()
        var sessionKey: String
    }

    var tabs: [OpenTab] = []
    var selectedTabID: OpenTab.ID?

    func openOrActivate(sessionKey: String) {
        if let existing = self.tabs.first(where: { $0.sessionKey == sessionKey }) {
            self.selectedTabID = existing.id
            return
        }
        let tab = OpenTab(sessionKey: sessionKey)
        self.tabs.append(tab)
        self.selectedTabID = tab.id
    }

    func close(tabID: OpenTab.ID) {
        guard let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let wasSelected = self.selectedTabID == tabID
        self.tabs.remove(at: idx)
        if wasSelected {
            self.selectedTabID = self.tabs.indices.contains(idx)
                ? self.tabs[idx].id
                : self.tabs.last?.id
        }
    }

    var selectedSessionKey: String? {
        guard let id = self.selectedTabID else { return nil }
        return self.tabs.first(where: { $0.id == id })?.sessionKey
    }
}

// MARK: - Archived store

@MainActor
final class CoworkArchivedStore {
    static let shared = CoworkArchivedStore()
    var archived: Set<String>

    private init() {
        let arr = UserDefaults.standard.stringArray(forKey: coworkArchivedKeysKey) ?? []
        self.archived = Set(arr)
    }

    func archive(_ key: String) {
        self.archived.insert(key)
        self.persist()
    }

    func unarchive(_ key: String) {
        self.archived.remove(key)
        self.persist()
    }

    func isArchived(_ key: String) -> Bool {
        self.archived.contains(key)
    }

    private func persist() {
        UserDefaults.standard.set(Array(self.archived), forKey: coworkArchivedKeysKey)
    }
}

// MARK: - Root

struct CoworkMainWindowView: View {
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var sessionPreviews: [String: SessionMenuPreviewSnapshot] = [:]
    @State private var viewModelCache: [String: OpenClawChatViewModel] = [:]
    @State private var sidebarQuery = ""
    @State private var isLoadingSessions = false
    @State private var isCreatingTask = false
    @State private var loadError: String?
    @State private var showArchived = false
    @State private var archivedStore = CoworkArchivedStore.shared
    @State private var tabs = CoworkTabBook()
    @State private var focus = CoworkWindowFocus()
    @State private var themeStore = ThemePreferenceStore.shared
    private let transport = MacGatewayChatTransport()

    var body: some View {
        NavigationSplitView {
            CoworkSessionsSidebar(
                sessions: self.filteredSessions,
                previews: self.sessionPreviews,
                selected: Binding(
                    get: { self.tabs.selectedSessionKey },
                    set: { key in if let key { self.tabs.openOrActivate(sessionKey: key) } }),
                query: self.$sidebarQuery,
                showArchived: self.$showArchived,
                isLoading: self.isLoadingSessions,
                isCreating: self.isCreatingTask,
                errorText: self.loadError,
                searchFocusTick: self.focus.searchFocusTick,
                isArchived: { self.archivedStore.isArchived($0) },
                onRefresh: { Task { await self.refreshSessions() } },
                onNewTask: { Task { await self.createTask() } },
                onArchive: { key in self.archivedStore.archive(key) },
                onUnarchive: { key in self.archivedStore.unarchive(key) },
                onDelete: { key in Task { await self.deleteSession(key: key) } },
                onExport: { key in self.exportSession(key: key) })
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } content: {
            VStack(spacing: 0) {
                CoworkTabBar(
                    tabs: self.tabs,
                    sessions: self.sessions,
                    onClose: { self.tabs.close(tabID: $0) })
                Divider().overlay(CoworkPalette.hairline)
                CoworkTaskDetailView(
                    viewModel: self.currentViewModel(),
                    selectedSession: self.currentSession(),
                    onExport: { self.exportCurrentSession() })
                    .frame(minWidth: 560)
            }
        } detail: {
            CoworkArtifactsPane(viewModel: self.currentViewModel())
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("OpenClaw")
        .frame(minWidth: 1100, minHeight: 720)
        .background(CoworkPalette.background)
        .preferredColorScheme(self.themeStore.preference.colorScheme)
        .task { await self.refreshSessions() }
        .onReceive(NotificationCenter.default.publisher(for: .coworkNewTaskRequested)) { _ in
            Task { await self.createTask() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .coworkFocusSearchRequested)) { _ in
            self.focus.searchFocusTick &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .coworkCycleThemeRequested)) { _ in
            self.themeStore.cycle()
        }
    }

    private var filteredSessions: [OpenClawChatSessionEntry] {
        let q = self.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let archived = self.archivedStore.archived
        return self.sessions.filter { entry in
            let isArchived = archived.contains(entry.key)
            if !self.showArchived, isArchived { return false }
            if self.showArchived, !isArchived { return false }
            if q.isEmpty { return true }
            let haystack = [entry.displayName, entry.subject, entry.key, entry.model]
                .compactMap(\.self).joined(separator: " ").lowercased()
            return haystack.contains(q)
        }
    }

    private func currentSession() -> OpenClawChatSessionEntry? {
        guard let key = self.tabs.selectedSessionKey else { return nil }
        return self.sessions.first(where: { $0.key == key })
    }

    private func currentViewModel() -> OpenClawChatViewModel? {
        guard let key = self.tabs.selectedSessionKey else { return nil }
        if let existing = self.viewModelCache[key] { return existing }
        let vm = OpenClawChatViewModel(sessionKey: key, transport: self.transport)
        self.viewModelCache[key] = vm
        return vm
    }

    @MainActor
    private func refreshSessions() async {
        self.isLoadingSessions = true
        self.loadError = nil
        do {
            let response = try await self.transport.listSessions(limit: 80)
            self.sessions = response.sessions
            if self.tabs.tabs.isEmpty {
                if let mainKey = response.defaults?.mainSessionKey,
                   self.sessions.contains(where: { $0.key == mainKey })
                {
                    self.tabs.openOrActivate(sessionKey: mainKey)
                } else if let first = self.sessions.first {
                    self.tabs.openOrActivate(sessionKey: first.key)
                }
            }
            let keys = self.sessions.prefix(20).map(\.key)
            Task { await self.loadPreviews(for: keys) }
        } catch {
            self.loadError = error.localizedDescription
        }
        self.isLoadingSessions = false
    }

    @MainActor
    private func loadPreviews(for keys: [String]) async {
        await SessionMenuPreviewLoader.prewarm(sessionKeys: keys, maxItems: 4)
        await withTaskGroup(of: (String, SessionMenuPreviewSnapshot).self) { group in
            for key in keys {
                group.addTask {
                    let snap = await SessionMenuPreviewLoader.load(sessionKey: key, maxItems: 4)
                    return (key, snap)
                }
            }
            for await (key, snap) in group {
                self.sessionPreviews[key] = snap
            }
        }
    }

    @MainActor
    private func createTask() async {
        guard !self.isCreatingTask else { return }
        self.isCreatingTask = true
        defer { self.isCreatingTask = false }
        do {
            let data = try await GatewayConnection.shared.request(
                method: "sessions.create",
                params: [:],
                timeoutMs: 15000)
            struct CreateResponse: Decodable {
                let key: String?
                let sessionKey: String?
            }
            let decoded = try? JSONDecoder().decode(CreateResponse.self, from: data)
            let newKey = decoded?.key ?? decoded?.sessionKey
            await self.refreshSessions()
            if let newKey { self.tabs.openOrActivate(sessionKey: newKey) }
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    @MainActor
    private func deleteSession(key: String) async {
        do {
            _ = try await GatewayConnection.shared.request(
                method: "sessions.delete",
                params: ["key": AnyCodable(key), "deleteTranscript": AnyCodable(true)],
                timeoutMs: 15000)
            self.viewModelCache.removeValue(forKey: key)
            if let tab = self.tabs.tabs.first(where: { $0.sessionKey == key }) {
                self.tabs.close(tabID: tab.id)
            }
            await self.refreshSessions()
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    @MainActor
    private func exportCurrentSession() {
        guard let key = self.tabs.selectedSessionKey else { return }
        self.exportSession(key: key)
    }

    @MainActor
    private func exportSession(key: String) {
        let vm = self.viewModelCache[key]
        let session = self.sessions.first(where: { $0.key == key })
        let suggested = session?.displayName ?? session?.subject ?? key
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(suggested)-session"
        panel.message = String(localized: "选择保存格式：JSON 或 Markdown")
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            let data: Data
            if ext == "md" || ext == "markdown" {
                data = Self.makeMarkdown(session: session, viewModel: vm).data(using: .utf8) ?? Data()
            } else {
                data = Self.makeJSON(session: session, viewModel: vm)
            }
            try? data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func makeJSON(session: OpenClawChatSessionEntry?, viewModel: OpenClawChatViewModel?) -> Data {
        struct Payload: Encodable {
            let session: OpenClawChatSessionEntry?
            let messages: [OpenClawChatMessage]
        }
        let payload = Payload(session: session, messages: viewModel?.messages ?? [])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(payload)) ?? Data()
    }

    private static func makeMarkdown(session: OpenClawChatSessionEntry?, viewModel: OpenClawChatViewModel?) -> String {
        var out = "# \(session?.displayName ?? session?.subject ?? session?.key ?? "会话")\n\n"
        if let s = session {
            if let model = s.model { out += "- Model: `\(model)`\n" }
            if let think = s.thinkingLevel { out += "- Thinking: `\(think)`\n" }
            out += "- Key: `\(s.key)`\n"
            out += "\n---\n\n"
        }
        for msg in viewModel?.messages ?? [] {
            out += "### \(msg.role)\n\n"
            for block in msg.content {
                if let text = block.text, !text.isEmpty {
                    out += text + "\n\n"
                } else if block.type == "tool_use" || block.type == "toolCall" {
                    out += "> 🔧 **\(block.name ?? "tool")**\n\n"
                }
            }
        }
        return out
    }
}

// MARK: - Tab bar

struct CoworkTabBar: View {
    var tabs: CoworkTabBook
    let sessions: [OpenClawChatSessionEntry]
    let onClose: (CoworkTabBook.OpenTab.ID) -> Void

    private func label(for key: String) -> String {
        if let s = sessions.first(where: { $0.key == key }) {
            return s.displayName ?? s.subject ?? s.key
        }
        return key
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(self.tabs.tabs) { tab in
                    let isSelected = self.tabs.selectedTabID == tab.id
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.white : CoworkPalette.muted)
                        Text(self.label(for: tab.sessionKey))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isSelected ? Color.white : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: 180, alignment: .leading)
                            .truncationMode(.middle)
                        Button {
                            self.onClose(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? CoworkPalette.accent : CoworkPalette.surface))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.tabs.selectedTabID = tab.id
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(CoworkPalette.surface.opacity(0.5))
    }
}

// MARK: - Sessions sidebar

struct CoworkSessionsSidebar: View {
    let sessions: [OpenClawChatSessionEntry]
    let previews: [String: SessionMenuPreviewSnapshot]
    @Binding var selected: String?
    @Binding var query: String
    @Binding var showArchived: Bool
    let isLoading: Bool
    let isCreating: Bool
    let errorText: String?
    let searchFocusTick: Int
    let isArchived: (String) -> Bool
    let onRefresh: () -> Void
    let onNewTask: () -> Void
    let onArchive: (String) -> Void
    let onUnarchive: (String) -> Void
    let onDelete: (String) -> Void
    let onExport: (String) -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.headerRow
            self.searchField
            self.archivedToggle
            if let errorText = self.errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            self.sessionsList
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CoworkPalette.surface)
        .onChange(of: self.searchFocusTick) { _, _ in
            self.isSearchFocused = true
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(self.showArchived ? "归档" : "任务")
                .font(.title2.weight(.bold))
            Spacer()
            Button { self.onRefresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(self.isLoading)
                .help("刷新")
            Button { self.onNewTask() } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(CoworkPalette.accent)
            }
            .buttonStyle(.borderless)
            .disabled(self.isCreating)
            .help("新建任务 (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索任务", text: self.$query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(self.$isSearchFocused)
            if !self.query.isEmpty {
                Button { self.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CoworkPalette.surfaceElevated))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var archivedToggle: some View {
        HStack {
            Spacer()
            Button {
                self.showArchived.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: self.showArchived ? "archivebox.fill" : "archivebox")
                        .font(.caption)
                    Text(self.showArchived ? "显示活跃" : "显示归档")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if self.isLoading, self.sessions.isEmpty {
                    ProgressView().controlSize(.small)
                        .padding(.top, 20)
                        .frame(maxWidth: .infinity)
                } else if self.sessions.isEmpty {
                    Text(self.showArchived ? "暂无归档任务。" : (self.query.isEmpty ? "暂无任务。点击 + 创建。" : "没有匹配的任务。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    ForEach(self.sessions, id: \.key) { entry in
                        CoworkTaskCard(
                            entry: entry,
                            preview: self.previews[entry.key],
                            isSelected: self.selected == entry.key,
                            isArchived: self.isArchived(entry.key))
                            .contentShape(Rectangle())
                            .onTapGesture { self.selected = entry.key }
                            .contextMenu {
                                Button("打开") { self.selected = entry.key }
                                Divider()
                                Button("复制 Session Key") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.key, forType: .string)
                                }
                                Button("导出…") { self.onExport(entry.key) }
                                Divider()
                                if self.isArchived(entry.key) {
                                    Button("取消归档") { self.onUnarchive(entry.key) }
                                } else {
                                    Button("归档") { self.onArchive(entry.key) }
                                }
                                Button("删除…", role: .destructive) {
                                    Self.confirmDelete(key: entry.key, action: self.onDelete)
                                }
                            }
                            .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private static func confirmDelete(key: String, action: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "确认删除此会话？")
        alert.informativeText = String(localized: "删除后该会话的历史记录将不可恢复。")
        alert.addButton(withTitle: String(localized: "删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            action(key)
        }
    }
}

struct CoworkTaskCard: View {
    let entry: OpenClawChatSessionEntry
    let preview: SessionMenuPreviewSnapshot?
    let isSelected: Bool
    let isArchived: Bool

    private var primaryTitle: String {
        self.entry.displayName ?? self.entry.subject ?? self.entry.key
    }

    private var statusTint: Color {
        if self.isArchived { return CoworkPalette.muted }
        guard let updatedAt = entry.updatedAt else { return CoworkPalette.muted }
        let age = Date().timeIntervalSince1970 * 1000 - updatedAt
        if age < 2 * 60_000 { return CoworkPalette.working }
        if age < 30 * 60_000 { return CoworkPalette.success }
        return CoworkPalette.muted
    }

    private var isWorking: Bool {
        if self.isArchived { return false }
        guard let updatedAt = entry.updatedAt else { return false }
        return Date().timeIntervalSince1970 * 1000 - updatedAt < 2 * 60_000
    }

    private var previewLine: String? {
        let items = preview?.items ?? []
        guard let assistant = items.reversed().first(where: { $0.role == .assistant }) ?? items.last else { return nil }
        let t = assistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var relativeTime: String? {
        guard let ts = entry.updatedAt else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: Date(timeIntervalSince1970: ts / 1000), relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if self.isWorking {
                    Circle()
                        .stroke(self.statusTint.opacity(0.35), lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .scaleEffect(1.35).opacity(0.6)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                   value: self.isWorking)
                }
                Circle().fill(self.statusTint).frame(width: 8, height: 8)
            }
            .frame(width: 16, height: 16).padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.primaryTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(self.isSelected ? Color.white : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    if self.isArchived {
                        Image(systemName: "archivebox")
                            .font(.caption2)
                            .foregroundStyle(self.isSelected ? Color.white.opacity(0.75) : .secondary)
                    }
                }
                if let line = self.previewLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(self.isSelected ? Color.white.opacity(0.82) : .secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let model = entry.model, !model.isEmpty {
                        Text(model).font(.caption2.monospaced())
                            .foregroundStyle(self.isSelected ? Color.white.opacity(0.82) : .secondary)
                            .lineLimit(1)
                    }
                    if let rel = self.relativeTime {
                        Text(rel).font(.caption2)
                            .foregroundStyle(self.isSelected ? Color.white.opacity(0.82) : .secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.isSelected ? CoworkPalette.accent : Color.clear))
    }
}

// MARK: - Center: task detail + chat

struct CoworkTaskDetailView: View {
    var viewModel: OpenClawChatViewModel?
    var selectedSession: OpenClawChatSessionEntry?
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoworkTaskHeader(
                session: self.selectedSession,
                viewModel: self.viewModel,
                onExport: self.onExport)
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)

            if let viewModel = self.viewModel {
                let steps = CoworkPlanExtractor.extractPlanSteps(from: viewModel)
                if !steps.isEmpty {
                    CoworkInlinePlanBar(steps: steps)
                        .padding(.horizontal, 22).padding(.bottom, 10)
                }
            }

            Divider().overlay(CoworkPalette.hairline)

            if let viewModel = self.viewModel {
                OpenClawChatView(
                    viewModel: viewModel,
                    showsSessionSwitcher: false,
                    style: .standard,
                    userAccent: CoworkPalette.userBubble,
                    showsAssistantTrace: true)
                    .id(viewModel.sessionKey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CoworkEmptyChatPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CoworkPalette.background)
    }
}

struct CoworkTaskHeader: View {
    var session: OpenClawChatSessionEntry?
    var viewModel: OpenClawChatViewModel?
    let onExport: () -> Void

    private var title: String {
        self.session?.displayName ?? self.session?.subject ?? self.session?.key ?? "OpenClaw"
    }

    private var isWorking: Bool {
        guard let vm = self.viewModel else { return false }
        return vm.isSending || vm.pendingRunCount > 0 || !vm.pendingToolCalls.isEmpty
    }

    private var liveActionText: String? {
        guard let vm = self.viewModel else { return nil }
        if let last = vm.pendingToolCalls.last { return "正在运行 `\(last.name)`" }
        if vm.isSending { return "正在思考…" }
        return nil
    }

    private var statusPill: (String, Color, String) {
        if self.viewModel == nil { return ("等待会话", CoworkPalette.muted, "moon") }
        if self.isWorking { return ("Claude 正在工作", CoworkPalette.working, "sparkles") }
        return ("就绪", CoworkPalette.success, "checkmark.circle.fill")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(self.title).font(.title.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu {
                    Button("导出会话…") { self.onExport() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(self.viewModel == nil)
                CoworkWorkingPill(
                    text: self.statusPill.0,
                    systemImage: self.statusPill.2,
                    tint: self.statusPill.1,
                    pulse: self.isWorking)
            }

            HStack(spacing: 10) {
                if let session = self.session {
                    if let model = session.model, !model.isEmpty {
                        CoworkChip(text: model, systemImage: "cpu")
                    }
                    if let thinking = session.thinkingLevel, !thinking.isEmpty {
                        CoworkChip(text: "思考 \(thinking)", systemImage: "brain")
                    }
                    if let tokens = session.totalTokens {
                        CoworkChip(text: "上下文 \(formatCompactNumber(tokens))", systemImage: "text.alignleft")
                    }
                }
                Spacer()
            }

            if let live = self.liveActionText {
                Text(live).font(.callout.monospaced())
                    .foregroundStyle(CoworkPalette.working).padding(.top, 2)
            }
        }
    }
}

struct CoworkWorkingPill: View {
    let text: String
    let systemImage: String
    let tint: Color
    let pulse: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: self.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(self.tint)
                .symbolEffect(.pulse, options: self.pulse ? .repeating : .default, isActive: self.pulse)
            Text(self.text).font(.caption.weight(.semibold))
                .foregroundStyle(self.tint)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(self.tint.opacity(0.14)))
    }
}

struct CoworkChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: self.systemImage).font(.caption2)
            Text(self.text).font(.caption.monospaced())
                .lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(CoworkPalette.surface))
    }
}

// MARK: - Inline plan bar

struct CoworkInlinePlanBar: View {
    let steps: [CoworkPlanExtractor.PlanStep]

    private var completed: Int { self.steps.filter { $0.status == "completed" }.count }
    private var progress: Double {
        self.steps.isEmpty ? 0 : Double(self.completed) / Double(self.steps.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(CoworkPalette.accent)
                Text("执行计划").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(self.completed)/\(self.steps.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: self.progress)
                .progressViewStyle(.linear).tint(CoworkPalette.accent)
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(self.steps.prefix(5).enumerated()), id: \.offset) { idx, step in
                    HStack(spacing: 5) {
                        Image(systemName: step.statusIcon).font(.caption)
                            .foregroundStyle(step.statusColor)
                        Text("步骤 \(idx + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(step.statusColor.opacity(0.12)))
                }
                if self.steps.count > 5 {
                    Text("+\(self.steps.count - 5) 更多").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(CoworkPalette.surfaceElevated)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CoworkPalette.hairline, lineWidth: 1)))
    }
}

// MARK: - Right: Artifacts pane

struct CoworkArtifactsPane: View {
    var viewModel: OpenClawChatViewModel?

    private var artifacts: [CoworkArtifact] {
        guard let vm = self.viewModel else { return [] }
        return CoworkArtifactExtractor.extract(from: vm.messages)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoworkPlanDetailCard(viewModel: self.viewModel)
                CoworkArtifactsCard(artifacts: self.artifacts, hasSession: self.viewModel != nil)
                CoworkNotesCard(sessionKey: self.viewModel?.sessionKey)
                CoworkActivityCard(viewModel: self.viewModel)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CoworkPalette.surface)
    }
}

struct CoworkArtifactsCard: View {
    let artifacts: [CoworkArtifact]
    let hasSession: Bool

    var body: some View {
        CoworkCard(
            title: "产物",
            systemImage: "doc.on.doc.fill",
            accessory: self.artifacts.isEmpty ? nil : "\(self.artifacts.count)")
        {
            if self.artifacts.isEmpty {
                Text(self.hasSession ? "Agent 尚未产出文件。" : "选择会话后显示产出的文件与代码片段。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.artifacts) { art in
                        CoworkArtifactRow(artifact: art)
                            .contentShape(Rectangle())
                            .onTapGesture { Self.reveal(artifact: art) }
                            .contextMenu {
                                Button("在访达中显示") { Self.reveal(artifact: art) }
                                Button("复制路径") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(art.label, forType: .string)
                                }
                            }
                    }
                }
            }
        }
    }

    private static func reveal(artifact: CoworkArtifact) {
        let fm = FileManager.default
        let candidates = [artifact.label, (artifact.label as NSString).expandingTildeInPath]
        for raw in candidates {
            if fm.fileExists(atPath: raw) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: raw)])
                return
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.label, forType: .string)
    }
}

// MARK: - Plan extraction & detail

enum CoworkPlanExtractor {
    struct PlanStep: Hashable {
        let text: String
        let status: String

        var statusIcon: String {
            switch self.status {
            case "completed": "checkmark.circle.fill"
            case "in_progress": "arrow.triangle.2.circlepath.circle.fill"
            default: "circle"
            }
        }

        var statusColor: Color {
            switch self.status {
            case "completed": CoworkPalette.success
            case "in_progress": CoworkPalette.working
            default: CoworkPalette.muted
            }
        }
    }

    @MainActor
    static func extractPlanSteps(from viewModel: OpenClawChatViewModel) -> [PlanStep] {
        for message in viewModel.messages.reversed() {
            for block in message.content {
                guard let type = block.type,
                      (type == "tool_use" || type == "toolCall" || type == "tool_call"),
                      block.name == "update_plan",
                      let args = block.arguments?.value as? [String: AnyCodable],
                      let rawPlan = args["plan"]?.value as? [AnyCodable] else { continue }
                let steps = rawPlan.compactMap { entry -> PlanStep? in
                    guard let row = entry.value as? [String: AnyCodable],
                          let text = row["step"]?.value as? String,
                          let status = row["status"]?.value as? String else { return nil }
                    return PlanStep(text: text, status: status)
                }
                if !steps.isEmpty { return steps }
            }
        }
        return []
    }
}

struct CoworkPlanDetailCard: View {
    var viewModel: OpenClawChatViewModel?

    private var steps: [CoworkPlanExtractor.PlanStep] {
        guard let vm = self.viewModel else { return [] }
        return CoworkPlanExtractor.extractPlanSteps(from: vm)
    }

    var body: some View {
        CoworkCard(
            title: "计划",
            systemImage: "list.bullet.rectangle.portrait",
            accessory: self.steps.isEmpty ? nil : "\(self.steps.filter { $0.status == "completed" }.count)/\(self.steps.count)")
        {
            if self.steps.isEmpty {
                Text(self.viewModel == nil
                    ? "选择会话后在此查看计划。"
                    : "Agent 尚未建立结构化计划。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(self.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.statusIcon)
                                .foregroundStyle(step.statusColor).frame(width: 18)
                            HStack(spacing: 4) {
                                Text("\(idx + 1).").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(step.text).font(.callout)
                                    .foregroundStyle(step.status == "completed" ? .secondary : .primary)
                                    .strikethrough(step.status == "completed")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Notes card (local overlay)

struct CoworkNotesCard: View {
    let sessionKey: String?
    @State private var text: String = ""
    @State private var hasLoaded = false

    private var storageKey: String? {
        guard let key = sessionKey else { return nil }
        return coworkNotesKeyPrefix + key
    }

    var body: some View {
        CoworkCard(title: "笔记", systemImage: "note.text", accessory: nil) {
            if self.sessionKey == nil {
                Text("选择会话后可写入私有笔记。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextEditor(text: self.$text)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 80, maxHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(CoworkPalette.surface))
                    .onChange(of: self.text) { _, newValue in
                        guard self.hasLoaded, let key = self.storageKey else { return }
                        UserDefaults.standard.set(newValue, forKey: key)
                    }
            }
        }
        .onAppear { self.load() }
        .onChange(of: self.sessionKey) { _, _ in self.load() }
    }

    private func load() {
        self.hasLoaded = false
        if let key = self.storageKey {
            self.text = UserDefaults.standard.string(forKey: key) ?? ""
        } else {
            self.text = ""
        }
        self.hasLoaded = true
    }
}

// MARK: - Activity card

struct CoworkActivityCard: View {
    var viewModel: OpenClawChatViewModel?

    private struct Entry: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String?
        let timestamp: Double?
    }

    @MainActor
    private var entries: [Entry] {
        guard let vm = self.viewModel else { return [] }
        var out: [Entry] = []
        for call in vm.pendingToolCalls {
            out.append(
                Entry(id: "pending-\(call.toolCallId)",
                      icon: call.isError == true ? "exclamationmark.triangle.fill" : "wrench.adjustable.fill",
                      tint: call.isError == true ? .red : CoworkPalette.working,
                      title: call.name,
                      subtitle: "进行中",
                      timestamp: call.startedAt))
        }
        for msg in vm.messages.suffix(16).reversed() {
            for block in msg.content where (block.type == "tool_use" || block.type == "toolCall" || block.type == "tool_call") {
                out.append(
                    Entry(id: "tool-\(msg.id.uuidString)-\(block.id ?? block.name ?? UUID().uuidString)",
                          icon: "wrench.and.screwdriver",
                          tint: CoworkPalette.accent,
                          title: block.name ?? "tool",
                          subtitle: nil,
                          timestamp: msg.timestamp))
            }
        }
        return out
    }

    var body: some View {
        CoworkCard(title: "活动", systemImage: "dot.radiowaves.left.and.right", accessory: nil) {
            let list = self.entries
            if list.isEmpty {
                Text(self.viewModel == nil
                    ? "选择会话后显示实时动态。"
                    : "暂无进行中的活动。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(list) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.icon)
                                .foregroundStyle(entry.tint)
                                .frame(width: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.callout.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 6) {
                                    if let sub = entry.subtitle {
                                        Text(sub).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let ts = entry.timestamp {
                                        Text(Self.formatRelative(ms: ts))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private static func formatRelative(ms: Double) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: Date(timeIntervalSince1970: ms / 1000), relativeTo: Date())
    }
}

// MARK: - Artifact extraction

struct CoworkArtifact: Identifiable {
    let id: String
    let kind: Kind
    let label: String
    let detail: String?

    enum Kind {
        case image, file, code
        var systemImage: String {
            switch self {
            case .image: "photo.fill"
            case .file: "doc.fill"
            case .code: "chevron.left.forwardslash.chevron.right"
            }
        }
        var tint: Color {
            switch self {
            case .image: .purple
            case .file: CoworkPalette.accent
            case .code: .teal
            }
        }
    }
}

enum CoworkArtifactExtractor {
    static func extract(from messages: [OpenClawChatMessage]) -> [CoworkArtifact] {
        var out: [CoworkArtifact] = []
        for msg in messages {
            for block in msg.content {
                let t = block.type ?? ""
                if t == "image" || t == "image_block" || (block.mimeType?.hasPrefix("image/") ?? false) {
                    out.append(CoworkArtifact(
                        id: "\(msg.id.uuidString)-img-\(block.id ?? block.fileName ?? "image")",
                        kind: .image,
                        label: block.fileName ?? "image",
                        detail: block.mimeType))
                } else if t == "file" || block.fileName != nil {
                    out.append(CoworkArtifact(
                        id: "\(msg.id.uuidString)-file-\(block.id ?? block.fileName ?? "file")",
                        kind: .file,
                        label: block.fileName ?? "file",
                        detail: block.mimeType))
                } else if block.name == "write_file" || block.name == "apply_patch" || block.name == "edit" {
                    if let args = block.arguments?.value as? [String: AnyCodable],
                       let path = args["path"]?.value as? String ?? args["file"]?.value as? String
                    {
                        out.append(CoworkArtifact(
                            id: "\(msg.id.uuidString)-code-\(block.id ?? path)",
                            kind: .code, label: path, detail: block.name))
                    }
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.label).inserted }
    }
}

struct CoworkArtifactRow: View {
    let artifact: CoworkArtifact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: self.artifact.kind.systemImage)
                .foregroundStyle(self.artifact.kind.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.artifact.label).font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                if let detail = self.artifact.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right.square")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Empty state

struct CoworkEmptyChatPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 48)).foregroundStyle(CoworkPalette.muted)
            Text("选择左侧任务开始对话").font(.title3.weight(.medium))
            Text("或点击左上角 + 新建一个任务。").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Generic card

struct CoworkCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let accessory: String?
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringKey,
        systemImage: String,
        accessory: String? = nil,
        @ViewBuilder content: () -> Content)
    {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: self.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CoworkPalette.accent)
                Text(self.title).font(.headline)
                Spacer()
                if let accessory = self.accessory {
                    Text(accessory).font(.caption.monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(CoworkPalette.accent.opacity(0.12)))
                        .foregroundStyle(CoworkPalette.accent)
                }
            }
            self.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CoworkPalette.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(CoworkPalette.hairline, lineWidth: 1)))
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let coworkNewTaskRequested = Notification.Name("ai.openclaw.cowork.newTask")
    static let coworkFocusSearchRequested = Notification.Name("ai.openclaw.cowork.focusSearch")
    static let coworkCycleThemeRequested = Notification.Name("ai.openclaw.cowork.cycleTheme")
}

// MARK: - Helpers

private func formatCompactNumber(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}
