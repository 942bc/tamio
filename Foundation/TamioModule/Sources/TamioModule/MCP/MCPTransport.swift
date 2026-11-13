//
//  MCPTransport.swift
//  TamioModule
//
//  The 2024-11-05 HTTP+SSE transport: a GET for the event stream, and
//  JSON-RPC POSTed to the endpoint that stream announces. The protocol keeps
//  MCPClient testable without a network.
//

import Foundation

public protocol MCPTransport: AnyObject, Sendable {
    /// Opens the event stream and returns the message (POST) endpoint.
    func open(endpoint: URL, headers: [String: String]) async throws -> URL
    func post(_ body: Data, to endpoint: URL, headers: [String: String]) async throws
    var messages: AsyncThrowingStream<JSONValue, Error> { get }
    func close() async
}

public actor MCPSSETransport: MCPTransport {
    public nonisolated let messages: AsyncThrowingStream<JSONValue, Error>
    private nonisolated let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation

    private let session: URLSession
    private var task: Task<Void, Never>?
    private var endpointWaiters: [CheckedContinuation<URL, Error>] = []
    private var finished = false
    private var closed = false

    public init(session: URLSession = .shared) {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        messages = stream
        self.continuation = continuation
        self.session = session
    }

    public func open(endpoint: URL, headers: [String: String]) async throws -> URL {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 3600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            if http.statusCode == 401 {
                throw MCPClientError.unauthorized(http.value(forHTTPHeaderField: "WWW-Authenticate"))
            }
            throw MCPClientError.http(http.statusCode)
        }

        task = Task { [weak self] in
            guard let self else { return }
            var parser = MCPSSEParser()
            do {
                for try await line in bytes.lines {
                    if let event = parser.consume(line: line) {
                        await self.receive(event, base: endpoint)
                    }
                }
                await self.fail(MCPClientError.transport(String(localized: "The server closed the stream.")))
            } catch {
                await self.fail(MCPClientError.transport(error.localizedDescription))
            }
        }

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await self.waitForEndpoint() }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw MCPClientError.timeout
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch {
                fail(error)
                throw error
            }
        }
    }

    public func post(_ body: Data, to endpoint: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            if http.statusCode == 401 {
                throw MCPClientError.unauthorized(http.value(forHTTPHeaderField: "WWW-Authenticate"))
            }
            throw MCPClientError.http(http.statusCode)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        task?.cancel()
        fail(MCPClientError.transport(String(localized: "Disconnected.")))
    }

    private func receive(_ event: MCPSSEEvent, base: URL) {
        if event.event == "endpoint" {
            let value = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: value, relativeTo: base)?.absoluteURL {
                endpointWaiters.forEach { $0.resume(returning: url) }
                endpointWaiters.removeAll()
            }
            return
        }
        guard let data = event.data.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }
        continuation.yield(message)
    }

    private func waitForEndpoint() async throws -> URL {
        try await withCheckedThrowingContinuation { endpointWaiters.append($0) }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        endpointWaiters.forEach { $0.resume(throwing: error) }
        endpointWaiters.removeAll()
        continuation.finish(throwing: error)
    }
}
