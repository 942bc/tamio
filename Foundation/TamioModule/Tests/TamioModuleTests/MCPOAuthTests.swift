//
//  MCPOAuthTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import CryptoKit
import XCTest

final class MCPOAuthTests: XCTestCase {
    func testResourceMetadataURLFromChallenge() {
        let header = #"Bearer resource_metadata="https://example.com/.well-known/oauth-protected-resource", error="invalid_token""#
        XCTAssertEqual(
            MCPOAuthChallenge.resourceMetadataURL(from: header, base: URL(string: "https://example.com/sse")!),
            URL(string: "https://example.com/.well-known/oauth-protected-resource")
        )
    }

    func testFallbackResourceMetadataURL() {
        XCTAssertEqual(
            MCPOAuthChallenge.resourceMetadataURL(from: nil, base: URL(string: "https://example.com/sse")!),
            URL(string: "https://example.com/.well-known/oauth-protected-resource")
        )
    }

    func testResourceMetadataDecodes() throws {
        let data = Data(#"{"resource":"https://example.com","authorization_servers":["https://auth.example.com"],"scopes_supported":["read","write"]}"#.utf8)
        let metadata = try JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: data)
        XCTAssertEqual(metadata.authorizationServers, ["https://auth.example.com"])
        XCTAssertEqual(metadata.scopesSupported, ["read", "write"])
    }

    func testAuthorizationServerMetadataDecodes() throws {
        let data = Data(#"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register","scopes_supported":["read"]}"#.utf8)
        let metadata = try JSONDecoder().decode(MCPAuthorizationServerMetadata.self, from: data)
        XCTAssertEqual(metadata.tokenEndpoint, "https://auth.example.com/token")
        XCTAssertEqual(metadata.registrationEndpoint, "https://auth.example.com/register")
    }

    func testPKCEChallengeIsS256OfVerifier() {
        let pkce = MCPPKCE(verifier: "the-verifier")
        let expected = Data(SHA256.hash(data: Data("the-verifier".utf8))).base64URLEncodedString()
        XCTAssertEqual(pkce.challenge, expected)
    }

    func testAuthorizationURLCarriesPKCEAndState() throws {
        var oauth = MCPServerOAuth()
        oauth.clientID = "client"
        oauth.authorizationEndpoint = "https://auth.example.com/authorize"
        oauth.scopes = ["read"]
        let url = try MCPOAuth.authorizationURL(
            oauth: oauth,
            redirectURI: "sb.moe.tamio:/oauth/mcp",
            pkce: MCPPKCE(verifier: "verifier"),
            state: "state"
        )
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "state" }?.value, "state")
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, "client")
    }

    func testRegistrationBody() throws {
        let body = try MCPOAuth.registrationBody(redirectURI: "sb.moe.tamio:/oauth/mcp")
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["redirect_uris"]?.strings, ["sb.moe.tamio:/oauth/mcp"])
        XCTAssertEqual(json["token_endpoint_auth_method"]?.string, "none")
    }

    func testTokenResponseParsing() {
        let tokens = MCPOAuth.tokens(from: .object([
            "access_token": .string("a"),
            "refresh_token": .string("r"),
            "expires_in": .number(3600),
        ]))
        XCTAssertEqual(tokens.accessToken, "a")
        XCTAssertEqual(tokens.refreshToken, "r")
        XCTAssertNotNil(tokens.expiresAt)
    }

    func testRegistrationBodyCarriesScopeAndAuthMethod() throws {
        let body = try MCPOAuth.registrationBody(
            redirectURI: "sb.moe.tamio:/oauth/mcp",
            scopes: ["read", "write"],
            tokenAuthMethod: "client_secret_basic"
        )
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["scope"]?.string, "read write")
        XCTAssertEqual(json["token_endpoint_auth_method"]?.string, "client_secret_basic")
    }

    func testBasicTokenRequestUsesAuthorizationHeader() {
        var oauth = MCPServerOAuth()
        oauth.clientID = "client"
        oauth.clientSecret = "secret"
        oauth.refreshToken = "refresh"
        oauth.tokenAuthMethod = "client_secret_basic"
        let request = MCPOAuth.refreshRequest(oauth: oauth)
        XCTAssertTrue(request.authorization?.hasPrefix("Basic ") == true)
        let body = String(data: request.body, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("client_secret"))
        XCTAssertTrue(body.contains("client_id=client"))
    }

    func testPostTokenRequestKeepsSecretInBody() {
        var oauth = MCPServerOAuth()
        oauth.clientID = "client"
        oauth.clientSecret = "secret"
        oauth.refreshToken = "refresh"
        oauth.tokenAuthMethod = "client_secret_post"
        let request = MCPOAuth.refreshRequest(oauth: oauth)
        XCTAssertNil(request.authorization)
        let body = String(data: request.body, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("client_secret=secret"))
        XCTAssertTrue(body.contains("client_id=client"))
    }
}
