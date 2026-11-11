import Foundation

// MARK: - Данные обхода в памяти

/// Всё, что известно об обходе. Значение (struct), чтобы анализ шёл на снимке в фоне.
public struct CrawlData: Sendable {
    public var config: CrawlConfig
    public var urls: [String] = []
    public var pages: [PageRecord] = []
    public var pageIndex: [Int32: Int] = [:]
    public var links: [LinkRecord] = []
    public var sitemapIds: Set<Int32> = []
    public var startId: Int32?
    public var robotsText: String?

    public init(config: CrawlConfig) { self.config = config }

    public init(stored: StoredCrawl) {
        config = stored.config
        urls = stored.urls
        pages = stored.pages
        for (i, p) in pages.enumerated() { pageIndex[p.id] = i }
        links = stored.links
        sitemapIds = Set(stored.sitemapIds)
        startId = stored.startId
        robotsText = stored.robotsText
    }

    public mutating func apply(_ batch: CrawlBatch) {
        for u in batch.newURLs {
            let i = Int(u.id)
            if i == urls.count { urls.append(u.url) }
            else if i > urls.count {
                urls += Array(repeating: "", count: i - urls.count)
                urls.append(u.url)
            } else { urls[i] = u.url }
        }
        for p in batch.pages {
            if let i = pageIndex[p.id] { pages[i] = p }
            else {
                pageIndex[p.id] = pages.count
                pages.append(p)
            }
        }
        links += batch.links
        sitemapIds.formUnion(batch.sitemapIds)
        if let s = batch.startId { startId = s }
        if let r = batch.robotsText { robotsText = r }
    }

    public func url(_ id: Int32) -> String {
        let i = Int(id)
        return i >= 0 && i < urls.count ? urls[i] : ""
    }

    public func page(_ id: Int32) -> PageRecord? {
        pageIndex[id].map { pages[$0] }
    }
}

// MARK: - Индексируемость

public enum Indexability: Sendable, Equatable, Hashable {
    case indexable
    case blockedByRobots
    case failed
    case redirect(Int)
    case status(Int)
    case noindex
    case canonicalized

    public var isIndexable: Bool { self == .indexable }

    public var title: String {
        switch self {
        case .indexable: "Индексируется"
        case .blockedByRobots: "Запрет в robots.txt"
        case .failed: "Ошибка загрузки"
        case .redirect(let c): "Редирект \(c)"
        case .status(let c): "Код \(c)"
        case .noindex: "noindex"
        case .canonicalized: "Canonical на другой URL"
        }
    }
}

// MARK: - Проблемы

public enum IssueSeverity: Int, Sendable, Comparable, CaseIterable {
    case error = 0, warning = 1, notice = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
        switch self {
        case .error: "Ошибка"
        case .warning: "Предупреждение"
        case .notice: "Замечание"
        }
    }
}

public enum IssueGroup: String, Sendable, CaseIterable {
    case title, description, h1, headings, responses, indexing, hreflang, links, content
    public var title: String {
        switch self {
        case .hreflang: "Hreflang"
        case .title: "Title"
        case .description: "Description"
        case .h1: "H1"
        case .headings: "Заголовки"
        case .responses: "Ответы сервера"
        case .indexing: "Индексация"
        case .links: "Ссылки"
        case .content: "Контент"
        }
    }
}

public enum IssueID: String, Sendable, CaseIterable, Hashable {
    case titleMissing, titleDuplicate, titleTooShort, titleTooLong, titleMultiple
    case descriptionMissing, descriptionDuplicate, descriptionTooShort, descriptionTooLong, descriptionMultiple
    case h1Missing, h1Multiple, h1Empty, h1Duplicate, h1EqualsTitle, h1TooLong
    case headingSkippedLevel, headingEmpty, headingBeforeH1, h2Missing, h2TooLong, h2Duplicate
    case client4xx, server5xx, connectionError, redirect3xx, redirectChain, redirectLoop, slowResponse
    case noindex, canonicalOther, canonicalToNon200, nonIndexableInSitemap, blockedByRobots, urlVariantDuplicate
    case canonicalMissing, canonicalMultipleSame, canonicalMultipleDifferent, canonicalRelative
    case brokenInternalLinks, linksToRedirects, internalNofollow, orphanPages, deepPages, fewInlinks
    case hreflangNoReturn, hreflangNoSelf, hreflangNoXDefault, hreflangTargetNon200, hreflangInvalidCode
    case duplicateContent, lowWordCount, imagesWithoutAlt, imagesEmptyAlt, imagesLongAlt

    public var group: IssueGroup {
        switch self {
        case .titleMissing, .titleDuplicate, .titleTooShort, .titleTooLong, .titleMultiple: .title
        case .descriptionMissing, .descriptionDuplicate, .descriptionTooShort, .descriptionTooLong, .descriptionMultiple: .description
        case .h1Missing, .h1Multiple, .h1Empty, .h1Duplicate, .h1EqualsTitle, .h1TooLong: .h1
        case .headingSkippedLevel, .headingEmpty, .headingBeforeH1, .h2Missing, .h2TooLong, .h2Duplicate: .headings
        case .client4xx, .server5xx, .connectionError, .redirect3xx, .redirectChain, .redirectLoop, .slowResponse: .responses
        case .noindex, .canonicalOther, .canonicalToNon200, .nonIndexableInSitemap, .blockedByRobots, .urlVariantDuplicate,
             .canonicalMissing, .canonicalMultipleSame, .canonicalMultipleDifferent, .canonicalRelative: .indexing
        case .brokenInternalLinks, .linksToRedirects, .internalNofollow, .orphanPages, .deepPages, .fewInlinks: .links
        case .hreflangNoReturn, .hreflangNoSelf, .hreflangNoXDefault, .hreflangTargetNon200, .hreflangInvalidCode: .hreflang
        case .duplicateContent, .lowWordCount, .imagesWithoutAlt, .imagesEmptyAlt, .imagesLongAlt: .content
        }
    }

    public var severity: IssueSeverity {
        switch self {
        case .titleMissing, .h1Missing, .client4xx, .server5xx, .connectionError, .redirectLoop,
             .brokenInternalLinks, .canonicalToNon200, .duplicateContent, .titleDuplicate, .canonicalMultipleDifferent:
            .error
        case .titleTooLong, .titleTooShort, .titleMultiple, .descriptionMissing, .descriptionDuplicate,
             .descriptionMultiple, .h1Multiple, .h1Empty, .h1Duplicate, .redirectChain, .noindex,
             .nonIndexableInSitemap, .linksToRedirects, .orphanPages, .urlVariantDuplicate, .headingEmpty, .slowResponse,
             .imagesWithoutAlt, .canonicalMultipleSame,
             .hreflangNoReturn, .hreflangNoSelf, .hreflangNoXDefault, .hreflangTargetNon200, .hreflangInvalidCode:
            .warning
        case .descriptionTooShort, .descriptionTooLong, .h1EqualsTitle, .headingSkippedLevel, .headingBeforeH1,
             .redirect3xx, .canonicalOther, .blockedByRobots, .internalNofollow, .deepPages, .fewInlinks,
             .lowWordCount, .imagesEmptyAlt, .imagesLongAlt, .h1TooLong, .h2Missing, .h2TooLong, .h2Duplicate,
             .canonicalMissing, .canonicalRelative:
            .notice
        }
    }

    public func title(_ t: Thresholds) -> String {
        switch self {
        case .titleMissing: "Title отсутствует или пустой"
        case .titleDuplicate: "Title повторяется на разных страницах"
        case .titleTooShort: "Title короче \(t.titleMin) символов"
        case .titleTooLong: "Title длиннее \(t.titleMax) символов"
        case .titleMultiple: "Несколько title на странице"
        case .descriptionMissing: "Description отсутствует или пустой"
        case .descriptionDuplicate: "Description повторяется"
        case .descriptionTooShort: "Description короче \(t.descriptionMin) символов"
        case .descriptionTooLong: "Description длиннее \(t.descriptionMax) символов"
        case .descriptionMultiple: "Несколько description на странице"
        case .h1Missing: "Нет H1"
        case .h1Multiple: "Несколько H1"
        case .h1Empty: "Пустой H1"
        case .h1Duplicate: "H1 повторяется на разных страницах"
        case .h1EqualsTitle: "H1 совпадает с title"
        case .h1TooLong: "H1 длиннее \(t.h1Max) символов"
        case .headingSkippedLevel: "Пропуск уровня заголовка (например, H2 → H4)"
        case .headingEmpty: "Пустые заголовки H2–H6"
        case .headingBeforeH1: "H2–H6 стоят раньше H1"
        case .h2Missing: "Нет H2"
        case .h2TooLong: "H2 длиннее \(t.h2Max) символов"
        case .h2Duplicate: "Первый H2 повторяется на разных страницах"
        case .client4xx: "Код 4xx"
        case .server5xx: "Код 5xx"
        case .connectionError: "Ошибка соединения"
        case .redirect3xx: "Редирект 3xx"
        case .redirectChain: "Цепочка из 2+ редиректов"
        case .redirectLoop: "Петля редиректов"
        case .slowResponse: "Ответ дольше \(t.slowResponseMs) мс"
        case .noindex: "noindex"
        case .canonicalOther: "Canonical указывает на другой URL"
        case .canonicalToNon200: "Canonical ведёт на страницу не с кодом 200"
        case .nonIndexableInSitemap: "Неиндексируемая страница в sitemap"
        case .blockedByRobots: "Запрещено в robots.txt"
        case .urlVariantDuplicate: "Дубль URL: слэш на конце или регистр"
        case .canonicalMissing: "Нет canonical"
        case .canonicalMultipleSame: "Несколько одинаковых canonical"
        case .canonicalMultipleDifferent: "Несколько разных canonical"
        case .canonicalRelative: "Canonical с относительным адресом"
        case .hreflangNoReturn: "Hreflang: нет обратной ссылки со страницы-перевода"
        case .hreflangNoSelf: "Hreflang: нет ссылки на саму страницу"
        case .hreflangNoXDefault: "Hreflang: нет x-default"
        case .hreflangTargetNon200: "Hreflang ведёт на страницу не с кодом 200"
        case .hreflangInvalidCode: "Hreflang: неверный код языка или региона"
        case .brokenInternalLinks: "Есть битые внутренние ссылки"
        case .linksToRedirects: "Есть ссылки на редиректы"
        case .internalNofollow: "Есть внутренние ссылки с nofollow"
        case .orphanPages: "Сирота: есть в sitemap, входящих ссылок нет"
        case .deepPages: "Глубже \(t.maxClickDepth) кликов от главной"
        case .fewInlinks: "Мало входящих ссылок (1–\(t.fewInlinksMax))"
        case .duplicateContent: "Полный дубль текста"
        case .lowWordCount: "Меньше \(t.minWords) слов"
        case .imagesWithoutAlt: "Картинки без атрибута alt"
        case .imagesEmptyAlt: "Картинки с пустым alt"
        case .imagesLongAlt: "Alt длиннее \(t.altMax) символов"
        }
    }

    /// Проблемы, которые точны только после завершения обхода.
    public var needsFullCrawl: Bool {
        switch self {
        case .titleDuplicate, .descriptionDuplicate, .h1Duplicate, .h2Duplicate, .duplicateContent, .urlVariantDuplicate,
             .orphanPages, .deepPages, .fewInlinks, .brokenInternalLinks, .linksToRedirects, .canonicalToNon200,
             .redirectChain, .redirectLoop, .hreflangNoReturn, .hreflangTargetNon200:
            true
        default:
            false
        }
    }
}

// MARK: - Результат анализа

public struct PageMetrics: Sendable, Equatable {
    public var depth: Int?
    public var inlinks = 0
    public var uniqueInlinks = 0
    public var outInternal = 0
    public var outExternal = 0
    public var brokenOutlinks = 0
    public var redirectOutlinks = 0
    public var nofollowOutlinks = 0
    public var canonicalTarget: Int32?
    /// Все canonical страницы (HTML и заголовок Link) после нормализации, по порядку.
    public var canonicalTargets: [Int32] = []
    public var indexability: Indexability = .indexable
    public var issues: [IssueID] = []
}

public struct RedirectInfo: Sendable, Equatable {
    public var finalId: Int32?
    public var finalURL: String
    public var finalStatus: Int
    public var hops: Int
    public var loop: Bool
}

public struct CrawlAnalysis: Sendable {
    public var metrics: [Int32: PageMetrics] = [:]
    public var issues: [IssueID: [Int32]] = [:]
    public var redirects: [Int32: RedirectInfo] = [:]
    /// Индексы ссылок в `CrawlData.links` по цели и по источнику.
    public var inlinks: [Int32: [Int]] = [:]
    public var outlinks: [Int32: [Int]] = [:]
    public var linkCount = 0
    public var pageCount = 0

    public init() {}
    public static let empty = CrawlAnalysis()
}

public enum CrawlAnalyzer {
    public static func analyze(_ data: CrawlData) -> CrawlAnalysis {
        var a = CrawlAnalysis()
        let t = data.config.thresholds
        a.linkCount = data.links.count
        a.pageCount = data.pages.count
        for p in data.pages { a.metrics[p.id] = PageMetrics() }

        // 1. Ссылки: индексы, входящие/исходящие, битые.
        var uniqueSources: [Int32: Set<Int32>] = [:]
        var adjacency: [Int32: [Int32]] = [:]
        /// Цели hreflang по странице-источнику.
        var hreflangTargets: [Int32: [Int32]] = [:]
        for (i, l) in data.links.enumerated() {
            a.outlinks[l.source, default: []].append(i)
            a.inlinks[l.target, default: []].append(i)
            switch l.kind {
            case .canonical:
                if a.metrics[l.source]?.canonicalTarget == nil { a.metrics[l.source]?.canonicalTarget = l.target }
                a.metrics[l.source]?.canonicalTargets.append(l.target)
                continue
            case .redirect:
                if !l.external { adjacency[l.source, default: []].append(l.target) }
                continue
            case .hreflang:
                hreflangTargets[l.source, default: []].append(l.target)
                continue
            case .anchor, .image:
                break
            }
            if l.external {
                a.metrics[l.source]?.outExternal += 1
                continue
            }
            a.metrics[l.source]?.outInternal += 1
            adjacency[l.source, default: []].append(l.target)
            if l.rel.contains(.nofollow) { a.metrics[l.source]?.nofollowOutlinks += 1 }
            if l.target != l.source {
                a.metrics[l.target]?.inlinks += 1
                uniqueSources[l.target, default: []].insert(l.source)
            }
            if let target = data.page(l.target) {
                if target.state == .failed || target.statusCode >= 400 { a.metrics[l.source]?.brokenOutlinks += 1 }
                else if target.isRedirect { a.metrics[l.source]?.redirectOutlinks += 1 }
            }
        }
        for (id, set) in uniqueSources { a.metrics[id]?.uniqueInlinks = set.count }

        // 2. Глубина: кратчайший путь по ссылкам от стартовой страницы.
        if data.config.mode == .spider, let start = data.startId {
            var depth: [Int32: Int] = [start: 0]
            var queue = [start]
            var head = 0
            while head < queue.count {
                let cur = queue[head]
                head += 1
                // Идём дальше только от загруженных страниц.
                guard data.pageIndex[cur] != nil, let d = depth[cur] else { continue }
                for next in adjacency[cur] ?? [] where depth[next] == nil {
                    depth[next] = d + 1
                    queue.append(next)
                }
            }
            for (id, d) in depth where a.metrics[id] != nil { a.metrics[id]?.depth = d }
        }

        // 3. Редиректы: конечная точка и число шагов.
        for p in data.pages where p.isRedirect {
            var hops = 1
            var visited: Set<Int32> = [p.id]
            var cur = p
            var loop = false
            while let next = cur.redirectTo, let np = data.page(next) {
                if visited.contains(next) { loop = true; break }
                visited.insert(next)
                cur = np
                if np.isRedirect { hops += 1 } else { break }
            }
            let finalURL = cur.isRedirect ? (cur.redirectURL ?? cur.url) : cur.url
            a.redirects[p.id] = RedirectInfo(finalId: cur.isRedirect ? cur.redirectTo : cur.id, finalURL: finalURL,
                                             finalStatus: cur.isRedirect ? (data.page(cur.redirectTo ?? -1)?.statusCode ?? 0) : cur.statusCode,
                                             hops: hops, loop: loop)
        }

        // 4. Индексируемость.
        let preset = data.config.userAgentPreset
        for p in data.pages {
            let ct = a.metrics[p.id]?.canonicalTarget
            a.metrics[p.id]?.indexability = indexability(of: p, canonicalTarget: ct, preset: preset)
        }

        // 5. Дубли среди индексируемых страниц с контентом.
        var titles: [String: [Int32]] = [:]
        var descs: [String: [Int32]] = [:]
        var h1s: [String: [Int32]] = [:]
        var h2s: [String: [Int32]] = [:]
        var hashes: [String: [Int32]] = [:]
        var variants: [String: [Int32]] = [:]
        for p in data.pages where p.isContentPage && a.metrics[p.id]?.indexability.isIndexable == true {
            guard let h = p.html else { continue }
            if let s = key(h.title) { titles[s, default: []].append(p.id) }
            if let s = key(h.description) { descs[s, default: []].append(p.id) }
            if let s = key(h.h1s.first) { h1s[s, default: []].append(p.id) }
            if let s = key(h.firstH2) { h2s[s, default: []].append(p.id) }
            if !h.contentHash.isEmpty, h.wordCount > 0 { hashes[h.contentHash, default: []].append(p.id) }
            variants[variantKey(p.url), default: []].append(p.id)
        }
        func dupSet(_ m: [String: [Int32]]) -> Set<Int32> {
            Set(m.values.filter { $0.count > 1 }.flatMap { $0 })
        }
        let dupTitles = dupSet(titles), dupDescs = dupSet(descs), dupH1 = dupSet(h1s), dupH2 = dupSet(h2s)
        let dupContent = dupSet(hashes), dupVariants = dupSet(variants)

        // 6. Проблемы по страницам.
        let isSpider = data.config.mode == .spider
        for p in data.pages {
            guard var m = a.metrics[p.id] else { continue }
            var issues: [IssueID] = []
            func add(_ i: IssueID) { issues.append(i) }

            switch p.state {
            case .blockedByRobots: add(.blockedByRobots)
            case .failed: add(.connectionError)
            case .fetched:
                if (400..<500).contains(p.statusCode) { add(.client4xx) }
                if p.statusCode >= 500 { add(.server5xx) }
                if p.isRedirect {
                    add(.redirect3xx)
                    if let r = a.redirects[p.id] {
                        if r.loop { add(.redirectLoop) } else if r.hops >= 2 { add(.redirectChain) }
                    }
                }
                if p.responseTimeMs > t.slowResponseMs { add(.slowResponse) }
            }

            switch m.indexability {
            case .noindex: add(.noindex)
            case .canonicalized: add(.canonicalOther)
            default: break
            }
            if let ct = m.canonicalTarget, ct != p.id, let target = data.page(ct), target.state != .fetched || target.statusCode != 200 {
                add(.canonicalToNon200)
            }
            if data.sitemapIds.contains(p.id), !m.indexability.isIndexable { add(.nonIndexableInSitemap) }

            if p.isContentPage, let h = p.html {
                let title = h.title ?? ""
                if title.isEmpty { add(.titleMissing) }
                else {
                    if title.count < t.titleMin { add(.titleTooShort) }
                    if title.count > t.titleMax { add(.titleTooLong) }
                }
                if h.titles.count > 1 { add(.titleMultiple) }
                if dupTitles.contains(p.id) { add(.titleDuplicate) }

                let desc = h.description ?? ""
                if desc.isEmpty { add(.descriptionMissing) }
                else {
                    if desc.count < t.descriptionMin { add(.descriptionTooShort) }
                    if desc.count > t.descriptionMax { add(.descriptionTooLong) }
                }
                if h.descriptions.count > 1 { add(.descriptionMultiple) }
                if dupDescs.contains(p.id) { add(.descriptionDuplicate) }

                let h1 = h.h1s
                if h1.isEmpty { add(.h1Missing) }
                if h1.count > 1 { add(.h1Multiple) }
                if h1.contains(where: { $0.isEmpty }) { add(.h1Empty) }
                if dupH1.contains(p.id) { add(.h1Duplicate) }
                if let first = h1.first, !first.isEmpty, first.lowercased() == title.lowercased() { add(.h1EqualsTitle) }
                if h1.contains(where: { $0.count > t.h1Max }) { add(.h1TooLong) }

                if hasSkippedLevel(h.headings) { add(.headingSkippedLevel) }
                if h.headings.contains(where: { $0.level > 1 && $0.text.isEmpty }) { add(.headingEmpty) }
                if let firstH1 = h.headings.firstIndex(where: { $0.level == 1 }), h.headings[..<firstH1].contains(where: { $0.level > 1 }) {
                    add(.headingBeforeH1)
                }
                let h2 = h.headings.filter { $0.level == 2 }.map(\.text)
                if h2.isEmpty { add(.h2Missing) }
                if h2.contains(where: { $0.count > t.h2Max }) { add(.h2TooLong) }
                if dupH2.contains(p.id) { add(.h2Duplicate) }

                // Canonical: адреса сравниваются после нормализации, чтобы `/about/` и полный адрес были одним.
                if m.canonicalTargets.isEmpty, h.canonicals.isEmpty { add(.canonicalMissing) }
                if m.canonicalTargets.count > 1 {
                    add(Set(m.canonicalTargets).count > 1 ? .canonicalMultipleDifferent : .canonicalMultipleSame)
                }
                if h.canonicals.contains(where: isRelativeURL) { add(.canonicalRelative) }

                if !h.hreflang.isEmpty {
                    if h.hreflang.contains(where: { !isValidHreflang($0.lang) }) { add(.hreflangInvalidCode) }
                    if !h.hreflang.contains(where: { $0.lang.lowercased() == "x-default" }) { add(.hreflangNoXDefault) }
                    // Проверки по целям — только если обходчик записал связи hreflang:
                    // в обходах до 2026-11-11 их нет, и без этого условия «нет ссылки на себя» было бы везде.
                    let targets = hreflangTargets[p.id] ?? []
                    if !targets.isEmpty {
                        if !targets.contains(p.id) { add(.hreflangNoSelf) }
                        if targets.contains(where: { t in data.page(t).map { $0.state == .failed || ($0.state == .fetched && $0.statusCode != 200) } ?? false }) {
                            add(.hreflangTargetNon200)
                        }
                        let noReturn = targets.contains { t in
                            guard t != p.id, let tp = data.page(t), tp.isContentPage else { return false }
                            return !(hreflangTargets[t] ?? []).contains(p.id)
                        }
                        if noReturn { add(.hreflangNoReturn) }
                    }
                }

                if dupContent.contains(p.id) { add(.duplicateContent) }
                if dupVariants.contains(p.id) { add(.urlVariantDuplicate) }
                if h.wordCount < t.minWords { add(.lowWordCount) }
                if h.imagesWithoutAlt > 0 { add(.imagesWithoutAlt) }
                if h.imagesEmptyAlt > 0 { add(.imagesEmptyAlt) }
                if h.longAltCount(max: t.altMax) > 0 { add(.imagesLongAlt) }

                if m.brokenOutlinks > 0 { add(.brokenInternalLinks) }
                if m.redirectOutlinks > 0 { add(.linksToRedirects) }
                if m.nofollowOutlinks > 0 { add(.internalNofollow) }

                if isSpider, m.indexability.isIndexable, p.id != data.startId {
                    if data.sitemapIds.contains(p.id), m.uniqueInlinks == 0 { add(.orphanPages) }
                    if let d = m.depth, d > t.maxClickDepth { add(.deepPages) }
                    if (1...max(1, t.fewInlinksMax)).contains(m.uniqueInlinks) { add(.fewInlinks) }
                }
            }

            m.issues = issues
            a.metrics[p.id] = m
            for i in issues { a.issues[i, default: []].append(p.id) }
        }
        return a
    }

    static func key(_ s: String?) -> String? {
        guard let s else { return nil }
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return k.isEmpty ? nil : k
    }

    /// Ключ для поиска дублей URL, отличающихся слэшем на конце или регистром пути.
    static func variantKey(_ url: String) -> String {
        var u = url.lowercased()
        if let q = u.firstIndex(of: "?") {
            let path = u[..<q]
            if path.hasSuffix("/"), path.filter({ $0 == "/" }).count > 3 { u = String(path.dropLast()) + u[q...] }
        } else if u.hasSuffix("/"), u.filter({ $0 == "/" }).count > 3 {
            u.removeLast()
        }
        return u
    }

    static let isoLanguages = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
    /// EU, EZ, UN, QO есть в списке Foundation, но это зарезервированные коды, а не страны ISO 3166-1.
    /// Google: EU, UN и UK в hreflang не действуют (developers.google.com, «Localized versions», проверено 2026-11-11).
    static let isoRegions = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) })
        .subtracting(["EU", "EZ", "UN", "QO"])

    /// Код hreflang: `x-default` или язык ISO 639-1, затем необязательные письменность ISO 15924 (4 буквы)
    /// и регион ISO 3166-1 alpha-2 через дефис: `ru`, `en-GB`, `zh-Hant-TW`. `ru-RUS`, `en-UK`, `en_US` — неверные.
    public static func isValidHreflang(_ code: String) -> Bool {
        let c = code.trimmingCharacters(in: .whitespaces)
        if c.lowercased() == "x-default" { return true }
        var parts = c.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, isoLanguages.contains(parts.removeFirst().lowercased()) else { return false }
        if let script = parts.first, script.count == 4 {
            guard Locale.Script(script.prefix(1).uppercased() + script.dropFirst().lowercased()).isISOScript else { return false }
            parts.removeFirst()
        }
        if let region = parts.first {
            guard isoRegions.contains(region.uppercased()) else { return false }
            parts.removeFirst()
        }
        return parts.isEmpty
    }

    /// Адрес без схемы: `/page`, `page`, `//example.ru/page`. Пустой не считается.
    public static func isRelativeURL(_ href: String) -> Bool {
        let s = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !s.isEmpty && !s.hasPrefix("http://") && !s.hasPrefix("https://")
    }

    static func hasSkippedLevel(_ headings: [Heading]) -> Bool {
        var prev = 0
        for h in headings {
            if prev > 0, h.level > prev + 1 { return true }
            prev = h.level
        }
        return false
    }

    static func indexability(of p: PageRecord, canonicalTarget: Int32?, preset: UserAgentPreset) -> Indexability {
        switch p.state {
        case .blockedByRobots: return .blockedByRobots
        case .failed: return .failed
        case .fetched: break
        }
        if p.isRedirect { return .redirect(p.statusCode) }
        if p.statusCode != 200 { return .status(p.statusCode) }
        var directives: [String] = p.html?.metaRobots ?? []
        let botName: String
        switch preset {
        case .googlebot:
            directives += p.html?.metaGooglebot ?? []
            botName = "googlebot"
        case .yandexbot:
            directives += p.html?.metaYandex ?? []
            botName = "yandex"
        case .seopars, .custom:
            directives += (p.html?.metaGooglebot ?? []) + (p.html?.metaYandex ?? [])
            botName = ""
        }
        if hasNoindex(directives) || xRobotsNoindex(p.xRobotsTag, bot: botName) { return .noindex }
        if let ct = canonicalTarget, ct != p.id { return .canonicalized }
        return .indexable
    }

    static func hasNoindex(_ values: [String]) -> Bool {
        values.contains { v in
            v.lowercased().split(separator: ",").contains {
                let d = $0.trimmingCharacters(in: .whitespaces)
                return d == "noindex" || d == "none"
            }
        }
    }

    /// X-Robots-Tag может быть с префиксом робота: `googlebot: noindex`.
    static func xRobotsNoindex(_ header: String, bot: String) -> Bool {
        guard !header.isEmpty else { return false }
        var currentBot = ""
        for part in header.lowercased().split(separator: ",") {
            var d = part.trimmingCharacters(in: .whitespaces)
            if let colon = d.firstIndex(of: ":") {
                let prefix = d[..<colon].trimmingCharacters(in: .whitespaces)
                if !["unavailable_after", "max-snippet", "max-image-preview", "max-video-preview"].contains(prefix) {
                    currentBot = prefix
                    d = d[d.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let applies = currentBot.isEmpty || bot.isEmpty || bot.hasPrefix(currentBot) || currentBot.hasPrefix(bot)
            if applies, d == "noindex" || d == "none" { return true }
        }
        return false
    }
}
