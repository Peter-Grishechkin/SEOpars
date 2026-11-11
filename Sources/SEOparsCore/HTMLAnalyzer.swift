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
