//
//  MCPTransport.swift
//  TamioModule
//
//  The 2024-11-05 HTTP+SSE transport: a GET for the event stream, and
//  JSON-RPC POSTed to the endpoint that stream announces. The GET is read
//  through URLSessionDataDelegate: some servers answer a live stream with
//  Transfer-Encoding: Identity, which URLSession's AsyncBytes buffers until
//  the connection ends.
//

import Foundation

public protocol MCPTransport: AnyObject, Sendable {
    /// Opens the event stream and returns the message (POST) endpoint.
    func open(endpoint: URL, headers: [String: String]) async throws -> URL
    func post(_ body: Data, to endpoint: URL, headers: [String: String]) async throws
    var messages: AsyncThrowingStream<JSONValue, Error> { get }
    func close() async
}

/// One live event stream: URLSession hands over each chunk as it arrives.
private final class SSEStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<AsyncThrowingStream<Data, Error>, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(label: String) {
        self.label = label
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
        super.init()
    }

    func start(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            responseContinuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3600
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        continuation.finish()
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(MCPClientError.transport(String(localized: "The server's answer was not HTTP."))))
            return
        }
        Task {
            await MCPDebugLog.shared.record(
                server: label,
                direction: .inbound,
                text: "HTTP \(http.statusCode)\n\(Self.headerText(http.allHeaderFields))"
            )
        }
        if (200 ..< 300).contains(http.statusCode) {
            completionHandler(.allow)
            finish(.success(stream))
        } else {
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
            let error: MCPClientError = http.statusCode == 401
                ? .unauthorized(challenge)
                : .http(http.statusCode)
            completionHandler(.cancel)
            finish(.failure(error))
            continuation.finish(throwing: error)
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session?.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<AsyncThrowingStream<Data, Error>, Error>) {
        lock.lock()
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        switch result {
        case let .success(stream):
            continuation?.resume(returning: stream)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private static func headerText(_ fields: [AnyHashable: Any]) -> String {
        fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }
}

public actor MCPSSETransport: MCPTransport {
    public nonisolated let messages: AsyncThrowingStream<JSONValue, Error>
    private nonisolated let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation

    private let label: String
    private let session: URLSession
    private var stream: SSEStream?
    private var endpointWaiters: [CheckedContinuation<URL, Error>] = []
    private var finished = false
    private var closed = false

    public init(label: String = "MCP", session: URLSession = .shared) {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        messages = stream
        self.continuation = continuation
        self.label = label
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

        await log(.outbound, "GET \(endpoint.absoluteString)\n\(headerText(headers))")
        let stream = SSEStream(label: label)
        self.stream = stream
        do {
            let chunks = try await stream.start(request)
            Task { [weak self] in
                await self?.read(chunks, base: endpoint)
            }
        } catch {
            await log(.error, error.localizedDescription)
            throw error
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
                await self.fail(error)
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
        await log(.outbound, "POST \(endpoint.absoluteString)\n\(headerText(headers))")
        if let text = String(data: body, encoding: .utf8) {
            await log(.outbound, text)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            await log(.inbound, "HTTP \(http.statusCode)\n\(headerText(http.allHeaderFields))")
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                await log(.inbound, text)
            }
            if !(200 ..< 300).contains(http.statusCode) {
                let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
                await log(.error, "HTTP \(http.statusCode)" + (challenge.map { " · \($0)" } ?? ""))
                if http.statusCode == 401 {
                    throw MCPClientError.unauthorized(challenge)
                }
                throw MCPClientError.http(http.statusCode)
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        stream?.cancel()
        stream = nil
        await fail(MCPClientError.transport(String(localized: "Disconnected.")))
    }

    private func read(_ chunks: AsyncThrowingStream<Data, Error>, base: URL) async {
        var parser = MCPSSEParser()
        var buffer = Data()
        do {
            for try await chunk in chunks {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex ..< newline]
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    if let event = parser.consume(line: line) {
                        await receive(event, base: base)
                    }
                }
            }
            await fail(MCPClientError.transport(String(localized: "The server closed the stream.")))
        } catch {
            await fail(MCPClientError.transport(error.localizedDescription))
        }
    }

    private func receive(_ event: MCPSSEEvent, base: URL) async {
        if let name = event.event, name != "message" {
            await log(.info, "SSE event: \(name)")
        }
        let value = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeEndpoint = event.event == "endpoint"
            || (event.event == nil && (value.hasPrefix("/") || value.hasPrefix("http")))
        if looksLikeEndpoint {
            if let url = URL(string: value, relativeTo: base)?.absoluteURL {
                await log(.info, "endpoint \(url.absoluteString)")
                endpointWaiters.forEach { $0.resume(returning: url) }
                endpointWaiters.removeAll()
            }
            return
        }
        guard let data = event.data.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            await log(.inbound, event.data)
            return
        }
        await log(.inbound, event.data)
        continuation.yield(message)
    }

    private func waitForEndpoint() async throws -> URL {
        try await withCheckedThrowingContinuation { endpointWaiters.append($0) }
    }

    private func fail(_ error: Error) async {
        guard !finished else { return }
        finished = true
        await log(.error, error.localizedDescription)
        endpointWaiters.forEach { $0.resume(throwing: error) }
        endpointWaiters.removeAll()
        continuation.finish(throwing: error)
    }

    private func headerText(_ headers: [String: String]) -> String {
        headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }

    private func headerText(_ fields: [AnyHashable: Any]) -> String {
        fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }

    private func log(_ direction: MCPDebugLog.Direction, _ text: String) async {
        await MCPDebugLog.shared.record(server: label, direction: direction, text: text)
    }
}
