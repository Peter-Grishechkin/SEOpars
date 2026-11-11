import Foundation

public struct FetchResult: Sendable {
    public var statusCode: Int = 0
    public var headers: [String: String] = [:]
    public var body = Data()
    public var responseTimeMs = 0
    public var error: String?
    public var truncated = false

    public var contentType: String { headers["content-type"] ?? "" }
    public var location: String? { headers["location"] }
}

/// Не даёт URLSession молча идти по редиректам: каждый 3xx записывается отдельной строкой.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public final class Fetcher: Sendable {
    let session: URLSession

    public init(timeout: TimeInterval, maxConnections: Int, protocolClasses: [AnyClass]? = nil) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3
        cfg.httpMaximumConnectionsPerHost = max(1, maxConnections)
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        if let protocolClasses { cfg.protocolClasses = protocolClasses + (cfg.protocolClasses ?? []) }
        session = URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Загружает адрес. Тело читается только если `wantBody` вернул true для Content-Type.
    public func fetch(_ url: URL, userAgent: String, maxBytes: Int, wantBody: @Sendable (String) -> Bool) async -> FetchResult {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("ru-RU,ru;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        var result = FetchResult()
        let start = ContinuousClock.now
        do {
            let (bytes, response) = try await session.bytes(for: req)
            result.responseTimeMs = Self.ms(since: start)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                result.error = "Не HTTP-ответ"
                return result
            }
            result.statusCode = http.statusCode
            for (k, v) in http.allHeaderFields {
                if let k = k as? String { result.headers[k.lowercased()] = "\(v)" }
            }
            if wantBody(result.contentType) {
                var data = Data()
                if http.expectedContentLength > 0 { data.reserveCapacity(Int(min(http.expectedContentLength, Int64(maxBytes)))) }
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= maxBytes {
                        result.truncated = true
                        break
                    }
                }
                if result.truncated { bytes.task.cancel() }
                result.body = data
            } else {
                bytes.task.cancel()
            }
        } catch {
            if result.statusCode == 0 {
                result.responseTimeMs = Self.ms(since: start)
                result.error = Self.describe(error)
            }
        }
        return result
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .timedOut: return "Тайм-аут"
        case .cannotFindHost, .dnsLookupFailed: return "Домен не найден"
        case .cannotConnectToHost: return "Нет соединения с сервером"
        case .networkConnectionLost: return "Соединение прервано"
        case .notConnectedToInternet: return "Нет интернета"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "Ошибка SSL: \(e.localizedDescription)"
        case .httpTooManyRedirects: return "Слишком много редиректов"
        case .badServerResponse: return "Некорректный ответ сервера"
        case .cancelled: return "Отменено"
        default: return e.localizedDescription
        }
    }
}
