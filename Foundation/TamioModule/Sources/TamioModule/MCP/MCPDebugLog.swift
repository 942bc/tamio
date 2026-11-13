//
//  MCPDebugLog.swift
//  TamioModule
//
//  What Tamio sent to and received from MCP servers, kept in memory so the
//  user can watch a connection while debugging. It is not written to disk.
//

import Combine
import Foundation

@MainActor
public final class MCPDebugLog: ObservableObject {
    public static let shared = MCPDebugLog()

    public enum Direction: String, Sendable {
        case outbound = "→"
        case inbound = "←"
        case info = "·"
        case error = "!"

        public var label: String {
            switch self {
            case .outbound: return String(localized: "SEND")
            case .inbound: return String(localized: "RECV")
            case .info: return String(localized: "INFO")
            case .error: return String(localized: "ERROR")
            }
        }
    }

    public enum Channel: String, Sendable {
        case http = "HTTP"
        case sse = "SSE"
        case oauth = "OAuth"
        case app = "APP"
    }

    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let server: String
        public let direction: Direction
        public let channel: Channel
        public let text: String
    }

    @Published public private(set) var entries: [Entry] = []

    public static let limit = 500
    private static let textLimit = 20_000

    private init() {}

    public func record(
        server: String,
        direction: Direction,
        text: String,
        channel: Channel = .app
    ) {
        let formatted = Self.format(text)
        let clipped = formatted.count > Self.textLimit ? String(formatted.prefix(Self.textLimit)) + "\n…" : formatted
        entries.append(Entry(
            id: UUID(),
            date: Date(),
            server: server,
            direction: direction,
            channel: channel,
            text: clipped
        ))
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    public func clear() {
        entries.removeAll()
    }

    /// Pretty JSON for reading, or the text as it is when it is not JSON
    /// (URLs, error messages, SSE endpoints).
    public static func format(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(json),
              let pretty = String(data: encoded, encoding: .utf8)
        else { return text }
        return pretty
    }
}
