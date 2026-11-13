//
//  MCPClient.swift
//  TamioModule
//
//  One connection to a remote MCP server: initialize, tools/list with
//  pagination, and tools/call. JSON-RPC responses come back over the SSE
//  stream and are matched to their requests by id.
//

import Foundation

public actor MCPClient {
    public private(set) var state: MCPClientState = .idle

    private let server: RDMCPServer
    private let transport: any MCPTransport
    private let headers: [String: String]
    private var postEndpoint: URL?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var protocolVersion = "2024-11-05"

    public init(server: RDMCPServer, transport: any MCPTransport, headers: [String: String]) {
        self.server = server
        self.transport = transport
        self.headers = headers
    }

    public func connect() async throws -> MCPServerInfo {
        guard let endpoint = URL(string: server.endpoint) else {
            throw MCPClientError.invalidEndpoint(server.endpoint)
        }
        state = .connecting
        await log(.info, "Connecting to \(endpoint.absoluteString)")
        postEndpoint = try await transport.open(endpoint: endpoint, headers: headers)
        startReading()
        let result = try await request("initialize", params: .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Tamio"),
                "version": .string(Self.appVersion),
            ]),
        ]), timeout: .seconds(15))
        protocolVersion = result["protocolVersion"]?.string ?? protocolVersion
        try await notify("notifications/initialized")
        let info = result["serverInfo"]
        let serverInfo = MCPServerInfo(
            name: info?["name"]?.string ?? server.displayName,
            version: info?["version"]?.string ?? ""
        )
        state = .ready(serverInfo)
        await log(.info, "Connected: \(serverInfo.name) \(serverInfo.version) · protocol \(protocolVersion)")
        return serverInfo
    }

    public func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request("tools/list", params: .object(params), timeout: .seconds(15))
            let page = try JSONDecoder().decode(MCPToolPage.self, from: JSONEncoder().encode(result))
            tools.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil
        return tools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
        let result = try await request("tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]), timeout: .seconds(60))
        return MCPCallResult(json: result)
    }

    public func disconnect() async {
        reader?.cancel()
        reader = nil
        await transport.close()
        let open = pending
        pending.removeAll()
        open.values.forEach { $0.resume(throwing: MCPClientError.notConnected) }
        state = .idle
        await log(.info, "Disconnected")
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func startReading() {
        let transport = self.transport
        reader = Task { [weak self] in
            do {
                for try await message in transport.messages {
                    await self?.receive(message)
                }
            } catch {
                await self?.failAll(error)
            }
        }
    }

    private func receive(_ message: JSONValue) async {
        guard let id = message["id"]?.int else { return }
        if let error = message["error"] {
            let text = error["message"]?.string ?? String(localized: "The server refused the request.")
            await log(.error, "\(id): \(text)")
            fail(id, MCPClientError.rpc(text))
            return
        }
        guard let result = message["result"],
              let continuation = pending.removeValue(forKey: id)
        else { return }
        continuation.resume(returning: result)
    }

    private func request(_ method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue {
        guard let endpoint = postEndpoint else { throw MCPClientError.notConnected }
        let id = nextID
        nextID += 1
        let body = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ]))

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw MCPClientError.notConnected }
                return try await self.waitForResponse(id: id, body: body, endpoint: endpoint)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MCPClientError.timeout
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch {
                await log(.error, "\(method): \(error.localizedDescription)")
                fail(id, error)
                throw error
            }
        }
    }

    private func waitForResponse(id: Int, body: Data, endpoint: URL) async throws -> JSONValue {
        let transport = self.transport
        let headers = self.headers
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                do {
                    try await transport.post(body, to: endpoint, headers: headers)
                } catch {
                    await self?.fail(id, error)
                }
            }
        }
    }

    private func notify(_ method: String) async throws {
        guard let endpoint = postEndpoint else { throw MCPClientError.notConnected }
        let body = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]))
        try await transport.post(body, to: endpoint, headers: headers)
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) async {
        let open = pending
        pending.removeAll()
        open.values.forEach { $0.resume(throwing: error) }
        state = .failed(error.localizedDescription)
        await log(.error, error.localizedDescription)
    }

    private func log(_ direction: MCPDebugLog.Direction, _ text: String) async {
        await MCPDebugLog.shared.record(server: server.displayName, direction: direction, text: text)
    }
}
