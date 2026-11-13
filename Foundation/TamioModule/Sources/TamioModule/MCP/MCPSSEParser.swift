//
//  MCPSSEParser.swift
//  TamioModule
//
//  Server-sent events, one line at a time: event and data fields collected
//  until a blank line dispatches them.
//

import Foundation

public struct MCPSSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
}

public struct MCPSSEParser {
    private var event: String?
    private var data: [String] = []

    public init() {}

    public mutating func consume(line raw: String) -> MCPSSEEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            guard !data.isEmpty else {
                event = nil
                return nil
            }
            let event = MCPSSEEvent(event: event, data: data.joined(separator: "\n"))
            self.event = nil
            data.removeAll()
            return event
        }
        guard !line.hasPrefix(":") else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let field = String(line[..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}
