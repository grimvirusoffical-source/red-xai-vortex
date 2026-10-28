import Foundation

/// Bounded JSON/SSE HTTP with no credential-bearing redirects.
final class MCPHTTPTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: MCPHTTPTransaction] = [:]
    func post(_ request: URLRequest, messageID: Int?, limit: Int) async throws -> (object: [String: Any], sessionID: String?) {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let transaction = MCPHTTPTransaction(messageID: messageID, limit: limit) { [weak self] result in
                if let self { self.lock.lock(); self.active.removeValue(forKey: id); self.lock.unlock() }
                continuation.resume(with: result)
            }
            lock.lock(); active[id] = transaction; lock.unlock()
            transaction.start(request)
        }
    }
    func cancelAll() {
        lock.lock(); let items = Array(active.values); active.removeAll(); lock.unlock()
        for transaction in items { transaction.cancel() }
    }
}

final class MCPHTTPTransaction: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Output = (object: [String: Any], sessionID: String?)
    private var completion: ((Result<Output, Error>) -> Void)?
    private let expectedID: Int?
    private let limit: Int
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var lineBuffer = Data()
    private var eventLines: [String] = []
    private var receivedBytes = 0
    private var isEventStream = false
    private var sessionID: String?
    private let finishLock = NSLock()

    init(messageID: Int?, limit: Int, completion: @escaping (Result<Output, Error>) -> Void) {
        expectedID = messageID; self.limit = limit; self.completion = completion
    }
    func start(_ request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s; task = s.dataTask(with: request); task?.resume()
    }
    func cancel() { finish(.failure(MCPConfig.error("MCP connection stopped."))) }
    private func finish(_ result: Result<Output, Error>) {
        finishLock.lock(); let callback = completion; completion = nil; finishLock.unlock()
        guard let callback else { return }
        callback(result)
        task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(MCPConfig.error("MCP endpoint redirected. Enter the final server URL; credentials were not forwarded.")))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(MCPConfig.error("Invalid MCP HTTP response."))); return
        }
        guard (200...299).contains(response.statusCode) else {
            let description: String
            switch response.statusCode {
            case 401: description = "MCP authentication required or rejected. Check the API key/bearer token and authentication mode."
            case 403: description = "MCP server denied access. Check the key's scopes and server permissions."
            case 404: description = "MCP endpoint or session was not found. Check the URL, then reconnect."
            case 429: description = "MCP rate limit reached. Wait before retrying; tool calls are not automatically repeated."
            default: description = "MCP server returned HTTP \(response.statusCode)."
            }
            completionHandler(.cancel)
            finish(.failure(NSError(domain: "MCP", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: description])))
            return
        }
        if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !value.isEmpty, value.utf8.count < 1024,
           !value.contains("\r"), !value.contains("\n") { sessionID = value }
        if expectedID == nil { completionHandler(.cancel); finish(.success(([:], sessionID))); return }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        isEventStream = contentType.contains("text/event-stream")
        guard isEventStream || contentType.contains("application/json") else {
            completionHandler(.cancel); finish(.failure(MCPConfig.error("The URL did not return MCP JSON or SSE. Check that it is an MCP endpoint, not a website or API REST endpoint."))); return
        }
        if response.expectedContentLength > Int64(limit) { completionHandler(.cancel); finish(.failure(MCPConfig.error("MCP response exceeds the configured size limit."))); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedBytes += data.count
        guard receivedBytes <= limit else { finish(.failure(MCPConfig.error("MCP response exceeds the configured size limit."))); return }
        if !isEventStream { bytes.append(data); return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let raw = lineBuffer[..<newline]
            let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            lineBuffer.removeSubrange(...newline)
            if line.isEmpty { if consumeEvent() { return } }
            else if line.hasPrefix("data:") {
                var payload = String(line.dropFirst(5)); if payload.hasPrefix(" ") { payload.removeFirst() }
                eventLines.append(payload)
            }
        }
    }
    @discardableResult private func consumeEvent() -> Bool {
        defer { eventLines.removeAll() }
        guard !eventLines.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(eventLines.joined(separator: "\n").utf8)) as? [String: Any],
              object["id"] as? Int == expectedID else { return false }
        finish(.success((object, sessionID))); return true
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finishLock.lock(); let pending = completion != nil; finishLock.unlock()
        guard pending else { return }
        if let error {
            let e = error as NSError
            let description = e.code == NSURLErrorTimedOut ? "MCP request timed out. Check the endpoint or increase the optional timeout." : "MCP connection failed. Check the network, endpoint and TLS certificate."
            finish(.failure(MCPConfig.error(description))); return
        }
        if isEventStream {
            if consumeEvent() { return }
            finish(.failure(MCPConfig.error("MCP event stream ended without a response for this request."))); return
        }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["id"] as? Int == expectedID else {
            finish(.failure(MCPConfig.error("MCP returned invalid JSON or a mismatched response id."))); return
        }
        finish(.success((object, sessionID)))
    }
}
