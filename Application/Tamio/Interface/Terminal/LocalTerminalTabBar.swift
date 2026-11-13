//
//  LocalTerminalTabBar.swift
//  Tamio (macOS)
//
//  The shells on this Mac: one tab each, with + to open another and × to
//  close one. The page owns the terminal; the bar only changes the route.
//

import SwiftUI
import TamioDesign

struct LocalTerminalTabBar: View {
    let activeID: UUID

    @ObservedObject private var terminals = TerminalManager.shared
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: UUID?

    private var contexts: [TerminalManager.Context] {
        terminals.sessionContexts.filter { $0.remoteType == .local }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(contexts.enumerated()), id: \.element.id) { index, context in
                        tab(context, index: index)
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

    private func tab(_ context: TerminalManager.Context, index: Int) -> some View {
        let selected = context.id == activeID
        return HStack(spacing: 4) {
            Text(title(for: context, index: index))
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
                .lineLimit(1)
            if selected || hovered == context.id {
                Button {
                    router.closeLocalTerminal(context.id)
                } label: {
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
        .onTapGesture { router.route = .terminal(context.id) }
        .onHover { inside in
            if inside {
                hovered = context.id
            } else if hovered == context.id {
                hovered = nil
            }
        }
        .help(context.navigationSubtitle.isEmpty
            ? title(for: context, index: index)
            : context.navigationSubtitle)
    }

    private func title(for context: TerminalManager.Context, index: Int) -> String {
        contexts.count == 1
            ? String(localized: "This Mac")
            : String(localized: "This Mac \(index + 1)")
    }
}
