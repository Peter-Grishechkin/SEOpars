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
