//
//  MCPStreamableHTTPTransport.swift
//  TamioModule
//
//  The current MCP transport: every JSON-RPC message is POSTed to one
//  endpoint, and its answer comes back as JSON or as an SSE stream on the
//  same response. The response is read through URLSessionDataDelegate, as
//  some servers send their SSE stream with Transfer-Encoding: Identity,
//  which URLSession's AsyncBytes buffers until the connection ends.
//

import Foundation

public actor MCPStreamableHTTPTransport: MCPTransport {
    public nonisolated let messages: AsyncThrowingStream<JSONValue, Error>
    private nonisolated let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation

    private let label: String
    private var sessionID: String?
    private var protocolVersion: String?
    private var closed = false

    public init(label: String = "MCP") {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        messages = stream
        self.continuation = continuation
        self.label = label
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
        // The header belongs on requests after initialize; the initialize
        // request carries its version in the body. A server may call the
        // pair a mismatch if the header is sent with initialize.
        if let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body

        await log(.outbound, "POST \(endpoint.absoluteString)\n\(headerText(request))")
        if let text = String(data: body, encoding: .utf8) {
            await log(.outbound, text)
        }

        let responseStream = StreamableResponse()
        let (http, chunks) = try await responseStream.start(request)
        await log(.inbound, "HTTP \(http.statusCode)\n\(headerText(http.allHeaderFields))")
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = id
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        if !(200 ..< 300).contains(http.statusCode) {
            var data = Data()
            do {
                for try await chunk in chunks { data.append(chunk) }
            } catch {
                await log(.error, error.localizedDescription)
            }
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                await log(.inbound, text)
            }
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
            await log(.error, "HTTP \(http.statusCode)" + (challenge.map { " · \($0)" } ?? ""))
            responseStream.cancel()
            if http.statusCode == 401 {
                throw MCPClientError.unauthorized(challenge)
            }
            throw MCPClientError.http(http.statusCode)
        }

        if contentType.contains("text/event-stream") {
            var parser = MCPSSEParser()
            var buffer = Data()
            for try await chunk in chunks {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex ..< newline]
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    let line = String(decoding: lineData, as: UTF8.self)
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
            }
            responseStream.cancel()
        } else {
            var data = Data()
            for try await chunk in chunks { data.append(chunk) }
            responseStream.cancel()
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

/// One POST's response: headers as soon as they arrive, then each chunk.
private final class StreamableResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    override init() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
        super.init()
    }

    func start(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            responseContinuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
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
        completionHandler(.allow)
        finish(.success((http, stream)))
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

    private func finish(_ result: Result<(HTTPURLResponse, AsyncThrowingStream<Data, Error>), Error>) {
        lock.lock()
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        switch result {
        case let .success(value):
            continuation?.resume(returning: value)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}
