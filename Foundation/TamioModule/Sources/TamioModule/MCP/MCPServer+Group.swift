//
//  MCPServer+Group.swift
//  TamioModule
//
//  Saved remote MCP servers, stored and edited like every other store group.
//

import Foundation

public struct RDMCPServerGroup: Codable, Identifiable, Equatable, RDGroup {
    public typealias AssociatedType = RDMCPServer

    public var id = UUID()
    public private(set) var servers: [AssociatedType] = []

    public var items: [RDMCPServer] {
        get { servers }
        set { servers = newValue }
    }

    public static func accepts(_ item: RDMCPServer) -> Bool {
        !item.isPlaceholder
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.servers == rhs.servers
    }
}
