//
//  MCPServerTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

final class MCPServerTests: XCTestCase {
    func testGroupInsertUpdateDelete() {
        var group = RDMCPServerGroup()
        var server = RDMCPServer(name: "Weather", endpoint: "https://example.com/sse")
        group.insert(server)
        XCTAssertEqual(group.servers, [server])
        server.comment = "Forecasts"
        group.insert(server)
        XCTAssertEqual(group.count, 1)
        XCTAssertEqual(group[server.id], server)
        group.delete(server.id)
        XCTAssertTrue(group.servers.isEmpty)
    }

    func testPlaceholderIsRefused() {
        var group = RDMCPServerGroup()
        group.insert(RDMCPServer())
        XCTAssertTrue(group.servers.isEmpty)
    }

    func testAuthRoundTripsThroughJSON() throws {
        var oauth = MCPServerOAuth()
        oauth.clientID = "client"
        oauth.accessToken = "access"
        oauth.refreshToken = "refresh"
        oauth.scopes = ["read"]
        oauth.expiresAt = Date(timeIntervalSince1970: 1_700_000_000)
        let values: [MCPAuth] = [
            .none,
            .bearer(token: "secret"),
            .headers([MCPHeader(name: "X-API-Key", value: "k")]),
            .oauth(oauth),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(MCPAuth.self, from: data), value)
        }
    }

    func testEncryptedRoundTrip() throws {
        var group = RDMCPServerGroup()
        group.insert(RDMCPServer(
            name: "Weather",
            endpoint: "https://example.com/sse",
            auth: .bearer(token: "t")
        ))
        let plain = try PropertyListEncoder().encode(group)
        let aes = try XCTUnwrap(AES(key: String(repeating: "k", count: 32), iv: "0123456789abcdef"))
        let sealed = try XCTUnwrap(aes.encrypt(data: plain))
        let opened = try XCTUnwrap(aes.decrypt(data: sealed))
        XCTAssertEqual(try PropertyListDecoder().decode(RDMCPServerGroup.self, from: opened), group)
    }
}
