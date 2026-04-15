import AppKit
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Cowork-style desktop main window: sessions sidebar on the left, chat in
/// the center, live activity / plan inspector on the right. Reuses the
/// existing `OpenClawChatView` for the chat surface and
/// `MacGatewayChatTransport` for network transport.
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
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } content: {
            Group {
                if let viewModel = self.viewModel {
                    OpenClawChatView(
                        viewModel: viewModel,
                        showsSessionSwitcher: false,
                        style: .standard,
                        showsAssistantTrace: true)
                } else {
                    ContentUnavailableView(
                        "选择左侧会话开始对话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("或在菜单栏创建一个新的会话。"))
                }
            }
            .frame(minWidth: 480)
        } detail: {
            CoworkActivityPane(viewModel: self.viewModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 440)
        }
        .navigationTitle("OpenClaw")
        .frame(minWidth: 1000, minHeight: 640)
        .task {
            await self.refreshSessions()
        }
        .onChange(of: self.selectedSessionKey) { _, newKey in
            self.switchSession(to: newKey)
        }
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

// MARK: - Sessions sidebar

struct CoworkSessionsSidebar: View {
    let sessions: [OpenClawChatSessionEntry]
    @Binding var selected: String?
    let isLoading: Bool
    let errorText: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会话")
                    .font(.headline)
                Spacer()
                Button {
                    self.onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(self.isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let errorText = self.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            List(selection: self.$selected) {
                ForEach(self.sessions, id: \.key) { entry in
                    CoworkSessionRow(entry: entry)
                        .tag(entry.key)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct CoworkSessionRow: View {
    let entry: OpenClawChatSessionEntry

    private var primaryTitle: String {
        self.entry.displayName
            ?? self.entry.subject
            ?? self.entry.key
    }

    private var secondaryText: String? {
        if let model = entry.model, !model.isEmpty { return model }
        if let surface = entry.surface, !surface.isEmpty { return surface }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.primaryTitle)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            if let secondary = self.secondaryText {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Activity / Plan pane

struct CoworkActivityPane: View {
    var viewModel: OpenClawChatViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("活动")
                    .font(.title3.weight(.semibold))

                if let viewModel = self.viewModel {
                    self.planSection(viewModel: viewModel)
                    Divider()
                    self.toolCallsSection(viewModel: viewModel)
                } else {
                    Text("选择会话后在此查看计划与工具调用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func planSection(viewModel: OpenClawChatViewModel) -> some View {
        let planSteps = self.extractPlanSteps(from: viewModel)
        VStack(alignment: .leading, spacing: 8) {
            Text("计划")
                .font(.headline)
            if planSteps.isEmpty {
                Text("暂无结构化计划。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(planSteps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: step.statusIcon)
                                .foregroundStyle(step.statusColor)
                                .frame(width: 16)
                            Text(step.text)
                                .font(.callout)
                                .foregroundStyle(step.status == "completed" ? .secondary : .primary)
                                .strikethrough(step.status == "completed")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolCallsSection(viewModel: OpenClawChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工具调用")
                .font(.headline)
            if viewModel.pendingToolCalls.isEmpty {
                Text("暂无进行中的工具调用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.pendingToolCalls) { call in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: call.isError == true ? "exclamationmark.circle" : "wrench.and.screwdriver")
                            .foregroundStyle(call.isError == true ? .red : .accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.name)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let started = call.startedAt {
                                Text(Self.formatElapsed(since: started))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private static func formatElapsed(since ms: Double) -> String {
        let seconds = max(0, (Date().timeIntervalSince1970 * 1000 - ms) / 1000)
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        return "\(minutes)m"
    }

    private struct PlanStep {
        let text: String
        let status: String

        var statusIcon: String {
            switch self.status {
            case "completed": "checkmark.circle.fill"
            case "in_progress": "arrow.triangle.2.circlepath"
            default: "circle"
            }
        }

        var statusColor: Color {
            switch self.status {
            case "completed": .green
            case "in_progress": .blue
            default: .secondary
            }
        }
    }

    private func extractPlanSteps(from viewModel: OpenClawChatViewModel) -> [PlanStep] {
        // Find the latest update_plan tool call arguments in the message stream.
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
