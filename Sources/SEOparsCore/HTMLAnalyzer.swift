import CryptoKit
import Foundation
import SwiftSoup

/// Разбор HTML: мета-теги, заголовки, ссылки, текст.
public enum HTMLAnalyzer {
    public struct Result: Sendable {
        public var info: HTMLInfo
        public var links: [RawLink]
        /// `<base href>`, если есть.
        public var baseHref: String?
    }

    public static func parse(_ html: String, zoneRules: [ZoneRule] = []) -> Result {
        var info = HTMLInfo()
        var links: [RawLink] = []
        var baseHref: String?

        // До SwiftSoup: он сам исправляет разметку и прячет ошибки <head> (№ 112).
        let head = scanHead(html)
        info.headCount = head.headCount
        info.bodyCount = head.bodyCount
        info.headBreaker = head.breaker
        info.headHiddenTags = head.hidden

        guard let doc = try? SwiftSoup.parse(html) else {
            return Result(info: info, links: [], baseHref: nil)
        }

        if let base = try? doc.select("base[href]").first()?.attr("href"), !base.isEmpty {
            baseHref = base
        }

        // title: только вне svg.
        if let titles = try? doc.select("title") {
            for t in titles where !hasAncestor(t, named: ["svg"]) {
                info.titles.append(clean((try? t.text()) ?? ""))
            }
        }

        if let metas = try? doc.select("meta") {
            for m in metas {
                let name = ((try? m.attr("name")) ?? "").lowercased()
                let property = ((try? m.attr("property")) ?? "").lowercased()
                let httpEquiv = ((try? m.attr("http-equiv")) ?? "").lowercased()
                let content = clean((try? m.attr("content")) ?? "")
                switch name {
                case "description": info.descriptions.append(content)
                case "keywords": info.keywords = content
                case "robots": info.metaRobots.append(content)
                case "googlebot": info.metaGooglebot.append(content)
                case "yandex": info.metaYandex.append(content)
                case "viewport": info.viewport = content
                case "twitter:card": info.twitterCard = content
                default: break
                }
                switch property {
                case "og:title": info.ogTitle = content
                case "og:description": info.ogDescription = content
                case "og:image": info.ogImage = content
                default: break
                }
                if httpEquiv == "refresh" { info.metaRefresh = content }
            }
        }

        if let linkTags = try? doc.select("link[rel]") {
            for l in linkTags {
                let rel = ((try? l.attr("rel")) ?? "").lowercased().split(separator: " ")
                let href = ((try? l.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if rel.contains("canonical") { info.canonicals.append(href) }
                if rel.contains("alternate"), let lang = try? l.attr("hreflang"), !lang.isEmpty {
                    info.hreflang.append(Hreflang(lang: lang, href: href))
                }
            }
        }

        if let lang = try? doc.select("html").first()?.attr("lang"), !lang.isEmpty { info.lang = lang }

        if let hs = try? doc.select("h1, h2, h3, h4, h5, h6") {
            for h in hs {
                let level = Int(h.tagName().dropFirst()) ?? 0
                info.headings.append(Heading(level: level, text: clean((try? h.text()) ?? "")))
            }
        }

        if let imgs = try? doc.select("img") {
            info.imagesCount = imgs.size()
            var withAlt: [ImageAltSample] = []
            for img in imgs {
                let rawSrc = (try? img.attr("src")) ?? ""
                let src = rawSrc.isEmpty ? ((try? img.attr("data-src")) ?? "") : rawSrc
                guard img.hasAttr("alt") else {
                    info.imagesWithoutAlt += 1
                    if info.imagesWithoutAltSamples.count < 20 { info.imagesWithoutAltSamples.append(src) }
                    continue
                }
                let alt = clean((try? img.attr("alt")) ?? "")
                if alt.isEmpty {
                    info.imagesEmptyAlt += 1
                    if info.imagesEmptyAltSamples.count < 20 { info.imagesEmptyAltSamples.append(src) }
                } else {
                    info.altLengths.append(alt.count)
                    withAlt.append(ImageAltSample(src: src, length: alt.count))
                }
            }
            info.longestAlts = Array(withAlt.sorted { $0.length > $1.length }.prefix(5))
        }

        // Свои правила зон: элементы, подходящие под селектор. Ошибочный селектор пропускается.
        let ruleMatches: [(LinkZone, Set<ObjectIdentifier>)] = zoneRules.compactMap { rule in
            let selector = rule.selector.trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty, let found = try? doc.select(selector) else { return nil }
            return (rule.zone, Set(found.array().map(ObjectIdentifier.init)))
        }

        if let anchors = try? doc.select("a[href], area[href]") {
            for a in anchors {
                let href = (try? a.attr("href")) ?? ""
                var anchor = clean((try? a.text()) ?? "")
                var kind = LinkKind.anchor
                if anchor.isEmpty {
                    if let img = try? a.select("img").first() {
                        kind = .image
                        anchor = clean((try? img.attr("alt")) ?? "")
                    } else if let aria = try? a.attr("aria-label"), !aria.isEmpty {
                        anchor = clean(aria)
                    } else if let title = try? a.attr("title"), !title.isEmpty {
                        anchor = clean(title)
                    }
                }
                links.append(RawLink(
                    href: href,
                    anchor: anchor,
                    rel: RelFlags(relAttribute: (try? a.attr("rel")) ?? ""),
                    kind: kind,
                    zone: zone(of: a, rules: ruleMatches)
                ))
            }
        }

        // Видимый текст: убираем то, что не показывается.
        _ = try? doc.select("script, style, noscript, template, svg, iframe").remove()
        let text = (try? doc.body()?.text()) ?? ""
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        info.wordCount = words.count
        let normalized = words.joined(separator: " ").lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        info.contentHash = digest.prefix(12).map { String(format: "%02x", $0) }.joined()

        return Result(info: info, links: links, baseHref: baseHref)
    }

    static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Meta refresh (№ 103)

    /// Разбор `content` у meta refresh по шагам HTML Living Standard («shared declarative refresh steps»), упрощённо:
    /// `0; url=/x`, `0;URL='/x'`, `0, /x`, `5` (перезагрузка той же страницы). `nil` — значение браузер не примет.
    public static func parseMetaRefresh(_ content: String) -> (delay: Double, url: String?)? {
        var s = Substring(content).drop(while: \.isWhitespace)
        // Время — целые секунды; дробная часть по стандарту отбрасывается. «.5» — тоже 0.
        let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty || s.first == "." else { return nil }
        let delay = Double(digits) ?? 0
        s = s.drop(while: { ($0.isASCII && $0.isNumber) || $0 == "." })
        if s.isEmpty { return (delay, nil) }
        guard let sep = s.first, sep.isWhitespace || sep == ";" || sep == "," else { return nil }
        s = s.drop(while: \.isWhitespace)
        if s.first == ";" || s.first == "," { s = s.dropFirst() }
        s = s.drop(while: \.isWhitespace)
        if s.lowercased().hasPrefix("url") {
            let rest = s.dropFirst(3).drop(while: \.isWhitespace)
            if rest.first == "=" { s = rest.dropFirst().drop(while: \.isWhitespace) }
        }
        if let q = s.first, q == "'" || q == "\"" {
            s = s.dropFirst()
            if let end = s.firstIndex(of: q) { s = s[..<end] }
        }
        let url = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (delay, url.isEmpty ? nil : url)
    }

    // MARK: - Разметка <head> по исходным тегам (№ 112)

    public struct HeadScan: Sendable, Equatable {
        public var headCount = 0
        public var bodyCount = 0
        /// Первый недопустимый элемент в области `<head>`, если после него стоят canonical или meta robots.
        public var breaker: String?
        public var hidden: [String] = []
    }

    /// Элементы, которые парсер HTML оставляет в `<head>` (HTML Living Standard, режим «in head»).
    /// Google Search Central «Use valid HTML elements in the head» (проверено 2026-11-12) называет допустимыми
    /// title, meta, link, script, style, base, noscript, template: на первом недопустимом элементе Google считает
    /// `<head>` законченным и следующие за ним элементы не читает.
    static let headElements: Set<String> = ["base", "basefont", "bgsound", "link", "meta", "title", "noscript", "noframes", "style", "script", "template"]
    /// Содержимое этих элементов — текст, а не разметка: теги внутри не считаются. `noscript` тоже: при включённом
    /// JavaScript браузер и Google (рендер с JS) читают его как текст, а в `<head>` он допустим. Иначе стандартный код
    /// Яндекс Метрики (`<noscript><div><img …></div></noscript>` в `<head>`) давал бы ошибку почти на каждом сайте.
    /// Предположение: что Google делает с noscript до рендера, в документации не сказано.
    static let rawTextElements: Set<String> = ["script", "style", "noscript", "template", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"]

    /// Считает `<head>` и `<body>` и ищет элемент, который закрывает `<head>` раньше canonical или meta robots.
    /// Область `<head>` — то, что автор считал головой страницы: от начала до `</head>` или `<body>`.
    public static func scanHead(_ html: String) -> HeadScan {
        var r = HeadScan()
        let b = Array(html.utf8)
        let n = b.count
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), bang = UInt8(ascii: "!"), question = UInt8(ascii: "?")
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 12 || c == 13 }
        func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
        /// Поиск без учёта регистра букв; `needle` — в нижнем регистре.
        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard !needle.isEmpty, from <= n - needle.count else { return nil }
            var j = from
            while j <= n - needle.count {
                if lower(b[j]) == needle[0] {
                    var k = 1
                    while k < needle.count, lower(b[j + k]) == needle[k] { k += 1 }
                    if k == needle.count { return j }
                }
                j += 1
            }
            return nil
        }
        /// Конец тега: `>` вне значения атрибута в кавычках.
        func tagEnd(from: Int) -> Int {
            var j = from
            while j < n {
                let c = b[j]
                if c == gt { return j }
                if c == UInt8(ascii: "=") {
                    j += 1
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == UInt8(ascii: "\"") || b[j] == UInt8(ascii: "'") {
                        let q = b[j]
                        j += 1
                        while j < n, b[j] != q { j += 1 }
                    }
                }
                j += 1
            }
            return n
        }

        var headOpen = true
        var breaker: String?
        var hidden: [String] = []
        var i = 0
        if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
        while i < n {
            let c = b[i]
            if c != lt || i + 1 >= n {
                if headOpen, breaker == nil, !isSpace(c) {
                    var end = i
                    while end < n, b[end] != lt { end += 1 }
                    let text = clean(String(decoding: b[i..<min(end, i + 120)], as: UTF8.self))
                    breaker = "текст «\(text.count > 30 ? String(text.prefix(30)) + "…" : text)»"
                }
                i += 1
                continue
            }
            let next = b[i + 1]
            if next == bang, i + 3 < n, b[i + 2] == UInt8(ascii: "-"), b[i + 3] == UInt8(ascii: "-") {
                i = (find(Array("-->".utf8), from: i + 4) ?? n) + 3
                continue
            }
            if next == bang || next == question {
                i = tagEnd(from: i + 2) + 1
                continue
            }
            let isEnd = next == slash
            let nameStart = i + (isEnd ? 2 : 1)
            guard nameStart < n, isLetter(b[nameStart]) else {
                if isEnd { i = tagEnd(from: nameStart) + 1; continue }
                // «<» не перед буквой — это текст.
                if headOpen, breaker == nil { breaker = "текст «<»" }
                i += 1
                continue
            }
            var nameEnd = nameStart
            while nameEnd < n, !isSpace(b[nameEnd]), b[nameEnd] != slash, b[nameEnd] != gt { nameEnd += 1 }
            let name = String(decoding: b[nameStart..<nameEnd], as: UTF8.self).lowercased()
            let end = tagEnd(from: nameEnd)
            i = end + 1
            if isEnd {
                if name == "head" { headOpen = false }
                continue
            }
            switch name {
            case "head": r.headCount += 1
            case "body":
                r.bodyCount += 1
                headOpen = false
            case "html": break
            default:
                if headOpen {
                    if !headElements.contains(name) {
                        if breaker == nil { breaker = "<\(name)>" }
                    } else if breaker != nil, let tag = seoTag(name, attributes(b[nameEnd..<min(end, n)])) {
                        if !hidden.contains(tag) { hidden.append(tag) }
                    }
                }
            }
            if rawTextElements.contains(name) {
                i = name == "plaintext" ? n : ((find(Array("</\(name)".utf8), from: i)).map { tagEnd(from: $0 + 2) + 1 } ?? n)
            }
        }
        if let breaker, !hidden.isEmpty {
            r.breaker = breaker
            r.hidden = hidden
        }
        return r
    }

    /// canonical и meta robots, ради которых важен порядок в `<head>`.
    static func seoTag(_ name: String, _ attrs: [String: String]) -> String? {
        switch name {
        case "link":
            let rel = (attrs["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            return rel.contains("canonical") ? "canonical" : nil
        case "meta":
            let n = (attrs["name"] ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            return ["robots", "googlebot", "yandex"].contains(n) ? "meta \(n)" : nil
        default:
            return nil
        }
    }

    /// Атрибуты тега из исходного текста: имя в нижнем регистре, первое вхождение.
    static func attributes(_ s: ArraySlice<UInt8>) -> [String: String] {
        var r: [String: String] = [:]
        let b = Array(s)
        var i = 0
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 12 || c == 13 }
        while i < b.count {
            while i < b.count, isSpace(b[i]) || b[i] == UInt8(ascii: "/") { i += 1 }
            let ns = i
            while i < b.count, !isSpace(b[i]), b[i] != UInt8(ascii: "="), b[i] != UInt8(ascii: "/") { i += 1 }
            guard i > ns else { i += 1; continue }
            let name = String(decoding: b[ns..<i], as: UTF8.self).lowercased()
            while i < b.count, isSpace(b[i]) { i += 1 }
            var value = ""
            if i < b.count, b[i] == UInt8(ascii: "=") {
                i += 1
                while i < b.count, isSpace(b[i]) { i += 1 }
                if i < b.count, b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") {
                    let q = b[i]
                    i += 1
                    let vs = i
                    while i < b.count, b[i] != q { i += 1 }
                    value = String(decoding: b[vs..<min(i, b.count)], as: UTF8.self)
                    i += 1
                } else {
                    let vs = i
                    while i < b.count, !isSpace(b[i]) { i += 1 }
                    value = String(decoding: b[vs..<i], as: UTF8.self)
                }
            }
            if r[name] == nil { r[name] = value }
        }
        return r
    }

    private static func hasAncestor(_ el: Element, named names: Set<String>) -> Bool {
        var p = el.parent()
        while let cur = p {
            if names.contains(cur.tagName().lowercased()) { return true }
            p = cur.parent()
        }
        return false
    }

    /// Ошибка в CSS-селекторе правила зоны или `nil`, если селектор разбирается.
    public static func selectorError(_ selector: String) -> String? {
        let s = selector.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "Пустой селектор" }
        do {
            _ = try SwiftSoup.parse("<p></p>").select(s)
            return nil
        } catch {
            return "Ошибка в селекторе: \(s)"
        }
    }

    /// Зона ссылки: сначала свои правила (ближайший подходящий предок, при равенстве — правило выше в списке),
    /// затем эвристика.
    static func zone(of el: Element, rules: [(LinkZone, Set<ObjectIdentifier>)] = []) -> LinkZone {
        if !rules.isEmpty {
            var p = el.parent()
            while let cur = p {
                let id = ObjectIdentifier(cur)
                if let hit = rules.first(where: { $0.1.contains(id) }) { return hit.0 }
                p = cur.parent()
            }
        }
        return heuristicZone(of: el)
    }

    /// Эвристика зоны: ближайший семантический предок, затем подсказки в class/id.
    static func heuristicZone(of el: Element) -> LinkZone {
        var p = el.parent()
        var hinted: LinkZone?
        while let cur = p {
            let tag = cur.tagName().lowercased()
            if tag == "body" || tag == "html" { break }
            let role = ((try? cur.attr("role")) ?? "").lowercased()
            switch (tag, role) {
            case ("nav", _), (_, "navigation"): return .nav
            case ("header", _), (_, "banner"): return .header
            case ("footer", _), (_, "contentinfo"): return .footer
            case ("aside", _), (_, "complementary"): return .aside
            case ("main", _), ("article", _), (_, "main"): return .content
            default: break
            }
            if hinted == nil {
                let cls = (((try? cur.attr("class")) ?? "") + " " + cur.id()).lowercased()
                if cls.contains("footer") { hinted = .footer }
                else if cls.contains("header") && !cls.contains("entry-header") && !cls.contains("page-header") { hinted = .header }
                else if cls.contains("nav") || cls.contains("menu") { hinted = .nav }
                else if cls.contains("sidebar") { hinted = .aside }
            }
            p = cur.parent()
        }
        return hinted ?? .other
    }
}
