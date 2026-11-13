//
//  MCPServersView.swift
//  Tamio (macOS)
//
//  Saved remote MCP servers: a list on the left, the selected one on the
//  right with its connection, tools and the tool caller.
//

import SwiftUI
import TamioDesign
import TamioModule

struct MCPServersView: View {
    @EnvironmentObject var store: TamioStore

    @State private var searchText = ""
    @State private var selection: RDMCPServer.ID?
    @State private var creating = false
    @State private var editing: EditorTarget?

    struct EditorTarget: Identifiable {
        let id = UUID()
        let server: RDMCPServer.ID?
    }

    var filtered: [RDMCPServer] {
        let all = store.mcpServerGroup.servers
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(key)
                || $0.endpoint.lowercased().contains(key)
                || $0.comment.lowercased().contains(key)
        }
    }

    var body: some View {
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search MCP servers",
            primary: ToolbarAction("New MCP Server", systemImage: "plus", primary: true) {
                creating = true
            }
        ) {
        } trailing: {
        } header: {
            PageTitle("MCP Servers")
        } content: {
            if store.mcpServerGroup.servers.isEmpty {
                EmptyStateView(
                    "No MCP servers yet",
                    systemImage: "network",
                    message: "Remote MCP servers you can call tools on.",
                    actionTitle: "New MCP Server"
                ) {
                    creating = true
                }
                .rxCard()
            } else if filtered.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
                    .rxCard()
            } else {
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    list.frame(width: 320)
                    if let selection, store.mcpServerGroup.servers.contains(where: { $0.id == selection }) {
                        MCPServerDetail(server: selection) { editing = EditorTarget(server: $0) }
                            .id(selection)
                    } else {
                        EmptyStateView("Select an MCP server", systemImage: "network")
                            .rxCard()
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            MCPServerEditorSheet(server: nil) { created in
                creating = false
                if let created { selection = created }
            }
            .environmentObject(TamioStore.shared)
        }
        .sheet(item: $editing) { target in
            MCPServerEditorSheet(server: target.server) { _ in editing = nil }
                .environmentObject(TamioStore.shared)
        }
        .onAppear {
            if selection == nil { selection = store.mcpServerGroup.servers.first?.id }
        }
    }

    var list: some View {
        VStack(spacing: 2) {
            ForEach(filtered) { server in
                MCPServerRow(server: server, selected: selection == server.id)
                    .onTapGesture { selection = server.id }
                    .contextMenu {
                        Button("Edit…") { editing = EditorTarget(server: server.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { MCPServerActions.delete(server.id) }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(RX.Space.s2)
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .fill(Color.rxSurface.opacity(0.4))
        )
    }
}

private struct MCPServerRow: View {
    let server: RDMCPServer
    let selected: Bool

    @ObservedObject private var center = MCPClientCenter.shared
    @State private var hovered = false

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(server.authKind)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RX.Space.s3)
        .padding(.vertical, RX.Space.s2)
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                .fill(selected ? Color.rxRowSelected : (hovered ? Color.rxRowHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(server.endpoint)
    }

    private var statusColor: Color {
        switch center.state(server.id) {
        case .idle: return Color.rxInkSecondary.opacity(0.5)
        case .connecting: return .rxWarning
        case .ready: return .rxSuccess
        case .failed: return .rxDanger
        }
    }
}

private struct MCPServerDetail: View {
    let server: RDMCPServer.ID
    let edit: (RDMCPServer.ID) -> Void

    @EnvironmentObject var store: TamioStore
    @ObservedObject private var center = MCPClientCenter.shared
    @State private var calling: MCPTool?

    var value: RDMCPServer { store.mcpServerGroup[server] }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s4) {
            HStack(alignment: .top, spacing: RX.Space.s3) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.displayName)
                        .font(.rxSheetTitle)
                        .foregroundStyle(.rxInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value.endpoint)
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Edit…") { edit(server) }
                    .buttonStyle(.rx)
                Menu {
                    Button("Delete…", role: .destructive) { MCPServerActions.delete(server) }
                } label: {
                    Label("More", rx: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.rx(.plain, iconOnly: true))
                .fixedSize()
            }
            HStack(alignment: .center, spacing: RX.Space.s2) {
                Text(value.authKind)
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
                if case let .oauth(oauth) = value.auth {
                    Text(oauth.isSignedIn ? "Signed in" : "Not signed in")
                        .font(.rxHelp)
                        .foregroundStyle(oauth.isSignedIn ? Color.rxSuccess : Color.rxInkSecondary)
                }
                Spacer(minLength: 0)
                connectionControl
            }
            if case let .failed(message) = center.state(server) {
                HelpText(message, isError: true)
            }
            if !value.comment.isEmpty {
                Text(value.comment)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Tools")
                .font(.rxSectionTitle)
                .foregroundStyle(.rxInk)
            if center.toolList(server).isEmpty {
                EmptyStateView("Connect to load tools", systemImage: "wrench.and.screwdriver")
                    .rxCard()
            } else {
                VStack(alignment: .leading, spacing: RX.Space.s2) {
                    ForEach(center.toolList(server)) { tool in
                        HStack(alignment: .top, spacing: RX.Space.s3) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.name)
                                    .font(.rxBodyStrong)
                                    .foregroundStyle(.rxInk)
                                if let description = tool.description, !description.isEmpty {
                                    Text(description)
                                        .font(.rxHelp)
                                        .foregroundStyle(.rxInkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            Button("Call") { calling = tool }
                                .buttonStyle(.rx(size: .small))
                                .disabled(!center.isConnected(server))
                        }
                        .padding(RX.Space.s3)
                        .background(
                            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                                .fill(Color.rxPill)
                        )
                    }
                }
            }
        }
        .padding(RX.Space.s5)
        .rxCard()
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $calling) { tool in
            MCPToolCallSheet(server: value, tool: tool) { arguments in
                try await center.callTool(server: value, name: tool.name, arguments: arguments)
            }
        }
    }

    @ViewBuilder
    private var connectionControl: some View {
        switch center.state(server) {
        case .idle:
            Button("Connect") {
                Task { await center.connect(value) }
            }
            .buttonStyle(.rx)
        case .connecting:
            HStack(spacing: RX.Space.s2) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
            }
        case .ready:
            Button("Disconnect") {
                Task { await center.disconnect(server) }
            }
            .buttonStyle(.rx)
        case .failed:
            Button("Reconnect") {
                Task { await center.connect(value) }
            }
            .buttonStyle(.rx)
        }
    }
}

enum MCPServerActions {
    @MainActor
    static func delete(_ id: RDMCPServer.ID) {
        let store = TamioStore.shared
        let center = MCPClientCenter.shared
        let server = store.mcpServerGroup[id]
        Dialogs.requiresConfirmation(
            message: String(localized: "Delete \(server.displayName)?"),
            informative: String(localized: "Its token or OAuth session is removed from this Mac."),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            Task { await center.disconnect(id) }
            store.mcpServerGroup.delete(id)
        }
    }
}
