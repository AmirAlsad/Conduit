//
//  RecordingURLProtocol.swift
//  ConduitTests
//
//  A URLProtocol that answers every request with an empty 200 and records it, so
//  HTTP clients that take a `URLSession` can be tested without a network. Tests
//  run in parallel, so each one uses its own host and reads back only that host.
//

import Foundation

final class RecordingURLProtocol: URLProtocol {
    struct Captured {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var captured: [Captured] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func requests(host: String) -> [Captured] {
        lock.lock()
        defer { lock.unlock() }
        return captured.filter { $0.url.host() == host }
    }

    /// A unique endpoint whose requests no other test will see.
    static func uniqueEndpoint(path: String = "/inbound/register") -> URL {
        URL(string: "https://\(UUID().uuidString.lowercased()).example.com\(path)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = Captured(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream)
        )
        Self.lock.lock()
        Self.captured.append(record)
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
