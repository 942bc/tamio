//
//  MCPOAuth.swift
//  TamioModule
//
//  Discovery, PKCE, dynamic registration and token requests for the OAuth
//  flow a remote MCP server may ask for. The browser session lives in the
//  app; this file only builds and parses.
//

import CryptoKit
import Foundation

public struct MCPProtectedResourceMetadata: Codable, Equatable, Sendable {
    public var resource: String
    public var authorizationServers: [String]
    public var scopesSupported: [String]

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    public init(resource: String = "", authorizationServers: [String] = [], scopesSupported: [String] = []) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }
}

public struct MCPAuthorizationServerMetadata: Codable, Equatable, Sendable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var registrationEndpoint: String
    public var scopesSupported: [String]

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
    }

    public init(
        issuer: String = "",
        authorizationEndpoint: String = "",
        tokenEndpoint: String = "",
        registrationEndpoint: String = "",
        scopesSupported: [String] = []
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopesSupported = scopesSupported
    }
}

public enum MCPOAuthChallenge {
    /// The `resource_metadata` URL from a Bearer challenge, or the origin's
    /// well-known location when the server did not name one.
    public static func resourceMetadataURL(from header: String?, base: URL) -> URL? {
        if let header,
           let range = header.range(of: "resource_metadata=", options: .caseInsensitive)
        {
            var rest = header[range.upperBound...]
            if rest.hasPrefix("\"") { rest = rest.dropFirst() }
            if let end = rest.firstIndex(of: "\"") {
                let value = String(rest[..<end])
                return URL(string: value, relativeTo: base)?.absoluteURL
            }
            if let value = rest.split(whereSeparator: { $0 == " " || $0 == "," }).first {
                return URL(string: String(value), relativeTo: base)?.absoluteURL
            }
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/.well-known/oauth-protected-resource"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

public struct MCPPKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        self.init(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum MCPOAuth {
    public static let redirectURI = "sb.moe.tamio:/oauth/mcp"
    public static let callbackScheme = "sb.moe.tamio"

    public static func authorizationURL(
        oauth: MCPServerOAuth,
        redirectURI: String,
        pkce: MCPPKCE,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(string: oauth.authorizationEndpoint) else {
            throw MCPClientError.invalidEndpoint(oauth.authorizationEndpoint)
        }
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: oauth.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !oauth.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: oauth.scopes.joined(separator: " ")))
        }
        if !oauth.resource.isEmpty {
            items.append(URLQueryItem(name: "resource", value: oauth.resource))
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else {
            throw MCPClientError.invalidEndpoint(oauth.authorizationEndpoint)
        }
        return url
    }

    public static func registrationBody(redirectURI: String) throws -> Data {
        try JSONEncoder().encode(JSONValue.object([
            "client_name": .string("Tamio"),
            "redirect_uris": .array([.string(redirectURI)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ]))
    }

    public static func codeRequestBody(
        code: String,
        oauth: MCPServerOAuth,
        pkce: MCPPKCE,
        redirectURI: String
    ) -> Data {
        var items = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: oauth.clientID),
            URLQueryItem(name: "code_verifier", value: pkce.verifier),
        ]
        if !oauth.clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: oauth.clientSecret))
        }
        return formEncoded(items)
    }

    public static func refreshBody(oauth: MCPServerOAuth) -> Data {
        var items = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: oauth.refreshToken),
            URLQueryItem(name: "client_id", value: oauth.clientID),
        ]
        if !oauth.clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: oauth.clientSecret))
        }
        return formEncoded(items)
    }

    public static func tokens(from json: JSONValue) -> (accessToken: String, refreshToken: String, expiresAt: Date?) {
        let access = json["access_token"]?.string ?? ""
        let refresh = json["refresh_token"]?.string ?? ""
        let expires = json["expires_in"]?.int.map { Date().addingTimeInterval(TimeInterval($0)) }
        return (access, refresh, expires)
    }

    private static func formEncoded(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}
