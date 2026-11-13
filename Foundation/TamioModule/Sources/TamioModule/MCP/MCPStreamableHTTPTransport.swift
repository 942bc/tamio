//
//  MCPStreamableHTTPTransport.swift
//  TamioModule
//
//  The current MCP transport: every JSON-RPC message is POSTed to one
//  endpoint, and its answer comes back as JSON or as an SSE stream on the
//  same response. The server may give a session id in Mcp-Session-Id.
//

import Foundation

public actor MCPStreamableHTTPTransport: MCPTransport {
    public nonisolated let messages: AsyncThrowingStream<JSONValue, Error>
    private nonisolated let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation

    private let label: String
    private let session: URLSession
    private var sessionID: String?
    private var protocolVersion: String?
    private var closed = false

    public init(label: String = "MCP", session: URLSession = .shared) {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        messages = stream
        self.continuation = continuation
        self.label = label
        self.session = session
    }

    public func open(endpoint: URL, headers _: [String: String]) async throws -> URL {
        await log(.info, "Streamable HTTP \(endpoint.absoluteString)")
        return endpoint
    }

    public func post(_ body: Data, to endpoint: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body

        await log(.outbound, "POST \(endpoint.absoluteString)\n\(headerText(request))")
        if let text = String(data: body, encoding: .utf8) {
            await log(.outbound, text)
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        await log(.inbound, "HTTP \(http.statusCode)\n\(headerText(http.allHeaderFields))")
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = id
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        if !(200 ..< 300).contains(http.statusCode) {
            var data = Data()
            do {
                for try await byte in bytes { data.append(byte) }
            } catch {
                await log(.error, error.localizedDescription)
            }
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                await log(.inbound, text)
            }
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
            await log(.error, "HTTP \(http.statusCode)" + (challenge.map { " · \($0)" } ?? ""))
            if http.statusCode == 401 {
                throw MCPClientError.unauthorized(challenge)
            }
            throw MCPClientError.http(http.statusCode)
        }

        if contentType.contains("text/event-stream") {
            var parser = MCPSSEParser()
            for try await line in bytes.lines {
                guard let event = parser.consume(line: line) else { continue }
                guard let data = event.data.data(using: .utf8),
                      let message = try? JSONDecoder().decode(JSONValue.self, from: data)
                else {
                    await log(.inbound, event.data, channel: .sse)
                    continue
                }
                await log(.inbound, event.data, channel: .sse)
                receiveProtocolVersion(from: message)
                continuation.yield(message)
            }
        } else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard !data.isEmpty else { return }
            await log(.inbound, String(data: data, encoding: .utf8) ?? "")
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
            receiveProtocolVersion(from: message)
            continuation.yield(message)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
        await log(.info, "Disconnected")
    }

    private func receiveProtocolVersion(from message: JSONValue) {
        if protocolVersion == nil, let version = message["result"]?["protocolVersion"]?.string {
            protocolVersion = version
        }
    }

    private func headerText(_ request: URLRequest) -> String {
        (request.allHTTPHeaderFields ?? [:])
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }

    private func headerText(_ fields: [AnyHashable: Any]) -> String {
        fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }

    private func log(
        _ direction: MCPDebugLog.Direction,
        _ text: String,
        channel: MCPDebugLog.Channel = .http
    ) async {
        await MCPDebugLog.shared.record(
            server: label,
            direction: direction,
            text: text,
            channel: channel
        )
    }
}
