import Combine
import Foundation
import TamioModule

/// Live connections to the saved MCP servers. A connection stays open until
/// the user disconnects or quits; its tool list is kept in memory.
@MainActor
final class MCPClientCenter: ObservableObject {
    static let shared = MCPClientCenter()

    @Published private(set) var states: [UUID: MCPClientState] = [:]
    @Published private(set) var serverInfo: [UUID: MCPServerInfo] = [:]
    @Published private(set) var toolLists: [UUID: [MCPTool]] = [:]

    private var clients: [UUID: MCPClient] = [:]
    private var transports: [UUID: any MCPTransport] = [:]

    private init() {}

    func state(_ id: UUID) -> MCPClientState { states[id] ?? .idle }
    func toolList(_ id: UUID) -> [MCPTool] { toolLists[id] ?? [] }
    func isConnected(_ id: UUID) -> Bool {
        if case .ready = states[id] { return true }
        return false
    }

    func connect(_ server: RDMCPServer) async {
        var server = server
        states[server.id] = .connecting
        MCPDebugLog.shared.record(
            server: server.displayName,
            direction: .info,
            text: "Connect \(server.endpoint)"
        )
        if case let .oauth(oauth) = server.auth,
           let expiresAt = oauth.expiresAt,
           expiresAt < Date().addingTimeInterval(60),
           !oauth.refreshToken.isEmpty,
           let refreshed = try? await MCPOAuthCoordinator.refresh(oauth)
        {
            server.auth = .oauth(refreshed)
            TamioStore.shared.mcpServerGroup.insert(server)
        }
        do {
            try await connectOnce(server)
        } catch let error as MCPClientError {
            guard case let .unauthorized(challenge) = error, case let .oauth(oauth) = server.auth else {
                states[server.id] = .failed(error.localizedDescription)
                return
            }
            do {
                let signedIn = try await MCPOAuthCoordinator.signIn(endpoint: server.endpoint, oauth: oauth, challenge: challenge)
                server.auth = .oauth(signedIn)
                TamioStore.shared.mcpServerGroup.insert(server)
                try await connectOnce(server)
            } catch {
                states[server.id] = .failed(error.localizedDescription)
            }
        } catch {
            states[server.id] = .failed(error.localizedDescription)
        }
    }

    func disconnect(_ id: UUID) async {
        if let client = clients[id] { await client.disconnect() }
        clients[id] = nil
        transports[id] = nil
        states[id] = .idle
    }

    func callTool(server: RDMCPServer, name: String, arguments: JSONValue) async throws -> MCPCallResult {
        guard let client = clients[server.id] else { throw MCPClientError.notConnected }
        return try await client.callTool(name: name, arguments: arguments)
    }

    private func connectOnce(_ server: RDMCPServer) async throws {
        await disconnect(server.id)
        states[server.id] = .connecting
        let transport: any MCPTransport = server.transportKind == .sse
            ? MCPSSETransport(label: server.displayName)
            : MCPStreamableHTTPTransport(label: server.displayName)
        let client = MCPClient(server: server, transport: transport, headers: Self.headers(for: server.auth))
        transports[server.id] = transport
        clients[server.id] = client
        let info = try await client.connect()
        let list = try await client.listTools()
        states[server.id] = .ready(info)
        serverInfo[server.id] = info
        toolLists[server.id] = list
        var updated = server
        updated.lastConnected = Date()
        TamioStore.shared.mcpServerGroup.insert(updated)
    }

    static func headers(for auth: MCPAuth) -> [String: String] {
        switch auth {
        case .none:
            return [:]
        case let .bearer(token):
            return ["Authorization": "Bearer \(token)"]
        case let .headers(headers):
            return Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        case let .oauth(oauth):
            return oauth.accessToken.isEmpty ? [:] : ["Authorization": "Bearer \(oauth.accessToken)"]
        }
    }
}
