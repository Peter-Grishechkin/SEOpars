import Foundation
import Testing
@testable import SEOparsCore

/// Проверки из разбора Screaming Frog (SPEC п. 1.8, TASKS-SF-2026-11-09.md).
@Suite struct SFChecksTests {
    /// HTML-страница с кодом 200 и нормальными title, description, H1.
    static func page(_ id: Int32, _ url: String, _ edit: (inout HTMLInfo) -> Void = { _ in }) -> PageRecord {
        var p = PageRecord(id: id, url: url, state: .fetched)
        p.statusCode = 200
        p.contentType = "text/html"
        var info = HTMLInfo()
        info.titles = ["Нормальный заголовок страницы для теста \(id)"]
        info.descriptions = [String(repeating: "о", count: 100) + "\(id)"]
        info.headings = [Heading(level: 1, text: "H1 \(id)"), Heading(level: 2, text: "H2 \(id)")]
        info.wordCount = 300
        info.contentHash = "hash\(id)"
        edit(&info)
        p.html = info
        return p
    }

    static func crawl(_ pages: [PageRecord], links: [LinkRecord] = [], _ cfg: (inout CrawlConfig) -> Void = { _ in }) -> CrawlData {
        var c = CrawlConfig()
        c.startURL = pages.first?.url ?? ""
        cfg(&c)
        var d = CrawlData(config: c)
        let maxId = Int(pages.map(\.id).max() ?? 0)
        d.urls = Array(repeating: "", count: maxId + 1)
        for p in pages {
            d.urls[Int(p.id)] = p.url
            d.pageIndex[p.id] = d.pages.count
            d.pages.append(p)
        }
        d.links = links
        d.startId = pages.first?.id
        return d
    }

    static func ids(_ a: CrawlAnalysis, _ i: IssueID) -> Set<Int32> { Set(a.issues[i] ?? []) }

    // MARK: № 117, п. 4.1

    @Test func everyIssueHasHowToFix() {
        let t = Thresholds()
        for id in IssueID.allCases {
            let fix = id.howToFix(t).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!fix.isEmpty, "\(id)")
            #expect(fix != id.title(t), "\(id)")
        }
    }

    // MARK: № 103, п. 1.4

    @Test func metaRefreshParsing() {
        #expect(HTMLAnalyzer.parseMetaRefresh("0; url=/about/")?.url == "/about/")
        #expect(HTMLAnalyzer.parseMetaRefresh("0;URL='/x y'")?.url == "/x y")
        #expect(HTMLAnalyzer.parseMetaRefresh(" 5 , url = \"https://e.com/\" ")?.url == "https://e.com/")
        #expect(HTMLAnalyzer.parseMetaRefresh("0; /plain")?.url == "/plain")
        let reload = HTMLAnalyzer.parseMetaRefresh("30")
        #expect(reload?.delay == 30 && reload?.url == nil)
        #expect(HTMLAnalyzer.parseMetaRefresh("3.5; url=/a")?.delay == 3)
        #expect(HTMLAnalyzer.parseMetaRefresh("url=/a") == nil)
        #expect(HTMLAnalyzer.parseMetaRefresh("0url=/a") == nil)
    }

    static func record(_ contentType: String?, _ body: String, url: String = "https://e.com/p") -> PageRecord {
        var res = FetchResult()
        res.statusCode = 200
        if let contentType { res.headers["content-type"] = contentType }
        res.body = Data(body.utf8)
        let job = Crawler.Job(item: QueueItem(id: 1, depth: 0, priority: 0, seq: 0), url: url, normalizer: URLNormalizer())
        return Crawler.buildRecord(job: job, url: URL(string: url)!, res: res).0
    }

    @Test func contentTypeAndRefreshTargetInRecord() {
        let html = "<!doctype html><html><head><title>T</title><base href=\"https://e.com/dir/\"><meta http-equiv=\"refresh\" content=\"0; url=next\"></head><body></body></html>"
        let normal = Self.record("text/html; charset=utf-8", html)
        #expect(normal.sniffedHTML == nil)
        // Адрес перехода — относительно <base>.
        #expect(normal.html?.metaRefreshURL == "https://e.com/dir/next")
        // text/plain с HTML не разбирается, но отмечается; без заголовка — разбирается и отмечается.
        let plain = Self.record("text/plain; charset=utf-8", "\u{FEFF}<!-- x -->\n" + html)
        #expect(plain.sniffedHTML == true && plain.html == nil)
        let untyped = Self.record(nil, html)
        #expect(untyped.sniffedHTML == true && untyped.html != nil)
        // Текст с примером HTML внутри — не страница.
        #expect(Self.record("text/plain", "Пример кода: <html><head></head></html>").sniffedHTML == nil)
        #expect(Self.record("text/plain", "<header>не HTML-документ</header>").sniffedHTML == nil)
    }

    @Test func metaRefreshAndContentTypeChecks() {
        let clean = Self.page(0, "https://e.com/")
        let refresh = Self.page(1, "https://e.com/r") { $0.metaRefresh = "0; url=/about/"; $0.metaRefreshURL = "https://e.com/about/" }
        let reload = Self.page(2, "https://e.com/live") { $0.metaRefresh = "60" }
        var plain = PageRecord(id: 3, url: "https://e.com/plain", state: .fetched)
        plain.statusCode = 200
        plain.contentType = "text/plain"
        plain.sniffedHTML = true
        var untyped = Self.page(4, "https://e.com/untyped")
        untyped.sniffedHTML = true
        let ignored = Self.page(5, "https://e.com/empty-refresh") { $0.metaRefresh = "" }
        let a = CrawlAnalyzer.analyze(Self.crawl([clean, refresh, reload, plain, untyped, ignored]))
        #expect(Self.ids(a, .metaRefresh) == [1, 2])
        #expect(Self.ids(a, .nonHTMLContentType) == [3, 4])
        #expect(refresh.html?.metaRefreshSummary == "переход на https://e.com/about/ через 0 с")
        #expect(reload.html?.metaRefreshSummary == "перезагрузка этой же страницы через 60 с")
        #expect(IssueID.metaRefresh.severity == .warning && IssueID.nonHTMLContentType.severity == .warning)
    }

    // MARK: № 104, п. 1.5

    @Test func sitemapChecks() {
        let pages = [
            Self.page(0, "https://e.com/"), Self.page(1, "https://e.com/out"), Self.page(2, "https://e.com/twice"),
            Self.page(3, "https://e.com/closed") { $0.metaRobots = ["noindex"] },
        ]
        var d = Self.crawl(pages)
        d.sitemapIds = [0, 2]
        d.addSitemapFiles([
            SitemapEntry(id: 0, file: "https://e.com/a.xml"), SitemapEntry(id: 2, file: "https://e.com/a.xml"),
            SitemapEntry(id: 2, file: "https://e.com/b.xml"), SitemapEntry(id: 2, file: "https://e.com/b.xml"),
        ])
        #expect(d.sitemapFiles[2] == ["https://e.com/a.xml", "https://e.com/b.xml"])
        var a = CrawlAnalyzer.analyze(d)
        // Закрытая noindex страница вне sitemap — не проблема.
        #expect(Self.ids(a, .notInSitemap) == [1])
        #expect(Self.ids(a, .inMultipleSitemaps) == [2])
        #expect(IssueID.notInSitemap.severity == .notice && IssueID.inMultipleSitemaps.severity == .notice)
        // Sitemap не загрузился — «не в sitemap» молчит.
        d.sitemapIds = []
        a = CrawlAnalyzer.analyze(d)
        #expect(Self.ids(a, .notInSitemap).isEmpty)
    }

    /// Файл обхода до 2026-11-12: таблицы sitemap_files нет, а при открытии только для чтения она не создаётся.
    @Test func storeWithoutSitemapFilesTable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("seopars-old-\(UUID().uuidString).seocrawl")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        let store = try CrawlStore.create(at: file, config: CrawlConfig())
        try store.write(StoreWrite(sitemapIds: [0], meta: [:]))
        try store.db.exec("DROP TABLE sitemap_files")
        let old = try CrawlStore.open(at: file, readOnly: true).load()
        #expect(old.sitemapIds == [0] && old.sitemapFiles.isEmpty)
    }

    // MARK: № 112, п. 2.8

    @Test func headScan() {
        var r = HTMLAnalyzer.scanHead("""
        <!doctype html><html><head><title>T</title><img src=x><link rel="canonical" href="/a"><meta name="ROBOTS" content="noindex"></head><body></body></html>
        """)
        #expect(r.breaker == "<img>" && r.hidden == ["canonical", "meta robots"] && r.headCount == 1 && r.bodyCount == 1)
        // Код Метрики в noscript, «<body>» в скрипте и в комментарии не в счёт; <header> — не <head>.
        r = HTMLAnalyzer.scanHead("""
        <html><head><script>var s='<body><div>';</script><noscript><div><img src=x></div></noscript><!-- <body> -->\
        <link rel=canonical href=/a></head><body><header>h</header></body></html>
        """)
        #expect(r.breaker == nil && r.headCount == 1 && r.bodyCount == 1)
        // Недопустимый элемент после canonical ничего не прячет.
        r = HTMLAnalyzer.scanHead("<head><link rel=canonical href=/a><div>x</div></head><body></body>")
        #expect(r.breaker == nil && r.hidden.isEmpty)
        // Текст в head тоже его обрывает; регистр тегов не важен.
        r = HTMLAnalyzer.scanHead("<HEAD><title>T</title>&nbsp;<META NAME=robots CONTENT=noindex></HEAD><BODY>")
        #expect(r.breaker == "текст «&nbsp;»" && r.hidden == ["meta robots"])
        // «>» в значении атрибута не закрывает тег; два body; head нет.
        r = HTMLAnalyzer.scanHead("<html><meta content=\"a>b\" name=x><body><p>1</p><body class=w></html>")
        #expect(r.headCount == 0 && r.bodyCount == 2 && r.breaker == nil)
        // Теги внутри title — текст.
        r = HTMLAnalyzer.scanHead("<head><title><b>T</b></title><link rel=canonical href=/a></head><body>")
        #expect(r.breaker == nil)
    }

    @Test func headChecks() {
        func page(_ id: Int32, head: Int, body: Int, breaker: String? = nil) -> PageRecord {
            Self.page(id, "https://e.com/\(id)") {
                $0.headCount = head
                $0.bodyCount = body
                $0.headBreaker = breaker
                $0.headHiddenTags = breaker == nil ? [] : ["canonical"]
            }
        }
        let a = CrawlAnalyzer.analyze(Self.crawl([
            page(0, head: 1, body: 1), page(1, head: 1, body: 1, breaker: "<img>"),
            page(2, head: 1, body: 2), page(3, head: 2, body: 1), page(4, head: 0, body: 1), page(5, head: 1, body: 0),
        ]))
        #expect(Self.ids(a, .headInvalidElement) == [1])
        #expect(Self.ids(a, .headBodyMultiple) == [2, 3])
        #expect(Self.ids(a, .headBodyMissing) == [4, 5])
        #expect(IssueID.headInvalidElement.severity == .error && IssueID.headInvalidElement.group == .markup)
        let p = HTMLAnalyzer.parse("<html><head><title>T</title><img src=x><link rel=canonical href=/a></head><body></body></html>").info
        #expect(p.headBreaker == "<img>" && p.headMarkupSummary == "<head> обрывается на <img>, после него: canonical")
    }

    // MARK: № 113, п. 2.9

    @Test func imageAltKinds() {
        let long = String(repeating: "а", count: 101)
        let r = HTMLAnalyzer.parse("""
        <body><img src="a.png"><img src="b.png" alt=""><img src="c.png" alt="  ">
        <img src="d.png" alt="\(long)"><img data-src="e.png" alt="Нормально"></body>
        """)
        #expect(r.info.imagesCount == 5)
        #expect(r.info.imagesWithoutAlt == 1 && r.info.imagesWithoutAltSamples == ["a.png"])
        #expect(r.info.imagesEmptyAlt == 2 && r.info.imagesEmptyAltSamples == ["b.png", "c.png"])
        #expect(r.info.altLengths == [101, 9])
        #expect(r.info.longestAlts.first == ImageAltSample(src: "d.png", length: 101))
    }

    @Test func altChecksFollowThreshold() {
        let bad = Self.page(1, "https://e.com/img") {
            $0.imagesWithoutAlt = 1
            $0.imagesEmptyAlt = 1
            $0.altLengths = [101, 20]
        }
        let clean = Self.page(0, "https://e.com/") { $0.altLengths = [20] }
        var d = Self.crawl([clean, bad])
        var a = CrawlAnalyzer.analyze(d)
        #expect(Self.ids(a, .imagesWithoutAlt) == [1])
        #expect(Self.ids(a, .imagesEmptyAlt) == [1])
        #expect(Self.ids(a, .imagesLongAlt) == [1])
        #expect(IssueID.imagesWithoutAlt.severity == .warning)
        #expect(IssueID.imagesEmptyAlt.severity == .notice)
        d.config.thresholds.altMax = 120
        a = CrawlAnalyzer.analyze(d)
        #expect(Self.ids(a, .imagesLongAlt).isEmpty)
    }

    // MARK: № 106, п. 2.2

    @Test func h1AndH2Checks() {
        let long = String(repeating: "з", count: 71)
        let pages = [
            Self.page(0, "https://e.com/"),
            Self.page(1, "https://e.com/h1-long") { $0.headings[0].text = long },
            Self.page(2, "https://e.com/no-h2") { $0.headings = [Heading(level: 1, text: "Без H2")] },
            Self.page(3, "https://e.com/h2-long") { $0.headings[1].text = long },
            Self.page(4, "https://e.com/dup-a") { $0.headings[1].text = "Похожие товары" },
            Self.page(5, "https://e.com/dup-b") { $0.headings += [Heading(level: 2, text: "Другой")]; $0.headings[1].text = "похожие товары " },
        ]
        var d = Self.crawl(pages)
        var a = CrawlAnalyzer.analyze(d)
        #expect(Self.ids(a, .h1TooLong) == [1])
        #expect(Self.ids(a, .h2Missing) == [2])
        #expect(Self.ids(a, .h2TooLong) == [3])
        #expect(Self.ids(a, .h2Duplicate) == [4, 5])
        #expect(IssueID.h2Duplicate.needsFullCrawl)
        d.config.thresholds.h1Max = 80
        d.config.thresholds.h2Max = 80
        a = CrawlAnalyzer.analyze(d)
        #expect(Self.ids(a, .h1TooLong).isEmpty && Self.ids(a, .h2TooLong).isEmpty)
    }

    // MARK: № 102, п. 1.3

    @Test func linkGraphChecks() {
        let u = ["", "about", "nofollow-only", "noindex", "from-noindex", "dead-end", "mixed", "canonicalized"]
        let pages = u.enumerated().map { i, path in
            Self.page(Int32(i), "https://e.com/" + path) { info in
                if path == "noindex" { info.metaRobots = ["noindex, follow"] }
            }
        }
        func link(_ s: Int32, _ t: Int32, _ rel: RelFlags = [], kind: LinkKind = .anchor, external: Bool = false) -> LinkRecord {
            LinkRecord(source: s, target: t, anchor: "a", rel: rel, kind: kind, zone: .content, external: external)
        }
        let links = [
            link(0, 1), link(0, 2, .nofollow), link(0, 3, .nofollow), link(0, 5), link(0, 6, .nofollow),
            link(1, 0), link(1, 2, .nofollow), link(1, 6),
            link(2, 0),
            link(3, 0), link(3, 4),
            link(4, 0),
            // Тупик: ссылка на себя и внешняя ссылка не в счёт.
            link(5, 5), link(5, 99, external: true),
            link(6, 0),
            link(7, 1, kind: .canonical), link(7, 4),
        ]
        var d = Self.crawl(pages, links: links)
        var a = CrawlAnalyzer.analyze(d)
        #expect(a.metrics[7]?.indexability == .canonicalized)
        // 3 (noindex) тоже связана только через nofollow, но неиндексируемой странице вес не нужен.
        #expect(Self.ids(a, .nofollowInlinksOnly) == [2])
        // У 4 оба источника неиндексируемые: noindex и canonical на другой адрес.
        #expect(Self.ids(a, .nonIndexableInlinksOnly) == [4])
        #expect(Self.ids(a, .noInternalOutlinks) == [5])
        let graphChecks: Set<IssueID> = [.nofollowInlinksOnly, .nonIndexableInlinksOnly, .noInternalOutlinks]
        #expect(graphChecks.isDisjoint(with: a.metrics[1]?.issues ?? []))
        #expect(IssueID.nofollowInlinksOnly.severity == .warning && IssueID.nonIndexableInlinksOnly.severity == .warning)
        #expect(IssueID.noInternalOutlinks.severity == .notice)
        #expect(IssueID.nofollowInlinksOnly.needsFullCrawl && !IssueID.noInternalOutlinks.needsFullCrawl)

        // Список URL: входящие неполные, проверки по ним молчат; тупик виден по самой странице.
        d.config.mode = .list
        a = CrawlAnalyzer.analyze(d)
        #expect(Self.ids(a, .nofollowInlinksOnly).isEmpty && Self.ids(a, .nonIndexableInlinksOnly).isEmpty)
        #expect(Self.ids(a, .noInternalOutlinks) == [5])
    }

    // MARK: № 100, п. 1.1

    @Test func canonicalChecks() {
        let u = ["https://e.com/", "https://e.com/none", "https://e.com/same", "https://e.com/diff", "https://e.com/rel"]
        let pages = [
            Self.page(0, u[0]) { $0.canonicals = [u[0]] },
            Self.page(1, u[1]),
            Self.page(2, u[2]) { $0.canonicals = [u[2], "/same"] },
            Self.page(3, u[3]) { $0.canonicals = [u[3], u[0]] },
            Self.page(4, u[4]) { $0.canonicals = ["/rel"] },
        ]
        func canonical(_ s: Int32, _ t: Int32) -> LinkRecord {
            LinkRecord(source: s, target: t, anchor: "", rel: [], kind: .canonical, zone: .other, external: false)
        }
        // Так их записывает обходчик: после нормализации `/same` и полный адрес — один id.
        let links = [canonical(0, 0), canonical(2, 2), canonical(2, 2), canonical(3, 3), canonical(3, 0), canonical(4, 4)]
        let a = CrawlAnalyzer.analyze(Self.crawl(pages, links: links))
        #expect(Self.ids(a, .canonicalMissing) == [1])
        #expect(Self.ids(a, .canonicalMultipleSame) == [2])
        #expect(Self.ids(a, .canonicalMultipleDifferent) == [3])
        #expect(Self.ids(a, .canonicalRelative) == [2, 4])
        #expect(IssueID.canonicalMultipleDifferent.severity == .error)
        #expect(CrawlAnalyzer.isRelativeURL("//e.com/x") && !CrawlAnalyzer.isRelativeURL("HTTPS://e.com/") && !CrawlAnalyzer.isRelativeURL(" "))
    }

    // MARK: № 105, п. 2.1

    @Test func robotsRuleForBlockedPages() {
        let r = RobotsTxt(text: "User-agent: *\nDisallow: /admin/\nAllow: /admin/public/\n\nUser-agent: Yandex\nDisallow: /search\n")
        #expect(r.decisiveRule("/admin/x", token: "seopars")?.rule.line == "Disallow: /admin/")
        #expect(r.decisiveRule("/admin/public/x", token: "seopars")?.rule.line == "Allow: /admin/public/")
        #expect(r.decisiveRule("/other", token: "seopars") == nil)
        #expect(r.decisiveRule("/search", token: "yandexbot")?.agent == "yandex")

        let ok = Self.page(0, "https://e.com/")
        let blocked = PageRecord(id: 1, url: "https://e.com/admin/x", state: .blockedByRobots)
        let otherHost = PageRecord(id: 2, url: "https://shop.e.com/admin/x", state: .blockedByRobots)
        var d = Self.crawl([ok, blocked, otherHost])
        d.robotsText = r.raw
        let rows = Dictionary(uniqueKeysWithValues: PageRow.build(d, CrawlAnalyzer.analyze(d)).map { ($0.id, $0) })
        #expect(rows[1]?.robotsRule == "Disallow: /admin/ (User-agent: *)")
        #expect(rows[0]?.robotsRule == "")
        // robots.txt другого хоста в обходе не хранится — правило не угадываем.
        #expect(rows[2]?.robotsRule == "")
        d.config.userAgentPreset = .yandexbot
        let yandexBlocked = PageRecord(id: 3, url: "https://e.com/search", state: .blockedByRobots)
        #expect(d.robotsRule(for: yandexBlocked) == "Disallow: /search (User-agent: yandex)")
    }

    // MARK: № 115, п. 3.2

    @Test func zoneRulesBeatHeuristic() {
        // Шапка Elementor без семантических тегов: эвристика видит в классах «menu» и решает «меню».
        let html = """
        <body><div class="elementor-location-header"><div class="elementor-nav-menu"><a href="/catalog/">Каталог</a></div>
        <nav><a href="/sale/">Акции</a></nav></div>
        <div class="promo"><a href="/promo/">Промо</a></div>
        <div class="elementor-location-footer"><a href="/contacts/">Контакты</a></div></body>
        """
        func zones(_ rules: [ZoneRule]) -> [String: LinkZone] {
            Dictionary(uniqueKeysWithValues: HTMLAnalyzer.parse(html, zoneRules: rules).links.map { ($0.href, $0.zone) })
        }
        let plain = zones([])
        #expect(plain["/catalog/"] == .nav && plain["/sale/"] == .nav && plain["/promo/"] == .other)
        let ruled = zones([
            ZoneRule(zone: .header, selector: ".elementor-location-header"),
            ZoneRule(zone: .content, selector: "div.promo"),
            ZoneRule(zone: .aside, selector: "div::x"),
        ])
        // Правило сильнее и ближайшего семантического <nav>; ошибочный селектор пропущен.
        #expect(ruled["/catalog/"] == .header && ruled["/sale/"] == .header)
        #expect(ruled["/promo/"] == .content)
        #expect(ruled["/contacts/"] == .footer)
        #expect(HTMLAnalyzer.selectorError("div::x") != nil && HTMLAnalyzer.selectorError(".ok > a") == nil)
    }

    // MARK: № 101, п. 1.2

    @Test func hreflangCodes() {
        for ok in ["ru", "en-GB", "EN-gb", "zh-Hant", "zh-Hant-TW", "x-default", "X-Default"] {
            #expect(CrawlAnalyzer.isValidHreflang(ok), "\(ok)")
        }
        for bad in ["ru-RUS", "en-UK", "en_US", "english", "", "es-419", "en-EU", "en-GB-x", "zz"] {
            #expect(!CrawlAnalyzer.isValidHreflang(bad), "\(bad)")
        }
    }

    @Test func hreflangChecks() {
        let base = "https://e.com/hreflang/"
        let names = ["", "ru/", "en/", "no-return", "no-self-ru", "no-self-en", "no-xdefault", "broken", "missing-en", "bad-code"]
        // Аннотации страниц: (код, id цели).
        let sets: [Int32: [(String, Int32)]] = [
            1: [("ru", 1), ("en", 2), ("x-default", 1)],
            2: [("ru", 1), ("en", 2), ("x-default", 1)],
            3: [("ru", 3), ("en", 2), ("x-default", 3)],
            4: [("en", 5), ("x-default", 5)],
            5: [("ru", 4), ("en", 5), ("x-default", 5)],
            6: [("ru", 6)],
            7: [("ru", 7), ("en", 8), ("x-default", 7)],
            9: [("ru-RUS", 9), ("x-default", 9)],
        ]
        var pages: [PageRecord] = []
        var links: [LinkRecord] = []
        for (i, name) in names.enumerated() {
            let id = Int32(i)
            if name == "missing-en" {
                var p = PageRecord(id: id, url: base + name, state: .fetched)
                p.statusCode = 404
                pages.append(p)
                continue
            }
            let set = sets[id] ?? []
            pages.append(Self.page(id, base + name) { $0.hreflang = set.map { Hreflang(lang: $0.0, href: base + names[Int($0.1)]) } })
            links += set.map { LinkRecord(source: id, target: $0.1, anchor: $0.0, rel: [], kind: .hreflang, zone: .other, external: false) }
        }
        let a = CrawlAnalyzer.analyze(Self.crawl(pages, links: links))
        #expect(Self.ids(a, .hreflangNoReturn) == [3])
        #expect(Self.ids(a, .hreflangNoSelf) == [4])
        #expect(Self.ids(a, .hreflangNoXDefault) == [6])
        #expect(Self.ids(a, .hreflangTargetNon200) == [7])
        #expect(Self.ids(a, .hreflangInvalidCode) == [9])
        // hreflang — не ссылка для перелинковки.
        #expect(a.metrics[2]?.uniqueInlinks == 0)

        // Старый обход: аннотации есть, связей hreflang нет — проверки по целям не срабатывают.
        let old = CrawlAnalyzer.analyze(Self.crawl(pages))
        #expect(Self.ids(old, .hreflangNoSelf).isEmpty && Self.ids(old, .hreflangNoReturn).isEmpty)
        #expect(Self.ids(old, .hreflangNoXDefault) == [6] && Self.ids(old, .hreflangInvalidCode) == [9])
    }
}
