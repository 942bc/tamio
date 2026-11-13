import AppKit
import SwiftUI
import TamioDesign
import TamioModule

/// Everything sent to and received from MCP servers, in the order it
/// happened. Kept in memory by MCPDebugLog; nothing is written to disk.
struct MCPDebugLogSheet: View {
    @ObservedObject private var log = MCPDebugLog.shared
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""
    @State private var follow = true

    private var filtered: [MCPDebugLog.Entry] {
        guard !filter.isEmpty else { return log.entries }
        let key = filter.lowercased()
        return log.entries.filter {
            $0.server.lowercased().contains(key) || $0.text.lowercased().contains(key)
        }
    }

    var body: some View {
        SheetScaffold("MCP Debug Log") {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                HStack(spacing: RX.Space.s3) {
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.rx)
                    Toggle("Follow", isOn: $follow)
                        .toggleStyle(.checkbox)
                }
                if filtered.isEmpty {
                    EmptyStateView("No MCP traffic yet.", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: RX.Space.s3) {
                                ForEach(filtered) { entry in
                                    entryView(entry)
                                        .id(entry.id)
                                }
                            }
                            .padding(.vertical, RX.Space.s1)
                        }
                        .onChange(of: log.entries.count) { _, _ in
                            guard follow, let last = filtered.last else { return }
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        } footer: {
            Button("Clear") { log.clear() }
                .buttonStyle(.rx)
            Spacer()
            Button("Copy") { copyAll() }
                .buttonStyle(.rx)
                .disabled(log.entries.isEmpty)
            Button("Close") { dismiss() }
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 820, height: 600)
    }

    private func entryView(_ entry: MCPDebugLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: RX.Space.s2) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.rxAxis)
                    .foregroundStyle(.rxInkTertiary)
                Text(entry.direction.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(directionColor(entry.direction))
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

    private func copyAll() {
        let text = log.entries.map { entry in
            "\(entry.date.formatted(.dateTime.hour().minute().second())) \(entry.direction.rawValue) \(entry.server)\n\(entry.text)"
        }
        .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
