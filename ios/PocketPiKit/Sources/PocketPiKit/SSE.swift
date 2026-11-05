import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server-sent events framing: feed it bytes as they arrive, get back the
/// `data` of each complete event. Only what pocketpi sends is needed (data
/// lines, keep-alive comments), but the rest of the format is parsed too.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            let text = String(decoding: line, as: UTF8.self)
            if text.isEmpty {
                if !dataLines.isEmpty { out.append(dataLines.joined(separator: "\n")) }
                dataLines = []
            } else if text.hasPrefix(":") {
                continue // comment, e.g. keep-alive
            } else if text.hasPrefix("data:") {
                var v = text.dropFirst(5)
                if v.first == " " { v = v.dropFirst() }
                dataLines.append(String(v))
            } // event:, id:, retry: are not used by pocketpi
        }
        return out
    }
}

/// Streams an SSE endpoint as decoded JSON events. Uses a data delegate rather
/// than `URLSession.bytes` so the same code runs in the Linux tests.
final class SSEStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Only touched on the session's serial delegate queue.
    private var parser = SSEParser()
    private let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?

    static func open(_ request: URLRequest) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let s = SSEStream(continuation: continuation)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let config = URLSessionConfiguration.default
            // pocketpi sends a keep-alive every 15 s; silence for a minute is a dead link.
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 7 * 24 * 3600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: s, delegateQueue: queue)
            s.session = session
            let task = session.dataTask(with: request)
            s.task = task
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    private init(continuation: AsyncThrowingStream<JSONValue, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            continuation.finish(throwing: PocketPiError.http(status: status, message: "event stream refused"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for payload in parser.feed(data) {
            if let v = try? JSONValue.parse(payload) { continuation.yield(v) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }
}
