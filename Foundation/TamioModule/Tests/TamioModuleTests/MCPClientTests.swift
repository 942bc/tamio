//
//  MCPClientTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

final class MCPClientTests: XCTestCase {
    func testCallResultReadsTextAndError() {
        let json = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("hello")])]),
            "isError": .bool(true),
        ])
        let result = MCPCallResult(json: json)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.contents, [.text("hello")])
    }

    func testToolPageDecodesPagination() throws {
        let data = Data(#"{"tools":[{"name":"ping","description":"Ping","inputSchema":{"type":"object"}}],"nextCursor":"c2"}"#.utf8)
        let page = try JSONDecoder().decode(MCPToolPage.self, from: data)
        XCTAssertEqual(page.tools.map(\.name), ["ping"])
        XCTAssertEqual(page.nextCursor, "c2")
    }

    func testClientConnectsListsAndCalls() async throws {
        let transport = MockMCPTransport()
        let client = MCPClient(
            server: RDMCPServer(name: "Mock", endpoint: "https://example.com/sse"),
            transport: transport,
            headers: [:]
        )
        let info = try await client.connect()
        XCTAssertEqual(info.name, "mock")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["ping"])
        let result = try await client.callTool(name: "ping", arguments: .object([:]))
        XCTAssertEqual(result.contents, [.text("pong")])
    }
}

private final class MockMCPTransport: MCPTransport, @unchecked Sendable {
    let messages: AsyncThrowingStream<JSONValue, Error>
    private let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation

    init() {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        messages = stream
        self.continuation = continuation
    }

    func open(endpoint _: URL, headers _: [String: String]) async throws -> URL {
        URL(string: "https://example.com/messages")!
    }

    func post(_ body: Data, to _: URL, headers _: [String: String]) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: body)
        guard let id = message["id"]?.int else { return }
        switch message["method"]?.string {
        case "initialize":
            continuation.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "result": .object([
                    "protocolVersion": .string("2024-11-05"),
                    "serverInfo": .object(["name": .string("mock"), "version": .string("1")]),
                ]),
            ]))
        case "tools/list":
            continuation.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "result": .object([
                    "tools": .array([.object(["name": .string("ping"), "inputSchema": .object([:])])]),
                ]),
            ]))
        case "tools/call":
            continuation.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "result": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("pong")])]),
                ]),
            ]))
        default:
            break
        }
    }

    func close() async {
        continuation.finish()
    }
}
