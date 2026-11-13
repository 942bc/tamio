import Foundation
import TamioModule

/// Discovery, registration, the browser step and token exchange for one
/// server. Returns an updated `MCPServerOAuth`; the caller stores it.
@MainActor
enum MCPOAuthCoordinator {
    static func signIn(endpoint: String, oauth: MCPServerOAuth, challenge: String? = nil) async throws -> MCPServerOAuth {
        guard URL(string: endpoint) != nil else {
            throw MCPClientError.invalidEndpoint(endpoint)
        }
        log("Sign in · \(endpoint)")
        var oauth = oauth
        let metadata = try await discover(endpoint: endpoint, oauth: &oauth, challenge: challenge)
        if oauth.authorizationEndpoint.isEmpty { oauth.authorizationEndpoint = metadata.authorizationEndpoint }
        if oauth.tokenEndpoint.isEmpty { oauth.tokenEndpoint = metadata.tokenEndpoint }
        if oauth.registrationEndpoint.isEmpty { oauth.registrationEndpoint = metadata.registrationEndpoint }
        if oauth.clientID.isEmpty, !oauth.registrationEndpoint.isEmpty {
            let registered = try await registerClient(oauth: oauth)
            oauth.clientID = registered.clientID
            oauth.clientSecret = registered.clientSecret
        }
        guard !oauth.authorizationEndpoint.isEmpty,
              !oauth.tokenEndpoint.isEmpty,
              !oauth.clientID.isEmpty
        else {
            throw MCPClientError.transport(String(localized: "Fill in the OAuth endpoints and client ID."))
        }

        let pkce = MCPPKCE()
        let state = UUID().uuidString
        let url = try MCPOAuth.authorizationURL(
            oauth: oauth,
            redirectURI: MCPOAuth.redirectURI,
            pkce: pkce,
            state: state
        )
        log("Open \(url.absoluteString)")
        let callback = try await MCPOAuthPresenter.shared.authorize(url, callbackScheme: MCPOAuth.callbackScheme)
        log("Callback \(callback.absoluteString)")
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else {
            throw MCPClientError.transport(String(localized: "The sign-in page did not return a code."))
        }
        let tokens = try await exchange(
            body: MCPOAuth.codeRequestBody(code: code, oauth: oauth, pkce: pkce, redirectURI: MCPOAuth.redirectURI),
            tokenEndpoint: oauth.tokenEndpoint
        )
        apply(tokens: tokens, to: &oauth)
        log("Signed in · expires \(oauth.expiresAt?.description ?? "never")")
        return oauth
    }

    static func refresh(_ oauth: MCPServerOAuth) async throws -> MCPServerOAuth {
        guard !oauth.refreshToken.isEmpty, !oauth.tokenEndpoint.isEmpty else {
            throw MCPClientError.transport(String(localized: "Sign in again."))
        }
        var oauth = oauth
        log("Refresh token · \(oauth.tokenEndpoint)")
        let tokens = try await exchange(body: MCPOAuth.refreshBody(oauth: oauth), tokenEndpoint: oauth.tokenEndpoint)
        apply(tokens: tokens, to: &oauth)
        return oauth
    }

    private static func apply(
        tokens: (accessToken: String, refreshToken: String, expiresAt: Date?),
        to oauth: inout MCPServerOAuth
    ) {
        if !tokens.accessToken.isEmpty { oauth.accessToken = tokens.accessToken }
        if !tokens.refreshToken.isEmpty { oauth.refreshToken = tokens.refreshToken }
        oauth.expiresAt = tokens.expiresAt
    }

    private static func discover(
        endpoint: String,
        oauth: inout MCPServerOAuth,
        challenge: String?
    ) async throws -> MCPAuthorizationServerMetadata {
        if !oauth.authorizationEndpoint.isEmpty, !oauth.tokenEndpoint.isEmpty {
            return MCPAuthorizationServerMetadata(
                authorizationEndpoint: oauth.authorizationEndpoint,
                tokenEndpoint: oauth.tokenEndpoint,
                registrationEndpoint: oauth.registrationEndpoint
            )
        }
        guard let base = URL(string: endpoint) else { throw MCPClientError.invalidEndpoint(endpoint) }
        guard let resourceURL = MCPOAuthChallenge.resourceMetadataURL(from: challenge, base: base) else {
            throw MCPClientError.invalidEndpoint(endpoint)
        }
        log("GET \(resourceURL.absoluteString)")
        let resource = try await get(resourceURL, as: MCPProtectedResourceMetadata.self)
        log("Resource metadata \(jsonString(resource))")
        guard let issuer = resource.authorizationServers.first.flatMap(URL.init(string:)) else {
            throw MCPClientError.transport(String(localized: "The server did not name an authorization server."))
        }
        if oauth.scopes.isEmpty { oauth.scopes = resource.scopesSupported }
        if oauth.resource.isEmpty { oauth.resource = resource.resource }
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else {
            throw MCPClientError.invalidEndpoint(issuer.absoluteString)
        }
        components.path = "/.well-known/oauth-authorization-server"
        components.query = nil
        components.fragment = nil
        guard let metadataURL = components.url else {
            throw MCPClientError.transport(String(localized: "The authorization server's address is not valid."))
        }
        log("GET \(metadataURL.absoluteString)")
        let metadata = try await get(metadataURL, as: MCPAuthorizationServerMetadata.self)
        log("Authorization metadata \(jsonString(metadata))")
        return metadata
    }

    private static func registerClient(oauth: MCPServerOAuth) async throws -> (clientID: String, clientSecret: String) {
        guard let url = URL(string: oauth.registrationEndpoint) else {
            throw MCPClientError.invalidEndpoint(oauth.registrationEndpoint)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MCPOAuth.registrationBody(redirectURI: MCPOAuth.redirectURI)
        log("POST \(url.absoluteString)")
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
            log(text)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            log("Response \(text)")
        }
        try check(response)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let clientID = json["client_id"]?.string, !clientID.isEmpty else {
            throw MCPClientError.transport(String(localized: "The authorization server did not register a client."))
        }
        return (clientID, json["client_secret"]?.string ?? "")
    }

    private static func exchange(
        body: Data,
        tokenEndpoint: String
    ) async throws -> (accessToken: String, refreshToken: String, expiresAt: Date?) {
        guard let url = URL(string: tokenEndpoint) else {
            throw MCPClientError.invalidEndpoint(tokenEndpoint)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        log("POST \(url.absoluteString)")
        if let text = String(data: body, encoding: .utf8) {
            log(text)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            log("Response \(text)")
        }
        try check(response)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return MCPOAuth.tokens(from: json)
    }

    private static func get<T: Decodable>(_ url: URL, as _: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw MCPClientError.http(http.statusCode)
        }
    }

    private static func log(_ text: String) {
        MCPDebugLog.shared.record(server: "OAuth", direction: .info, text: text, channel: .oauth)
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
