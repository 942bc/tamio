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
        if oauth.registrationEndpoint.isEmpty, let registration = metadata.registrationEndpoint {
            oauth.registrationEndpoint = registration
        }
        if oauth.issuer == nil, !metadata.issuer.isEmpty { oauth.issuer = metadata.issuer }
        if oauth.scopes.isEmpty, let scopes = metadata.scopesSupported { oauth.scopes = scopes }
        if oauth.clientID.isEmpty, !oauth.registrationEndpoint.isEmpty {
            let method = registrationMethod(metadata: metadata, oauth: oauth)
            log("Registering client · \(method)")
            let registered = try await registerClient(oauth: oauth, tokenAuthMethod: method)
            oauth.clientID = registered.clientID
            oauth.clientSecret = registered.clientSecret
            oauth.tokenAuthMethod = registered.tokenAuthMethod
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
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value
            throw MCPClientError.transport(description ?? error)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else {
            throw MCPClientError.transport(String(localized: "The sign-in page did not return a code."))
        }
        if let iss = items.first(where: { $0.name == "iss" })?.value,
           let expected = oauth.issuer, !expected.isEmpty,
           normalized(iss) != normalized(expected)
        {
            throw MCPClientError.transport(String(localized: "The sign-in response came from another issuer."))
        }
        let request = MCPOAuth.codeRequest(
            code: code,
            oauth: oauth,
            pkce: pkce,
            redirectURI: MCPOAuth.redirectURI
        )
        let tokens = try await exchange(request: request, tokenEndpoint: oauth.tokenEndpoint)
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
        let request = MCPOAuth.refreshRequest(oauth: oauth)
        let tokens = try await exchange(request: request, tokenEndpoint: oauth.tokenEndpoint)
        apply(tokens: tokens, to: &oauth)
        return oauth
    }

    private static func registrationMethod(
        metadata: MCPAuthorizationServerMetadata,
        oauth: MCPServerOAuth
    ) -> String {
        if let chosen = oauth.tokenAuthMethod, !chosen.isEmpty { return chosen }
        let supported = metadata.tokenEndpointAuthMethodsSupported ?? []
        if supported.isEmpty {
            return oauth.clientSecret.isEmpty ? "none" : "client_secret_post"
        }
        if supported.contains("none") { return "none" }
        if supported.contains("client_secret_basic") { return "client_secret_basic" }
        if supported.contains("client_secret_post") { return "client_secret_post" }
        return supported[0]
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
                issuer: oauth.issuer ?? "",
                authorizationEndpoint: oauth.authorizationEndpoint,
                tokenEndpoint: oauth.tokenEndpoint,
                registrationEndpoint: oauth.registrationEndpoint.isEmpty ? nil : oauth.registrationEndpoint
            )
        }
        guard let base = URL(string: endpoint) else { throw MCPClientError.invalidEndpoint(endpoint) }
        guard let resourceURL = MCPOAuthChallenge.resourceMetadataURL(from: challenge, base: base) else {
            throw MCPClientError.invalidEndpoint(endpoint)
        }
        log("GET \(resourceURL.absoluteString)")
        let resource = try await get(resourceURL, as: MCPProtectedResourceMetadata.self)
        log("Resource metadata \(jsonString(resource))")
        if oauth.scopes.isEmpty { oauth.scopes = resource.scopesSupported ?? [] }
        if oauth.resource.isEmpty { oauth.resource = resource.resource }
        guard let issuer = resource.authorizationServers.first.flatMap(URL.init(string:)) else {
            throw MCPClientError.transport(String(localized: "The server did not name an authorization server."))
        }
        let metadata = try await authorizationMetadata(issuer: issuer)
        if oauth.issuer == nil, !metadata.issuer.isEmpty { oauth.issuer = metadata.issuer }
        if oauth.scopes.isEmpty, let scopes = metadata.scopesSupported { oauth.scopes = scopes }
        return metadata
    }

    private static func authorizationMetadata(issuer: URL) async throws -> MCPAuthorizationServerMetadata {
        var lastError: Error = MCPClientError.transport(
            String(localized: "The authorization server's metadata could not be read.")
        )
        for url in wellKnownURLs(issuer: issuer) {
            log("GET \(url.absoluteString)")
            do {
                let metadata = try await get(url, as: MCPAuthorizationServerMetadata.self)
                log("Authorization metadata \(jsonString(metadata))")
                if !metadata.issuer.isEmpty,
                   normalized(metadata.issuer) != normalized(issuer.absoluteString)
                {
                    throw MCPClientError.transport(
                        String(localized: "The authorization server named a different issuer.")
                    )
                }
                return metadata
            } catch {
                log("Metadata \(url.absoluteString) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    /// RFC 8414 and OIDC discovery locations for an issuer, including an
    /// issuer that lives under a path.
    private static func wellKnownURLs(issuer: URL) -> [URL] {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path == "/" ? "" : components.path
        components.query = nil
        components.fragment = nil
        var urls: [URL] = []
        components.path = "/.well-known/oauth-authorization-server" + path
        if let url = components.url { urls.append(url) }
        components.path = path + "/.well-known/openid-configuration"
        if let url = components.url, !urls.contains(url) { urls.append(url) }
        return urls
    }

    private static func normalized(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private static func registerClient(
        oauth: MCPServerOAuth,
        tokenAuthMethod: String
    ) async throws -> (clientID: String, clientSecret: String, tokenAuthMethod: String) {
        guard let url = URL(string: oauth.registrationEndpoint) else {
            throw MCPClientError.invalidEndpoint(oauth.registrationEndpoint)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MCPOAuth.registrationBody(
            redirectURI: MCPOAuth.redirectURI,
            scopes: oauth.scopes,
            tokenAuthMethod: tokenAuthMethod
        )
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
        return (
            clientID,
            json["client_secret"]?.string ?? "",
            json["token_endpoint_auth_method"]?.string ?? tokenAuthMethod
        )
    }

    private static func exchange(
        request tokenRequest: MCPOAuth.TokenRequest,
        tokenEndpoint: String
    ) async throws -> (accessToken: String, refreshToken: String, expiresAt: Date?) {
        guard let url = URL(string: tokenEndpoint) else {
            throw MCPClientError.invalidEndpoint(tokenEndpoint)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = tokenRequest.body
        if let authorization = tokenRequest.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        log("POST \(url.absoluteString)")
        if let authorization = tokenRequest.authorization {
            log("Authorization: \(authorization)")
        }
        if let text = String(data: tokenRequest.body, encoding: .utf8) {
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
