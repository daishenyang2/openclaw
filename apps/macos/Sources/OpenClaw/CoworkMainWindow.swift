import AppKit
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Cowork-inspired desktop main window.
///
/// Three-pane layout:
/// - Left: sessions sidebar (card-style rows)
/// - Center: task header + chat (reuses `OpenClawChatView`)
/// - Right: plan checklist + activity timeline
struct CoworkMainWindowView: View {
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var selectedSessionKey: String?
    @State private var viewModel: OpenClawChatViewModel?
    @State private var isLoadingSessions = false
    @State private var loadError: String?
    private let transport = MacGatewayChatTransport()

    var body: some View {
        NavigationSplitView {
            CoworkSessionsSidebar(
                sessions: self.sessions,
                selected: self.$selectedSessionKey,
                isLoading: self.isLoadingSessions,
                errorText: self.loadError,
                onRefresh: { Task { await self.refreshSessions() } })
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } content: {
            CoworkChatPane(
                viewModel: self.viewModel,
                selectedSession: self.selectedSession())
                .frame(minWidth: 520)
        } detail: {
            CoworkActivityPane(viewModel: self.viewModel)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("OpenClaw")
        .frame(minWidth: 1060, minHeight: 680)
        .background(CoworkPalette.background)
        .task {
            await self.refreshSessions()
        }
        .onChange(of: self.selectedSessionKey) { _, newKey in
            self.switchSession(to: newKey)
        }
    }

    private func selectedSession() -> OpenClawChatSessionEntry? {
        guard let key = self.selectedSessionKey else { return nil }
        return self.sessions.first(where: { $0.key == key })
    }

    @MainActor
    private func refreshSessions() async {
        self.isLoadingSessions = true
        self.loadError = nil
        do {
            let response = try await self.transport.listSessions(limit: 50)
            self.sessions = response.sessions
            if self.selectedSessionKey == nil,
               let mainKey = response.defaults?.mainSessionKey,
               self.sessions.contains(where: { $0.key == mainKey })
            {
                self.selectedSessionKey = mainKey
            } else if self.selectedSessionKey == nil {
                self.selectedSessionKey = self.sessions.first?.key
            }
        } catch {
            self.loadError = error.localizedDescription
        }
        self.isLoadingSessions = false
    }

    @MainActor
    private func switchSession(to newKey: String?) {
        guard let newKey else {
            self.viewModel = nil
            return
        }
        self.viewModel = OpenClawChatViewModel(
            sessionKey: newKey,
            transport: self.transport)
    }
}

// MARK: - Visual tokens

enum CoworkPalette {
    static let background = Color(nsColor: NSColor.windowBackgroundColor)
    static let surface = Color(nsColor: NSColor.controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: NSColor.underPageBackgroundColor)
    static let hairline = Color.gray.opacity(0.18)
    static let accent = Color.accentColor
    static let working = Color.orange
    static let success = Color.green
    static let muted = Color.secondary
}

// MARK: - Sessions sidebar

struct CoworkSessionsSidebar: View {
    let sessions: [OpenClawChatSessionEntry]
    @Binding var selected: String?
    let isLoading: Bool
    let errorText: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("会话")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    self.onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(self.isLoading)
                .help("刷新")
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if let errorText = self.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if self.isLoading, self.sessions.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity)
                    } else if self.sessions.isEmpty {
                        Text("暂无会话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        ForEach(self.sessions, id: \.key) { entry in
                            CoworkSessionCard(
                                entry: entry,
                                isSelected: self.selected == entry.key)
                                .contentShape(Rectangle())
                                .onTapGesture { self.selected = entry.key }
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CoworkPalette.surface)
    }
}

struct CoworkSessionCard: View {
    let entry: OpenClawChatSessionEntry
    let isSelected: Bool

    private var primaryTitle: String {
        self.entry.displayName
            ?? self.entry.subject
            ?? self.entry.key
    }

    private var statusDotColor: Color {
        if let updatedAt = entry.updatedAt {
            let ageMs = Date().timeIntervalSince1970 * 1000 - updatedAt
            if ageMs < 2 * 60_000 { return CoworkPalette.working }
            if ageMs < 30 * 60_000 { return CoworkPalette.success }
        }
        return CoworkPalette.muted
    }

    private var relativeTime: String? {
        guard let updatedAt = entry.updatedAt else { return nil }
        let date = Date(timeIntervalSince1970: updatedAt / 1000)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(self.statusDotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(self.primaryTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(self.isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let model = entry.model, !model.isEmpty {
                        Text(model)
                            .font(.caption2.monospaced())
                            .foregroundStyle(self.isSelected ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(1)
                    }
                    if let rel = self.relativeTime {
                        Text("· \(rel)")
                            .font(.caption2)
                            .foregroundStyle(self.isSelected ? Color.white.opacity(0.75) : Color.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.isSelected ? CoworkPalette.accent : Color.clear))
    }
}

// MARK: - Center pane (task header + chat)

struct CoworkChatPane: View {
    var viewModel: OpenClawChatViewModel?
    var selectedSession: OpenClawChatSessionEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoworkTaskHeader(
                session: self.selectedSession,
                viewModel: self.viewModel)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            Divider()
                .overlay(CoworkPalette.hairline)

            if let viewModel = self.viewModel {
                OpenClawChatView(
                    viewModel: viewModel,
                    showsSessionSwitcher: false,
                    style: .standard,
                    showsAssistantTrace: true)
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

    private var title: String {
        self.session?.displayName
            ?? self.session?.subject
            ?? self.session?.key
            ?? "OpenClaw"
    }

    private var isWorking: Bool {
        guard let vm = self.viewModel else { return false }
        return vm.isSending || vm.pendingRunCount > 0 || !vm.pendingToolCalls.isEmpty
    }

    private var statusPill: (String, Color, String) {
        if self.viewModel == nil {
            return ("等待会话", CoworkPalette.muted, "moon")
        }
        if self.isWorking {
            return ("执行中", CoworkPalette.working, "hare.fill")
        }
        return ("待命", CoworkPalette.success, "checkmark.circle.fill")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: self.statusPill.2)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(self.statusPill.1)
                    Text(self.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let session = self.session {
                    HStack(spacing: 8) {
                        if let model = session.model, !model.isEmpty {
                            Text(model)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(CoworkPalette.surface))
                        }
                        if let thinking = session.thinkingLevel, !thinking.isEmpty {
                            Text("思考 \(thinking)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let tokens = session.totalTokens {
                            Text("上下文 \(formatCompactNumber(tokens))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            CoworkStatusPill(text: self.statusPill.0, tint: self.statusPill.1)
        }
    }
}

struct CoworkStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.tint)
                .frame(width: 7, height: 7)
            Text(self.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(self.tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(self.tint.opacity(0.12)))
    }
}

struct CoworkEmptyChatPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 44))
                .foregroundStyle(CoworkPalette.muted)
            Text("选择左侧会话开始对话")
                .font(.title3.weight(.medium))
            Text("或从菜单栏 OpenClaw 图标创建一个新会话。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Activity pane (plan + timeline)

struct CoworkActivityPane: View {
    var viewModel: OpenClawChatViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoworkPlanCard(viewModel: self.viewModel)
                CoworkActivityTimeline(viewModel: self.viewModel)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CoworkPalette.surface)
    }
}

// MARK: Plan card

struct CoworkPlanCard: View {
    var viewModel: OpenClawChatViewModel?

    private var steps: [PlanStep] {
        guard let viewModel else { return [] }
        return CoworkPlanCard.extractPlanSteps(from: viewModel)
    }

    private var progressText: String {
        let total = self.steps.count
        if total == 0 { return "" }
        let done = self.steps.filter { $0.status == "completed" }.count
        return "\(done)/\(total)"
    }

    var body: some View {
        CoworkCard(
            title: "执行计划",
            systemImage: "list.bullet.rectangle.portrait",
            accessory: self.steps.isEmpty ? nil : self.progressText)
        {
            if self.steps.isEmpty {
                Text(self.viewModel == nil
                    ? "选择会话后在此查看计划。"
                    : "Agent 尚未建立结构化计划。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(self.steps.enumerated()), id: \.offset) { idx, step in
                        CoworkPlanStepRow(
                            index: idx + 1,
                            step: step,
                            isLast: idx == self.steps.count - 1)
                    }
                }
            }
        }
    }

    struct PlanStep {
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

    static func extractPlanSteps(from viewModel: OpenClawChatViewModel) -> [PlanStep] {
        for message in viewModel.messages.reversed() {
            for block in message.content {
                guard let type = block.type,
                      (type == "tool_use" || type == "toolCall" || type == "tool_call"),
                      block.name == "update_plan",
                      let args = block.arguments?.value as? [String: AnyCodable],
                      let rawPlan = args["plan"]?.value as? [AnyCodable]
                else { continue }
                let steps = rawPlan.compactMap { entry -> PlanStep? in
                    guard let row = entry.value as? [String: AnyCodable],
                          let text = row["step"]?.value as? String,
                          let status = row["status"]?.value as? String
                    else { return nil }
                    return PlanStep(text: text, status: status)
                }
                if !steps.isEmpty { return steps }
            }
        }
        return []
    }
}

struct CoworkPlanStepRow: View {
    let index: Int
    let step: CoworkPlanCard.PlanStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .center) {
                Image(systemName: self.step.statusIcon)
                    .font(.body)
                    .foregroundStyle(self.step.statusColor)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(self.index).")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(self.step.text)
                        .font(.callout)
                        .foregroundStyle(self.step.status == "completed" ? .secondary : .primary)
                        .strikethrough(self.step.status == "completed")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Activity timeline

struct CoworkActivityTimeline: View {
    var viewModel: OpenClawChatViewModel?

    private struct Entry: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String?
        let timestamp: Double?
    }

    private var entries: [Entry] {
        guard let vm = self.viewModel else { return [] }
        var out: [Entry] = []
        for call in vm.pendingToolCalls {
            out.append(
                Entry(
                    id: "pending-\(call.toolCallId)",
                    icon: call.isError == true ? "exclamationmark.triangle.fill" : "wrench.adjustable.fill",
                    tint: call.isError == true ? .red : CoworkPalette.working,
                    title: call.name,
                    subtitle: "进行中",
                    timestamp: call.startedAt))
        }
        let recent = vm.messages.suffix(12)
        for msg in recent.reversed() {
            for block in msg.content {
                if block.type == "tool_use" || block.type == "toolCall" || block.type == "tool_call" {
                    out.append(
                        Entry(
                            id: "tool-\(msg.id.uuidString)-\(block.id ?? block.name ?? "unknown")",
                            icon: "wrench.and.screwdriver",
                            tint: CoworkPalette.accent,
                            title: block.name ?? "tool",
                            subtitle: nil,
                            timestamp: msg.timestamp))
                }
            }
        }
        return out
    }

    var body: some View {
        CoworkCard(
            title: "活动",
            systemImage: "dot.radiowaves.left.and.right",
            accessory: nil)
        {
            if self.entries.isEmpty {
                Text(self.viewModel == nil
                    ? "选择会话后在此查看实时动态。"
                    : "暂无进行中的活动。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(self.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.icon)
                                .foregroundStyle(entry.tint)
                                .frame(width: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 6) {
                                    if let sub = entry.subtitle {
                                        Text(sub)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let ts = entry.timestamp {
                                        Text(Self.formatRelative(ms: ts))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
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
        let date = Date(timeIntervalSince1970: ms / 1000)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Generic card shell

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
                Text(self.title)
                    .font(.headline)
                Spacer()
                if let accessory = self.accessory {
                    Text(accessory)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(CoworkPalette.accent.opacity(0.12)))
                        .foregroundStyle(CoworkPalette.accent)
                }
            }
            self.content
                .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Helpers

private func formatCompactNumber(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}
