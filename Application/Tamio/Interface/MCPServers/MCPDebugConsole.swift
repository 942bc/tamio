import AppKit
import SwiftUI
import TamioDesign
import TamioModule

/// The MCP traffic, pinned to the bottom of MCP Servers: every request,
/// response, SSE event and OAuth step, live. Kept in memory by MCPDebugLog;
/// nothing is written to disk.
struct MCPDebugConsole: View {
    @ObservedObject private var log = MCPDebugLog.shared

    @State private var filter = ""
    @State private var follow = true
    @State private var expanded = true

    private var filtered: [MCPDebugLog.Entry] {
        guard !filter.isEmpty else { return log.entries }
        let key = filter.lowercased()
        return log.entries.filter {
            $0.server.lowercased().contains(key) || $0.text.lowercased().contains(key)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.rxHairline)
                .frame(height: 1)
            header
            if expanded {
                list
                    .frame(height: 170)
            }
        }
        .background(Color.rxSurface)
    }

    private var header: some View {
        HStack(spacing: RX.Space.s2) {
            Label("Console", rx: "doc.text")
                .font(.rxBodyStrong)
                .foregroundStyle(.rxInk)
            Text("\(log.entries.count)")
                .font(.rxAxis)
                .foregroundStyle(.rxInkSecondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.rx)
                .frame(maxWidth: 240)
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
                .font(.rxHelp)
            Spacer(minLength: RX.Space.s2)
            Button("Clear") { log.clear() }
                .buttonStyle(.rx(size: .small))
            Button("Copy") { copyAll() }
                .buttonStyle(.rx(size: .small))
                .disabled(log.entries.isEmpty)
            Button {
                expanded.toggle()
            } label: {
                Image(rx: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.rxInkSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(expanded ? "Collapse Console" : "Expand Console"))
            .accessibilityLabel(Text(expanded ? "Collapse Console" : "Expand Console"))
        }
        .padding(.horizontal, RX.Space.s6)
        .padding(.vertical, RX.Space.s2)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RX.Space.s2) {
                    if filtered.isEmpty {
                        Text("No MCP traffic yet.")
                            .font(.rxHelp)
                            .foregroundStyle(.rxInkSecondary)
                            .padding(RX.Space.s3)
                    } else {
                        ForEach(filtered) { entry in
                            entryView(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, RX.Space.s6)
                .padding(.bottom, RX.Space.s2)
            }
            .onChange(of: log.entries.count) { _, _ in
                guard follow, let last = filtered.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func entryView(_ entry: MCPDebugLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: RX.Space.s2) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.rxAxis)
                    .foregroundStyle(.rxInkTertiary)
                Text("\(entry.direction.rawValue) \(entry.direction.label)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(directionColor(entry.direction))
                Text(entry.channel.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(channelColor(entry.channel))
                Text(entry.server)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.text)
                .font(.rxCode)
                .foregroundStyle(.rxInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RX.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                .fill(Color.rxSurfaceSunken)
        )
    }

    private func directionColor(_ direction: MCPDebugLog.Direction) -> Color {
        switch direction {
        case .outbound: return .rxAccentSolid
        case .inbound: return .rxSuccess
        case .info: return .rxInkSecondary
        case .error: return .rxDanger
        }
    }

    private func channelColor(_ channel: MCPDebugLog.Channel) -> Color {
        switch channel {
        case .http: return .rxAccentSolid
        case .sse: return .rxSuccess
        case .oauth: return .rxWarning
        case .app: return .rxInkSecondary
        }
    }

    private func copyAll() {
        let text = log.entries.map { entry in
            "\(entry.date.formatted(.dateTime.hour().minute().second())) [\(entry.channel.rawValue)] \(entry.direction.rawValue) \(entry.direction.label) \(entry.server)\n\(entry.text)"
        }
        .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
