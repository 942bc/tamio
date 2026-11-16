//
//  LocalTerminalTabBar.swift
//  Tamio (macOS)
//
//  The shells on this Mac: one tab each, with + to open another and × to
//  close one. The page owns the terminal; the bar only changes the route.
//

import AppKit
import SwiftUI
import TamioDesign

struct LocalTerminalTabBar: View {
    let activeID: UUID

    @ObservedObject private var terminals = TerminalManager.shared
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var contexts: [TerminalManager.Context] {
        terminals.sessionContexts.filter { $0.remoteType == .local }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(contexts.enumerated()), id: \.element.id) { index, context in
                        LocalTerminalTab(
                            context: context,
                            index: index,
                            total: contexts.count,
                            selected: context.id == activeID,
                            select: { router.route = .terminal(context.id) },
                            close: { router.closeLocalTerminal(context.id) },
                            newShell: { router.openLocalTerminal() },
                            closeOthers: {
                                for other in contexts where other.id != context.id {
                                    terminals.closeSession(withContextID: other.id)
                                }
                                router.route = .terminal(context.id)
                            }
                        )
                    }
                }
                .padding(2)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(RXPalette.tabTrack)
            )
            .fixedSize(horizontal: false, vertical: true)
            Button {
                router.openLocalTerminal()
            } label: {
                Image(rx: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "New Shell"))
            .accessibilityLabel(String(localized: "New Shell"))
            .padding(.leading, 6)
        }
        .frame(height: 30)
        .animation(reduceMotion ? nil : .rxQuick, value: contexts.map(\.id))
    }
}

private struct LocalTerminalTab: View {
    @ObservedObject var context: TerminalManager.Context
    let index: Int
    let total: Int
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    let newShell: () -> Void
    let closeOthers: () -> Void

    @State private var hovered = false
    @State private var renaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var defaultTitle: String {
        total == 1
            ? String(localized: "This Mac")
            : String(localized: "This Mac \(index + 1)")
    }

    private var title: String {
        if let custom = context.customTitle, !custom.isEmpty { return custom }
        return defaultTitle
    }

    var body: some View {
        HStack(spacing: 4) {
            if renaming {
                TextField("Tab Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
                    .frame(width: 92)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, renaming { commitRename() }
                    }
            } else {
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
                    .fixedSize()
            }
            if selected || hovered {
                Button(action: close) {
                    Image(rx: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.rxInkSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close Shell"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? RXPalette.tabSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .highPriorityGesture(
            TapGesture(count: 2).onEnded { beginRename() }
        )
        .onHover { hovered = $0 }
        .help(context.navigationSubtitle.isEmpty ? title : context.navigationSubtitle)
        .contextMenu {
            Button("New Shell", action: newShell)
            Button("Rename Tab…", action: beginRename)
            Button("Close Shell", action: close)
            if total > 1 {
                Divider()
                Button("Close Other Shells", action: closeOthers)
            }
        }
        .overlay {
            MiddleClickClose(action: close)
        }
    }

    private func beginRename() {
        renameText = context.customTitle ?? defaultTitle
        renaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        context.customTitle = trimmed.isEmpty ? nil : trimmed
        renaming = false
        renameFocused = false
    }

    private func cancelRename() {
        renaming = false
        renameFocused = false
    }
}

/// A transparent layer over a tab that only answers the middle mouse button:
/// left clicks pass through to the tab's SwiftUI gesture.
private struct MiddleClickClose: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context _: Context) -> MiddleClickNSView {
        MiddleClickNSView(action: action)
    }

    func updateNSView(_ view: MiddleClickNSView, context _: Context) {
        view.action = action
    }
}

@MainActor
private final class MiddleClickNSView: NSView {
    var action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        if event.type == .otherMouseDown || event.type == .otherMouseUp {
            return super.hitTest(point)
        }
        return nil
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            action()
        } else {
            super.otherMouseDown(with: event)
        }
    }
}
