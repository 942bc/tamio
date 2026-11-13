//
//  MCPServer.swift
//  TamioModule
//
//  A remote MCP server Tamio connects to as a client: where it is, how to
//  sign in, and what the user remembers about it. Kept encrypted with the
//  rest of the store, on this Mac only; its tokens do not go to Keychain.
//

import Foundation

public struct MCPHeader: Codable, Equatable, Sendable {
    public init(name: String = "", value: String = "") {
        self.name = name
        self.value = value
    }

    public var name: String
    public var value: String
}

public enum MCPAuth: Codable, Equatable, Sendable {
    case none
    case bearer(token: String)
    case headers([MCPHeader])
    case oauth(MCPServerOAuth)
}

public struct MCPServerOAuth: Codable, Equatable, Sendable {
    public init() {}

    public var clientID = ""
    public var clientSecret = ""
    public var scopes: [String] = []
    public var authorizationEndpoint = ""
    public var tokenEndpoint = ""
    public var registrationEndpoint = ""
    public var resource = ""
    public var accessToken = ""
    public var refreshToken = ""
    public var expiresAt: Date?

    public var isSignedIn: Bool { !accessToken.isEmpty || !refreshToken.isEmpty }
}

public struct RDMCPServer: Identifiable, Codable, Equatable, Sendable, RDGroupItem {
    public init() {}

    public init(
        id: UUID = .init(),
        name: String = "",
        endpoint: String = "",
        auth: MCPAuth = .none,
        comment: String = "",
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.auth = auth
        self.comment = comment
        self.lastConnected = lastConnected
    }

    public var id: UUID = .init()
    public var name: String = ""
    public var endpoint: String = ""
    public var auth: MCPAuth = .none
    public var comment: String = ""
    public var lastConnected: Date?

    public var isPlaceholder: Bool { name.isEmpty && endpoint.isEmpty }
    public var displayName: String { name.isEmpty ? endpoint : name }

    public var authKind: String {
        switch auth {
        case .none: return String(localized: "None")
        case .bearer: return String(localized: "Bearer Token")
        case .headers: return String(localized: "Custom Headers")
        case .oauth: return String(localized: "OAuth")
        }
    }
}
