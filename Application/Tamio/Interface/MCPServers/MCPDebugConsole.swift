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
    @State private var channelFilter: MCPDebugLog.Channel?
    @State private var directionFilter: MCPDebugLog.Direction?
    @State private var follow = true
    @State private var expanded = true
    @AppStorage("sb.moe.tamio.mcpConsoleHeight") private var consoleHeight: Double = 170
    @State private var dragStart: CGFloat?
    @State private var handleHovered = false
    @State private var cursorPushed = false

    private var filtered: [MCPDebugLog.Entry] {
        var result = log.entries
        if let channelFilter {
            result = result.filter { $0.channel == channelFilter }
        }
        if let directionFilter {
            result = result.filter { $0.direction == directionFilter }
        }
        guard !filter.isEmpty else { return result }
        let key = filter.lowercased()
        return result.filter {
            $0.server.lowercased().contains(key) || $0.text.lowercased().contains(key)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            if expanded {
                list
                    .frame(height: CGFloat(consoleHeight))
            }
        }
        .background(Color.rxSurface)
    }

    /// The top edge: drag it up or down to give the log more or less room.
    private var dragHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.rxHairline)
                .frame(height: 1)
            Capsule()
                .fill(Color.rxInkSecondary.opacity(handleHovered ? 0.6 : 0.35))
                .frame(width: 36, height: 4)
                .animation(.rxQuick, value: handleHovered)
        }
        .frame(height: 9)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            handleHovered = inside
            if inside, !cursorPushed {
                NSCursor.resizeUpDown.push()
                cursorPushed = true
            } else if !inside, cursorPushed, dragStart == nil {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = CGFloat(consoleHeight)
                        if !cursorPushed {
                            NSCursor.resizeUpDown.push()
                            cursorPushed = true
                        }
                    }
                    let start = dragStart ?? CGFloat(consoleHeight)
                    consoleHeight = Double(min(max(start - value.translation.height, 100), 620))
                }
                .onEnded { _ in
                    dragStart = nil
                    if !handleHovered, cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                }
        )
        .help(Text("Drag to resize the console"))
        .accessibilityLabel(Text("Resize Console"))
    }

    private var header: some View {
        HStack(spacing: RX.Space.s2) {
            Label("Console", rx: "doc.text")
                .font(.rxBodyStrong)
                .foregroundStyle(.rxInk)
            Text("\(log.entries.count)")
                .font(.rxAxis)
                .foregroundStyle(.rxInkSecondary)
            Picker("", selection: $channelFilter) {
                Text("All").tag(MCPDebugLog.Channel?.none)
                ForEach(MCPDebugLog.Channel.allCases, id: \.self) { channel in
                    Text(channel.rawValue).tag(Optional(channel))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 82)
            .help(Text("Filter by channel"))
            Picker("", selection: $directionFilter) {
                Text("All").tag(MCPDebugLog.Direction?.none)
                ForEach(MCPDebugLog.Direction.allCases, id: \.self) { direction in
                    Text(direction.label).tag(Optional(direction))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 92)
            .help(Text("Filter by direction"))
            TextField("Filter", text: $filter)
                .textFieldStyle(.rx)
                .frame(maxWidth: 180)
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
                                .contextMenu {
                                    Button("Copy Entry") { copy(entry) }
                                }
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
                Text(entry.date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
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
        let text = log.entries.map(line).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copy(_ entry: MCPDebugLog.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line(entry), forType: .string)
    }

    private func line(_ entry: MCPDebugLog.Entry) -> String {
        let time = entry.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
        return "\(time) [\(entry.channel.rawValue)] \(entry.direction.rawValue) \(entry.direction.label) \(entry.server)\n\(entry.text)"
    }
}
