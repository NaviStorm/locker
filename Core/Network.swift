import Foundation

typealias HTTPExchange = (URLRequest) async throws -> (Data, HTTPURLResponse)

struct TransportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Network {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest, maxBytes: Int = 8 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else { throw TransportError(message: "HTTPS est requis.") }
        let (url, raw) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let response = raw as? HTTPURLResponse,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else {
            throw TransportError(message: "Réponse du fournisseur invalide ou trop volumineuse.")
        }
        return (try Data(contentsOf: url), response)
    }

    static func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw TransportError(message: "Le fournisseur a répondu HTTP \(response.statusCode).")
        }
    }
}
