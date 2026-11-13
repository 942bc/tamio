//
//  MCPModels.swift
//  TamioModule
//
//  What a connected MCP server gives Tamio: what it is, its tools, and what
//  calling one returned.
//

import Foundation

public struct MCPServerInfo: Codable, Equatable, Sendable {
    public init(name: String = "", version: String = "") {
        self.name = name
        self.version = version
    }

    public var name: String
    public var version: String
}

public struct MCPTool: Identifiable, Codable, Equatable, Sendable {
    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue = .object([:])
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: JSONValue

    public var id: String { name }
}

public enum MCPContent: Equatable, Sendable {
    case text(String)
    case image(mimeType: String, data: Data)
    case other(JSONValue)
}

public struct MCPCallResult: Equatable, Sendable {
    public init(contents: [MCPContent], isError: Bool, raw: JSONValue) {
        self.contents = contents
        self.isError = isError
        self.raw = raw
    }

    public init(json: JSONValue) {
        raw = json
        isError = json["isError"]?.bool ?? false
        contents = (json["content"]?.array ?? []).map { item in
            switch item["type"]?.string {
            case "text":
                return .text(item["text"]?.string ?? "")
            case "image":
                if let encoded = item["data"]?.string, let data = Data(base64Encoded: encoded) {
                    return .image(mimeType: item["mimeType"]?.string ?? "image/png", data: data)
                }
                return .other(item)
            default:
                return .other(item)
            }
        }
    }

    public var contents: [MCPContent]
    public var isError: Bool
    public var raw: JSONValue
}

public struct MCPToolPage: Decodable, Equatable, Sendable {
    public var tools: [MCPTool]
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case tools
        case nextCursor
    }
}

public enum MCPClientError: LocalizedError, Equatable {
    case notConnected
    case invalidEndpoint(String)
    case http(Int)
    case rpc(String)
    case timeout
    case unauthorized(String?)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to the MCP server.")
        case let .invalidEndpoint(value):
            return String(localized: "Not a valid URL: \(value)")
        case let .http(status):
            return String(localized: "The server answered HTTP \(status).")
        case let .rpc(message):
            return message
        case .timeout:
            return String(localized: "The MCP server did not answer in time.")
        case .unauthorized:
            return String(localized: "The MCP server wants you to sign in.")
        case let .transport(message):
            return message
        }
    }
}

public enum MCPClientState: Equatable, Sendable {
    case idle
    case connecting
    case ready(MCPServerInfo)
    case failed(String)
}
