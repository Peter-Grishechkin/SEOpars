import Foundation

/// Правило Clean-param из robots.txt (директива Яндекса).
public struct CleanParamRule: Sendable, Equatable {
    public var params: [String]
    /// Префикс пути, может содержать `*`. Пусто — для всего сайта.
    public var pathPrefix: String

    public init(params: [String], pathPrefix: String) {
        self.params = params
        self.pathPrefix = pathPrefix
    }
}

/// Приводит URL к одному виду, чтобы одинаковые адреса не считались разными страницами.
///
/// Что делает:
/// - схема и хост в нижнем регистре, кириллический домен — в punycode, порт по умолчанию убирается;
/// - кириллица в пути и `%d0%ba`/`%D0%BA` сводятся к одному виду (верхний регистр hex);
/// - `.` и `..` в пути раскрываются, `#фрагмент` отбрасывается;
/// - параметры из списка «игнорировать» и Clean-param удаляются.
///
/// Чего не делает намеренно: не склеивает слэш на конце и регистр пути — это разные URL,
/// их дубли показываются как проблема.
public struct URLNormalizer: Sendable {
    public var ignoredParams: [String]
    public var cleanParams: [CleanParamRule]

    public init(ignoredParams: [String] = [], cleanParams: [CleanParamRule] = []) {
        self.ignoredParams = ignoredParams.map { $0.lowercased() }
        self.cleanParams = cleanParams
    }

    /// Нормализует ссылку относительно базового адреса. Возвращает nil для не-http ссылок.
    public func normalize(_ raw: String, base: URL? = nil) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Браузеры вырезают переводы строк и табы внутри адреса.
        s.removeAll { $0 == "\n" || $0 == "\r" || $0 == "\t" }
        if s.isEmpty || s.hasPrefix("#") { return nil }
        let lower = s.lowercased()
        for scheme in ["mailto:", "tel:", "javascript:", "data:", "sms:", "skype:", "viber:", "whatsapp:", "callto:", "fax:", "ftp:", "file:", "blob:"] where lower.hasPrefix(scheme) {
            return nil
        }
        // Обратные слэши браузеры трактуют как прямые.
        if s.contains("\\") { s = s.replacingOccurrences(of: "\\", with: "/") }

        guard let resolved = URL(string: s, relativeTo: base)?.absoluteURL,
              let comps = URLComponents(url: resolved, resolvingAgainstBaseURL: true),
              let schemeRaw = comps.scheme?.lowercased(),
              schemeRaw == "http" || schemeRaw == "https"
        else { return nil }

        guard var host = comps.encodedHost?.lowercased(), !host.isEmpty else { return nil }
        if host.contains("%") {
            // На случай, если Foundation отдал хост percent-encoded: переводим в punycode.
            host = (host.removingPercentEncoding ?? host)
            host = Self.punycodeHost(host)
        }
        while host.hasSuffix(".") { host.removeLast() }

        var result = schemeRaw + "://" + host
        if let port = comps.port, !(schemeRaw == "http" && port == 80), !(schemeRaw == "https" && port == 443) {
            result += ":\(port)"
        }

        var path = comps.percentEncodedPath
        if path.isEmpty { path = "/" }
        path = Self.removeDotSegments(path)
        path = Self.normalizePercentEncoding(path)
        result += path

        if let query = comps.percentEncodedQuery, !query.isEmpty {
            let kept = query.split(separator: "&", omittingEmptySubsequences: true).filter { item in
                let name = String(item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                let decoded = (name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? name).lowercased()
                return !shouldDrop(param: decoded, path: path)
            }
            if !kept.isEmpty {
                result += "?" + Self.normalizePercentEncoding(kept.joined(separator: "&"))
            }
        }
        return result
    }

    private func shouldDrop(param: String, path: String) -> Bool {
        for pattern in ignoredParams {
            if pattern.hasSuffix("*") {
                if param.hasPrefix(pattern.dropLast()) { return true }
            } else if param == pattern {
                return true
            }
        }
        for rule in cleanParams where rule.params.contains(where: { $0.lowercased() == param }) {
            if rule.pathPrefix.isEmpty || RobotsPattern.matches(pattern: rule.pathPrefix, path: path) {
                return true
            }
        }
        return false
    }

    // MARK: - Вспомогательное

    /// RFC 3986, 5.2.4.
    static func removeDotSegments(_ path: String) -> String {
        guard path.contains(".") else { return path }
        var input = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Первый элемент пустой (путь начинается со «/»).
        if input.first == "" { input.removeFirst() }
        var output: [String] = []
        for (i, seg) in input.enumerated() {
            let isLast = i == input.count - 1
            if seg == "." {
                if isLast { output.append("") }
            } else if seg == ".." {
                if !output.isEmpty { output.removeLast() }
                if isLast { output.append("") }
            } else {
                output.append(seg)
            }
        }
        return "/" + output.joined(separator: "/")
    }

    /// Раскрывает %XX для незарезервированных символов и переводит остальные в верхний регистр.
    static func normalizePercentEncoding(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "%"), i + 2 < bytes.count, let h = hexValue(bytes[i + 1]), let l = hexValue(bytes[i + 2]) {
                let v = h << 4 | l
                if isUnreserved(v) {
                    out.append(v)
                } else {
                    out.append(UInt8(ascii: "%"))
                    out.append(hexDigit(v >> 4))
                    out.append(hexDigit(v & 0xF))
                }
                i += 3
            } else if b == UInt8(ascii: "%") {
                // Одинокий «%» кодируем, чтобы адрес оставался валидным.
                out.append(contentsOf: Array("%25".utf8))
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? UInt8(ascii: "0") + v : UInt8(ascii: "A") + v - 10
    }

    private static func isUnreserved(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    static func punycodeHost(_ host: String) -> String {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        return c.encodedHost ?? host
    }

    // MARK: - Отображение

    /// Читаемый вид: кириллица в домене и пути вместо punycode и %XX.
    public static func display(_ url: String) -> String {
        guard let range = url.range(of: "://") else { return url }
        let scheme = url[..<range.lowerBound]
        let rest = url[range.upperBound...]
        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == ":" }) ?? rest.endIndex
        let host = String(rest[..<hostEnd])
        let tail = String(rest[hostEnd...])
        let shownHost = host.contains("xn--") ? Punycode.decodeHost(host) : host
        let shownTail = decodeForDisplay(tail)
        return "\(scheme)://\(shownHost)\(shownTail)"
    }

    private static func decodeForDisplay(_ s: String) -> String {
        guard s.contains("%") else { return s }
        // Раскрываем только то, что даёт валидный UTF-8, служебные символы оставляем закодированными.
        var result = ""
        var bytes: [UInt8] = []
        func flush() {
            if bytes.isEmpty { return }
            if let str = String(bytes: bytes, encoding: .utf8), !str.contains(where: { "/?#&=%+ ".contains($0) }) {
                result += str
            } else {
                result += bytes.map { String(format: "%%%02X", $0) }.joined()
            }
            bytes.removeAll()
        }
        let chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "%"), i + 2 < chars.count, let h = hexValue(chars[i + 1]), let l = hexValue(chars[i + 2]) {
                bytes.append(h << 4 | l)
                i += 3
            } else {
                flush()
                result += String(decoding: [chars[i]], as: UTF8.self)
                i += 1
            }
        }
        flush()
        return result
    }
}

/// Декодер punycode (RFC 3492) для показа доменов .рф.
public enum Punycode {
    public static func decodeHost(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let l = String(label)
            if l.lowercased().hasPrefix("xn--"), let decoded = decode(String(l.dropFirst(4))) {
                return decoded
            }
            return l
        }.joined(separator: ".")
    }

    public static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var n = 128, i = 0, bias = 72
        var output: [Unicode.Scalar] = []
        var chars = Array(input.unicodeScalars)
        if let delim = chars.lastIndex(of: "-") {
            output = Array(chars[..<delim])
            chars = Array(chars[(delim + 1)...])
        }
        var pos = 0
        func adapt(_ delta: Int, _ numPoints: Int, _ first: Bool) -> Int {
            var d = first ? delta / damp : delta / 2
            d += d / numPoints
            var k = 0
            while d > ((base - tMin) * tMax) / 2 {
                d /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        while pos < chars.count {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard pos < chars.count else { return nil }
                let c = chars[pos].value
                pos += 1
                let digit: Int
                switch c {
                case 0x30...0x39: digit = Int(c) - 22
                case 0x41...0x5A: digit = Int(c) - 0x41
                case 0x61...0x7A: digit = Int(c) - 0x61
                default: return nil
                }
                i += digit * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                w *= base - t
                k += base
            }
            bias = adapt(i - oldI, output.count + 1, oldI == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard let scalar = Unicode.Scalar(n) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        var s = ""
        s.unicodeScalars.append(contentsOf: output)
        return s
    }
}
