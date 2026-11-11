import Foundation

/// Плоская строка страницы для таблиц и CSV.
public struct PageRow: Identifiable, Sendable, Hashable {
    public var id: Int32
    public var url: String
    public var rawURL: String
    public var status: Int
    public var statusText: String
    public var indexable: Bool
    public var indexability: String
    /// Строка robots.txt, запретившая адрес (№ 105). Пусто — не запрещён.
    public var robotsRule: String
    public var contentType: String
    public var responseMs: Int
    public var sizeKB: Double
    /// -1 — неизвестно.
    public var depth: Int
    public var inlinks: Int
    public var uniqueInlinks: Int
    public var outInternal: Int
    public var outExternal: Int
    public var words: Int
    public var title: String
    public var titleLength: Int
    public var titleCount: Int
    public var description: String
    public var descriptionLength: Int
    public var h1: String
    public var h1Count: Int
    /// Первый H2.
    public var h2: String
    public var h2Count: Int
    public var h3Count: Int
    public var h4Count: Int
    public var h5Count: Int
    public var h6Count: Int
    public var headingIssues: String
    public var canonical: String
    public var canonicalState: String
    public var metaRobots: String
    public var inSitemap: String
    public var redirectTarget: String
    public var imagesWithoutAlt: Int
    public var imagesEmptyAlt: Int
    /// Картинок с alt длиннее порога `altMax`.
    public var imagesLongAlt: Int
    public var issuesCount: Int
    public var charset: String

    public var depthText: String { depth < 0 ? "—" : String(depth) }
    /// HTML-страница с кодом 200: только у неё проверяются title, description, H1, canonical.
    public var isContent: Bool { status == 200 && contentType.contains("html") }

    public static func build(_ data: CrawlData, _ a: CrawlAnalysis) -> [PageRow] {
        let robots = data.robotsText.map(RobotsTxt.init(text:))
        return data.pages.map { p in
            let m = a.metrics[p.id] ?? PageMetrics()
            let h = p.html
            let levels = h?.headings.map(\.level) ?? []
            func count(_ l: Int) -> Int { levels.filter { $0 == l }.count }
            var headingIssues: [String] = []
            if m.issues.contains(.h1TooLong) { headingIssues.append("длинный H1") }
            if m.issues.contains(.h2Missing) { headingIssues.append("нет H2") }
            if m.issues.contains(.h2TooLong) { headingIssues.append("длинный H2") }
            if m.issues.contains(.h2Duplicate) { headingIssues.append("H2 повторяется") }
            if m.issues.contains(.headingSkippedLevel) { headingIssues.append("пропуск уровня") }
            if m.issues.contains(.headingEmpty) { headingIssues.append("пустые") }
            if m.issues.contains(.headingBeforeH1) { headingIssues.append("до H1") }
            let canonicalURL = m.canonicalTarget.map { data.url($0) } ?? ""
            let canonicalState: String
            if let ct = m.canonicalTarget { canonicalState = ct == p.id ? "на себя" : "на другой" }
            else { canonicalState = p.isContentPage ? "нет" : "" }
            let statusText: String
            switch p.state {
            case .blockedByRobots: statusText = "robots.txt"
            case .failed: statusText = p.error ?? "ошибка"
            case .fetched: statusText = String(p.statusCode)
            }
            let title = h?.title ?? ""
            let desc = h?.description ?? ""
            return PageRow(
                id: p.id,
                url: URLNormalizer.display(p.url),
                rawURL: p.url,
                status: p.statusCode,
                statusText: statusText,
                indexable: m.indexability.isIndexable,
                indexability: m.indexability.title,
                robotsRule: data.robotsRule(for: p, parsed: robots),
                contentType: p.contentType.split(separator: ";").first.map(String.init) ?? "",
                responseMs: p.responseTimeMs,
                sizeKB: (Double(p.sizeBytes) / 1024 * 10).rounded() / 10,
                depth: m.depth ?? -1,
                inlinks: m.inlinks,
                uniqueInlinks: m.uniqueInlinks,
                outInternal: m.outInternal,
                outExternal: m.outExternal,
                words: h?.wordCount ?? 0,
                title: title,
                titleLength: title.count,
                titleCount: h?.titles.count ?? 0,
                description: desc,
                descriptionLength: desc.count,
                h1: h?.h1s.first ?? "",
                h1Count: count(1),
                h2: h?.firstH2 ?? "",
                h2Count: count(2),
                h3Count: count(3),
                h4Count: count(4),
                h5Count: count(5),
                h6Count: count(6),
                headingIssues: headingIssues.joined(separator: ", "),
                canonical: URLNormalizer.display(canonicalURL),
                canonicalState: canonicalState,
                metaRobots: (h?.metaRobots ?? []).joined(separator: "; "),
                inSitemap: data.sitemapIds.contains(p.id) ? "да" : "",
                redirectTarget: p.redirectURL.map(URLNormalizer.display) ?? "",
                imagesWithoutAlt: h?.imagesWithoutAlt ?? 0,
                imagesEmptyAlt: h?.imagesEmptyAlt ?? 0,
                imagesLongAlt: h?.longAltCount(max: data.config.thresholds.altMax) ?? 0,
                issuesCount: m.issues.count,
                charset: p.charset
            )
        }
    }
}

extension CrawlData {
    /// Правило robots.txt, запретившее страницу, с группой: «Disallow: /blocked/ (User-agent: *)».
    /// Пусто — страница не запрещена. Считается по сохранённому тексту robots.txt, поэтому работает и на старых обходах.
    /// shortcut: в обходе хранится robots.txt только стартового хоста — для других хостов (режим «С поддоменами»)
    /// правило не показывается. Переделать, если понадобится: запоминать правило в записи страницы при обходе.
    public func robotsRule(for p: PageRecord, parsed: RobotsTxt? = nil) -> String {
        guard p.state == .blockedByRobots,
              let robots = parsed ?? robotsText.map(RobotsTxt.init(text:)),
              let start = startId, CrawlScope.origin(of: p.url) == CrawlScope.origin(of: url(start)),
              let decided = robots.decisiveRule(RobotsTxt.pathAndQuery(of: p.url), token: config.userAgentPreset.robotsToken),
              !decided.rule.allow
        else { return "" }
        return "\(decided.rule.line) (User-agent: \(decided.agent))"
    }
}

/// Строка таблицы ссылок.
public struct LinkRow: Identifiable, Sendable, Hashable {
    /// Индекс в `CrawlData.links`.
    public var id: Int
    public var sourceId: Int32
    public var targetId: Int32
    public var source: String
    public var target: String
    public var anchor: String
    public var kind: String
    public var rel: String
    public var zone: String
    public var external: Bool
    public var place: String { external ? "внешняя" : "внутренняя" }
    /// Код ответа цели, если она загружена: 0 — не загружалась.
    public var targetStatus: Int
    public var targetStatusText: String

    public static func make(_ i: Int, _ l: LinkRecord, _ data: CrawlData, display: [String]? = nil) -> LinkRow {
        func show(_ id: Int32) -> String {
            if let display, Int(id) < display.count { return display[Int(id)] }
            return URLNormalizer.display(data.url(id))
        }
        let target = data.page(l.target)
        let statusText: String
        if let t = target {
            switch t.state {
            case .blockedByRobots: statusText = "robots.txt"
            case .failed: statusText = "ошибка"
            case .fetched: statusText = String(t.statusCode)
            }
        } else {
            statusText = ""
        }
        return LinkRow(
            id: i, sourceId: l.source, targetId: l.target,
            source: show(l.source),
            target: show(l.target),
            anchor: l.anchor, kind: l.kind.title, rel: l.rel.title, zone: l.zone.title,
            external: l.external,
            targetStatus: target?.statusCode ?? 0,
            targetStatusText: statusText
        )
    }

    public var isBroken: Bool { targetStatus >= 400 || targetStatusText == "ошибка" }
    public var isToRedirect: Bool { (300..<400).contains(targetStatus) }
}

/// Строка таблицы редиректов.
public struct RedirectRow: Identifiable, Sendable, Hashable {
    public var id: Int32
    public var url: String
    public var status: Int
    public var target: String
    public var finalURL: String
    public var finalStatus: Int
    public var hops: Int
    public var loop: String
    public var inlinks: Int

    public static func build(_ data: CrawlData, _ a: CrawlAnalysis) -> [RedirectRow] {
        data.pages.filter(\.isRedirect).map { p in
            let r = a.redirects[p.id]
            return RedirectRow(
                id: p.id, url: URLNormalizer.display(p.url), status: p.statusCode,
                target: p.redirectURL.map(URLNormalizer.display) ?? "",
                finalURL: r.map { URLNormalizer.display($0.finalURL) } ?? "",
                finalStatus: r?.finalStatus ?? 0, hops: r?.hops ?? 1,
                loop: r?.loop == true ? "петля" : "",
                inlinks: a.metrics[p.id]?.inlinks ?? 0
            )
        }
    }
}

// MARK: - CSV

public struct CSVColumn<Row>: Sendable {
    public var title: String
    public var value: @Sendable (Row) -> String
    public init(_ title: String, _ value: @escaping @Sendable (Row) -> String) {
        self.title = title
        self.value = value
    }
}

public enum CSVDelimiter: String, CaseIterable, Sendable {
    case semicolon = ";", comma = ","
    public var title: String { self == .semicolon ? "Точка с запятой (Excel, русская локаль)" : "Запятая" }
}

public enum CSVWriter {
    /// UTF-8 с BOM, строки через CRLF — Excel и Numbers открывают кириллицу без настройки.
    public static func make<Row>(_ rows: [Row], columns: [CSVColumn<Row>], delimiter: CSVDelimiter = .semicolon) -> Data {
        var out = "\u{FEFF}"
        let d = delimiter.rawValue
        out += columns.map { escape($0.title, d) }.joined(separator: d) + "\r\n"
        for r in rows {
            out += columns.map { escape($0.value(r), d) }.joined(separator: d) + "\r\n"
        }
        return Data(out.utf8)
    }

    static func escape(_ s: String, _ d: String) -> String {
        var v = s
        // Защита от выполнения формул в Excel.
        if let f = v.first, "=+@".contains(f) { v = "'" + v }
        if v.contains(d) || v.contains("\"") || v.contains("\n") || v.contains("\r") || v.hasPrefix(" ") || v.hasSuffix(" ") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}

public enum CSVColumns {
    public static let pages: [CSVColumn<PageRow>] = [
        .init("URL") { $0.url },
        .init("Код") { $0.statusText },
        .init("Индексируемость") { $0.indexability },
        .init("Правило robots.txt") { $0.robotsRule },
        .init("Тип") { $0.contentType },
        .init("Время ответа, мс") { String($0.responseMs) },
        .init("Размер, КБ") { String($0.sizeKB) },
        .init("Глубина") { $0.depthText },
        .init("Входящие") { String($0.inlinks) },
        .init("Уникальные входящие") { String($0.uniqueInlinks) },
        .init("Исходящие внутренние") { String($0.outInternal) },
        .init("Исходящие внешние") { String($0.outExternal) },
        .init("Слов") { String($0.words) },
        .init("В sitemap") { $0.inSitemap },
        .init("Редирект на") { $0.redirectTarget },
        .init("Кодировка") { $0.charset },
        .init("Проблем") { String($0.issuesCount) },
    ]

    public static let meta: [CSVColumn<PageRow>] = [
        .init("URL") { $0.url },
        .init("Код") { $0.statusText },
        .init("Title") { $0.title },
        .init("Длина title") { String($0.titleLength) },
        .init("Title на странице") { String($0.titleCount) },
        .init("Description") { $0.description },
        .init("Длина description") { String($0.descriptionLength) },
        .init("Canonical") { $0.canonical },
        .init("Canonical — куда") { $0.canonicalState },
        .init("Meta robots") { $0.metaRobots },
        .init("Индексируемость") { $0.indexability },
    ]

    public static let headings: [CSVColumn<PageRow>] = [
        .init("URL") { $0.url },
        .init("H1") { $0.h1 },
        .init("Число H1") { String($0.h1Count) },
        .init("H2") { String($0.h2Count) },
        .init("H3") { String($0.h3Count) },
        .init("H4") { String($0.h4Count) },
        .init("H5") { String($0.h5Count) },
        .init("H6") { String($0.h6Count) },
        .init("Проблемы заголовков") { $0.headingIssues },
        .init("Title") { $0.title },
    ]

    public static let links: [CSVColumn<LinkRow>] = [
        .init("Источник") { $0.source },
        .init("Цель") { $0.target },
        .init("Анкор") { $0.anchor },
        .init("Тип") { $0.kind },
        .init("rel") { $0.rel },
        .init("Зона") { $0.zone },
        .init("Внутренняя/внешняя") { $0.place },
        .init("Код цели") { $0.targetStatusText },
    ]

    public static let redirects: [CSVColumn<RedirectRow>] = [
        .init("URL") { $0.url },
        .init("Код") { String($0.status) },
        .init("Куда") { $0.target },
        .init("Конечный URL") { $0.finalURL },
        .init("Код конечного") { $0.finalStatus == 0 ? "" : String($0.finalStatus) },
        .init("Шагов") { String($0.hops) },
        .init("Петля") { $0.loop },
        .init("Входящие") { String($0.inlinks) },
    ]

    /// Все заголовки страниц по порядку — по строке на заголовок.
    public static func headingOutline(_ data: CrawlData) -> Data {
        struct R { var url: String; var level: Int; var text: String; var order: Int }
        var rows: [R] = []
        for p in data.pages where p.isContentPage {
            for (i, h) in (p.html?.headings ?? []).enumerated() {
                rows.append(R(url: URLNormalizer.display(p.url), level: h.level, text: h.text, order: i + 1))
            }
        }
        let cols: [CSVColumn<R>] = [
            .init("URL") { $0.url }, .init("№") { String($0.order) },
            .init("Уровень") { "H\($0.level)" }, .init("Текст") { $0.text },
        ]
        return CSVWriter.make(rows, columns: cols)
    }
}
