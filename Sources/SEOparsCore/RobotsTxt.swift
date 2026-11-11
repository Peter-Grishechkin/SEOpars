import Foundation

/// Сопоставление шаблонов robots.txt: `*` — любая последовательность, `$` в конце — конец адреса.
public enum RobotsPattern {
    public static func matches(pattern: String, path: String) -> Bool {
        var p = Array(normalize(pattern).utf8)
        let text = Array(path.utf8)
        var anchored = false
        if p.last == UInt8(ascii: "$") {
            anchored = true
            p.removeLast()
        }
        let parts = p.split(separator: UInt8(ascii: "*"), omittingEmptySubsequences: false).map(Array.init)
        guard let first = parts.first, text.starts(with: first) else { return false }
        var idx = first.count
        if parts.count == 1 { return anchored ? text.count == idx : true }
        for part in parts[1..<(parts.count - 1)] where !part.isEmpty {
            guard let found = find(part, in: text, from: idx) else { return false }
            idx = found + part.count
        }
        let last = parts[parts.count - 1]
        if anchored {
            return text.count - idx >= last.count && text.suffix(last.count).elementsEqual(last)
        }
        return last.isEmpty || find(last, in: text, from: idx) != nil
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count - from else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    /// Кириллицу в шаблоне кодируем так же, как в нормализованных URL.
    static func normalize(_ pattern: String) -> String {
        var out = ""
        for scalar in pattern.unicodeScalars {
            if scalar.isASCII, scalar != " " {
                out.unicodeScalars.append(scalar)
            } else {
                for b in String(scalar).utf8 { out += String(format: "%%%02X", b) }
            }
        }
        return URLNormalizer.normalizePercentEncoding(out)
    }
}

/// Разбор robots.txt: группы по User-agent, Allow/Disallow, Crawl-delay, Sitemap, Clean-param.
public struct RobotsTxt: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public var allow: Bool
        public var pattern: String
        /// Строка, как в robots.txt: `Disallow: /blocked/`.
        public var line: String { (allow ? "Allow: " : "Disallow: ") + pattern }
    }

    public struct Group: Sendable, Equatable {
        public var agents: [String] = []
        public var rules: [Rule] = []
        public var crawlDelay: Double?
    }

    public var groups: [Group] = []
    public var sitemaps: [String] = []
    public var cleanParams: [CleanParamRule] = []
    public var raw: String = ""

    public init() {}

    public init(text: String) {
        raw = text
        var current: Group?
        var lastWasAgent = false
        func closeGroup() {
            if let g = current { groups.append(g) }
            current = nil
        }
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "user-agent":
                if !lastWasAgent { closeGroup(); current = Group() }
                current?.agents.append(value.lowercased())
                lastWasAgent = true
                continue
            case "allow", "disallow":
                if current != nil, !value.isEmpty {
                    current?.rules.append(Rule(allow: key == "allow", pattern: value))
                }
            case "crawl-delay":
                if let v = Double(value.replacingOccurrences(of: ",", with: ".")) { current?.crawlDelay = v }
            case "sitemap":
                if !value.isEmpty { sitemaps.append(value) }
            case "clean-param":
                let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let paramsPart = parts.first {
                    let params = paramsPart.split(separator: "&").map { String($0) }
                    let prefix = parts.count > 1 ? String(parts[1]) : ""
                    cleanParams.append(CleanParamRule(params: params, pathPrefix: prefix))
                }
            default:
                break
            }
            lastWasAgent = false
        }
        closeGroup()
    }

    /// Самая точная группа для робота: самое длинное имя агента, которое является началом токена.
    /// Если подходящей нет — группа `*`. Одноимённые группы объединяются.
    public func group(for token: String) -> Group? {
        let token = token.lowercased()
        var bestAgent: String?
        for g in groups {
            for agent in g.agents where agent != "*" && token.hasPrefix(agent) {
                if bestAgent == nil || agent.count > bestAgent!.count { bestAgent = agent }
            }
        }
        let chosen = bestAgent ?? "*"
        let matching = groups.filter { $0.agents.contains(chosen) }
        guard !matching.isEmpty else { return nil }
        var merged = Group(agents: [chosen])
        for g in matching {
            merged.rules += g.rules
            if let d = g.crawlDelay { merged.crawlDelay = max(merged.crawlDelay ?? 0, d) }
        }
        return merged
    }

    /// Разрешён ли путь (путь + `?запрос`, в нормализованном виде). Побеждает самое длинное правило,
    /// при равенстве — Allow.
    public func isAllowed(_ pathAndQuery: String, token: String) -> Bool {
        if pathAndQuery == "/robots.txt" { return true }
        return decisiveRule(pathAndQuery, token: token)?.rule.allow ?? true
    }

    /// Правило, которое решает, разрешён ли путь, и User-agent его группы. `nil` — ни одно правило не подошло.
    public func decisiveRule(_ pathAndQuery: String, token: String) -> (rule: Rule, agent: String)? {
        guard let g = group(for: token) else { return nil }
        var best: Rule?
        for rule in g.rules where RobotsPattern.matches(pattern: rule.pattern, path: pathAndQuery) {
            let len = rule.pattern.count, bestLen = best?.pattern.count ?? -1
            if len > bestLen || (len == bestLen && rule.allow) { best = rule }
        }
        return best.map { ($0, g.agents.first ?? "*") }
    }

    public func crawlDelay(token: String) -> Double? { group(for: token)?.crawlDelay }

    /// Путь и запрос из нормализованного URL.
    public static func pathAndQuery(of url: String) -> String {
        guard let r = url.range(of: "://") else { return "/" }
        let rest = url[r.upperBound...]
        guard let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) else { return "/" }
        let tail = String(rest[slash...])
        return tail.hasPrefix("?") ? "/" + tail : tail
    }
}
