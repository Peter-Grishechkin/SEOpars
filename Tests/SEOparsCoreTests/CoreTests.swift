import Foundation
import Testing
@testable import SEOparsCore

@Suite struct HTMLAnalyzerTests {
    @Test func extractsMetaHeadingsLinks() {
        let html = """
        <html lang="ru"><head>
        <title>Заголовок   страницы</title>
        <meta name="Description" content="Описание">
        <meta name="robots" content="noindex, nofollow">
        <meta name="yandex" content="noindex">
        <meta property="og:title" content="OG">
        <link rel="canonical" href="https://example.com/page/">
        <link rel="alternate" hreflang="en" href="https://example.com/en/">
        </head><body>
        <svg><title>иконка</title></svg>
        <header><a href="/">Логотип</a></header>
        <nav><a href="/catalog/">Каталог</a></nav>
        <div class="elementor-nav-menu"><a href="/menu-item">Пункт</a></div>
        <main><h1>Главный</h1><h2>Раздел</h2><h4>Пропуск</h4>
        <p>Раз два три</p>
        <a href="/x" rel="nofollow sponsored">X</a>
        <a href="/img"><img src="a.png" alt="Картинка"></a>
        <img src="b.png">
        </main>
        <footer><a href="/contacts">Контакты</a></footer>
        <script>var a = "не текст";</script>
        </body></html>
        """
        let r = HTMLAnalyzer.parse(html)
        #expect(r.info.titles == ["Заголовок страницы"])
        #expect(r.info.descriptions == ["Описание"])
        #expect(r.info.metaRobots == ["noindex, nofollow"])
        #expect(r.info.metaYandex == ["noindex"])
        #expect(r.info.canonicals == ["https://example.com/page/"])
        #expect(r.info.hreflang.first?.lang == "en")
        #expect(r.info.lang == "ru")
        #expect(r.info.headings.map(\.level) == [1, 2, 4])
        #expect(r.info.imagesCount == 2)
        #expect(r.info.imagesWithoutAlt == 1)
        #expect(!r.info.contentHash.isEmpty)
        let byHref = Dictionary(r.links.map { ($0.href, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byHref["/"]?.zone == .header)
        #expect(byHref["/catalog/"]?.zone == .nav)
        #expect(byHref["/menu-item"]?.zone == .nav)
        #expect(byHref["/contacts"]?.zone == .footer)
        #expect(byHref["/x"]?.zone == .content)
        #expect(byHref["/x"]?.rel == [.nofollow, .sponsored])
        #expect(byHref["/img"]?.kind == .image)
        #expect(byHref["/img"]?.anchor == "Картинка")
    }
}

@Suite struct AnalyzerTests {
    func page(_ id: Int32, _ url: String, status: Int = 200, title: String = "Нормальный заголовок страницы для теста",
              h: [Heading] = [Heading(level: 1, text: "H1")], hash: String? = nil) -> PageRecord {
        var p = PageRecord(id: id, url: url, state: .fetched)
        p.statusCode = status
        p.contentType = "text/html"
        if status == 200 {
            var info = HTMLInfo()
            info.titles = [title]
            info.descriptions = [String(repeating: "о", count: 100) + "\(id)"]
            info.headings = h
            info.wordCount = 200
            info.contentHash = hash ?? "hash\(id)"
            p.html = info
        }
        return p
    }

    @Test func linksDepthAndIssues() {
        var cfg = CrawlConfig()
        cfg.startURL = "https://e.com/"
        var d = CrawlData(config: cfg)
        d.urls = ["https://e.com/", "https://e.com/a", "https://e.com/b", "https://e.com/404", "https://e.com/r", "https://e.com/orphan", "https://e.com/A"]
        d.startId = 0
        let pages = [
            page(0, d.urls[0], title: "Главная страница сайта для теста ок"),
            page(1, d.urls[1], title: "Дубль заголовка страницы для теста ок"),
            page(2, d.urls[2], title: "Дубль заголовка страницы для теста ок", h: [Heading(level: 2, text: "до"), Heading(level: 1, text: "H1")]),
            page(3, d.urls[3], status: 404),
            { var p = page(4, d.urls[4], status: 301); p.redirectTo = 1; p.redirectURL = d.urls[1]; return p }(),
            page(5, d.urls[5], title: "Сирота: страница сайта для теста ок"),
        ]
        for p in pages { d.pageIndex[p.id] = d.pages.count; d.pages.append(p) }
        func link(_ s: Int32, _ t: Int32, _ kind: LinkKind = .anchor, rel: RelFlags = []) -> LinkRecord {
            LinkRecord(source: s, target: t, anchor: "a", rel: rel, kind: kind, zone: .content, external: false)
        }
        d.links = [link(0, 1), link(0, 3), link(0, 4), link(1, 2, rel: .nofollow), link(4, 1, .redirect)]
        d.sitemapIds = [5]

        let a = CrawlAnalyzer.analyze(d)
        #expect(a.metrics[0]?.depth == 0)
        #expect(a.metrics[1]?.depth == 1)
        #expect(a.metrics[2]?.depth == 2)
        #expect(a.metrics[5]?.depth == nil)
        #expect(a.metrics[1]?.uniqueInlinks == 1)
        #expect(a.issues[.brokenInternalLinks] == [0])
        #expect(a.issues[.linksToRedirects] == [0])
        #expect(a.issues[.internalNofollow] == [1])
        #expect(a.issues[.client4xx] == [3])
        #expect(Set(a.issues[.titleDuplicate] ?? []) == [1, 2], "\(a.issues[.titleDuplicate] ?? []) \(a.metrics[2]?.indexability as Any)")
        #expect(a.issues[.headingBeforeH1] == [2])
        #expect(a.issues[.orphanPages] == [5])
        #expect(a.metrics[4]?.indexability == .redirect(301))
        #expect(a.redirects[4]?.finalId == 1)
    }

    @Test func skippedLevel() {
        #expect(CrawlAnalyzer.hasSkippedLevel([Heading(level: 1, text: ""), Heading(level: 3, text: "")]))
        #expect(!CrawlAnalyzer.hasSkippedLevel([Heading(level: 1, text: ""), Heading(level: 2, text: ""), Heading(level: 2, text: ""), Heading(level: 1, text: "")]))
        // Начало с H2 — это не «пропуск», а «H2 до H1» / «нет H1».
        #expect(!CrawlAnalyzer.hasSkippedLevel([Heading(level: 2, text: ""), Heading(level: 3, text: "")]))
    }

    @Test func xRobots() {
        #expect(CrawlAnalyzer.xRobotsNoindex("noindex", bot: "yandex"))
        #expect(CrawlAnalyzer.xRobotsNoindex("googlebot: noindex", bot: "googlebot"))
        #expect(!CrawlAnalyzer.xRobotsNoindex("googlebot: noindex", bot: "yandex"))
        #expect(!CrawlAnalyzer.xRobotsNoindex("unavailable_after: 25 Jun 2030", bot: ""))
    }

    @Test func variantKey() {
        #expect(CrawlAnalyzer.variantKey("https://e.com/Page/") == CrawlAnalyzer.variantKey("https://e.com/page"))
        #expect(CrawlAnalyzer.variantKey("https://e.com/") == "https://e.com/")
    }

    @Test func lengthVerdictMatchesThresholds() {
        let t = Thresholds()  // title 30–65
        func v(_ n: Int, present: Bool = true, content: Bool = true) -> LengthVerdict {
            .of(length: n, present: present, min: t.titleMin, max: t.titleMax, isContent: content)
        }
        #expect(v(29) == .tooShort && v(29).cellText(29) == "29 ↓")
        #expect(v(30) == .normal && v(65) == .normal && v(65).cellText(65) == "65")
        #expect(v(66) == .tooLong && v(66).cellText(66) == "66 ↑")
        #expect(v(66).spokenText(66) == "66, длиннее порога")
        #expect(v(0, present: false) == .missing && v(0, present: false).cellText(0) == "нет")
        #expect(v(0, present: false, content: false) == .notApplicable)
        #expect(v(80, content: false).cellText(80) == "—")
    }
}

/// Старые обходы и черновик настроек записаны без новых полей — они должны читаться.
@Suite struct CompatibilityTests {
    /// JSON значения без перечисленных ключей (по пути «ключ.ключ»).
    func json<T: Encodable>(_ value: T, removing paths: [String]) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        for path in paths {
            let parts = path.split(separator: ".").map(String.init)
            if parts.count == 1 { obj.removeValue(forKey: parts[0]) }
            else if var inner = obj[parts[0]] as? [String: Any] {
                inner.removeValue(forKey: parts[1])
                obj[parts[0]] = inner
            }
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test func configWithoutNewThresholds() throws {
        var cfg = CrawlConfig()
        cfg.thresholds.minWords = 150
        let data = try json(cfg, removing: ["thresholds.h1Max", "thresholds.h2Max", "thresholds.altMax"])
        let back = try JSONDecoder().decode(CrawlConfig.self, from: data)
        #expect(back.thresholds.minWords == 150)
        #expect(back.thresholds.h1Max == 70 && back.thresholds.h2Max == 70 && back.thresholds.altMax == 100)
    }

    @Test func pageWithoutNewHTMLFields() throws {
        var p = PageRecord(id: 7, url: "https://e.com/", state: .fetched)
        var info = HTMLInfo()
        info.titles = ["Старый обход"]
        info.imagesWithoutAlt = 2
        p.html = info
        let data = try json(p, removing: ["html.imagesEmptyAlt", "html.imagesEmptyAltSamples", "html.altLengths", "html.longestAlts"])
        let back = try JSONDecoder().decode(PageRecord.self, from: data)
        #expect(back.html?.titles == ["Старый обход"])
        #expect(back.html?.imagesWithoutAlt == 2)
        #expect(back.html?.imagesEmptyAlt == 0 && back.html?.altLengths == [])
    }
}

@Suite struct CSVTests {
    @Test func bomQuotingAndFormulas() {
        struct R { var a: String }
        let data = CSVWriter.make([R(a: "один;два"), R(a: "ка\"вычки"), R(a: "=СУММ(1)")], columns: [.init("Поле") { $0.a }])
        let s = String(decoding: data, as: UTF8.self)
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(s.contains("\"один;два\""))
        #expect(s.contains("\"ка\"\"вычки\""))
        #expect(s.contains("'=СУММ(1)"))
        #expect(s.contains("\r\n"))
    }
}

// MARK: - Обходчик на заглушке сети

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, [String: String], String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path(percentEncoded: false) ?? "/"
        let (code, headers, body) = Self.routes[path] ?? (404, ["Content-Type": "text/html"], "<h1>404</h1>")
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct CrawlSessionTests {
    static func site() {
        let html = ["Content-Type": "text/html; charset=utf-8"]
        func page(_ title: String, _ links: [String]) -> String {
            "<html><head><title>\(title)</title></head><body><h1>\(title)</h1>" + links.map { "<a href=\"\($0)\">\($0)</a>" }.joined() + "</body></html>"
        }
        var routes: [String: (Int, [String: String], String)] = [
            "/robots.txt": (200, ["Content-Type": "text/plain"], "User-agent: *\nDisallow: /private\n"),
            "/sitemap.xml": (404, [:], ""),
            "/": (200, html, page("Главная", (1...30).map { "/p\($0)" } + ["/private", "/moved"])),
            "/moved": (301, ["Location": "/p1"], ""),
        ]
        for i in 1...30 { routes["/p\(i)"] = (200, html, page("Страница \(i)", ["/", "/p\(i % 30 + 1)"])) }
        StubProtocol.routes = routes
    }

    @Test @MainActor func liveUpdatesAndFinalAnalysis() async throws {
        Self.site()
        var cfg = CrawlConfig()
        cfg.startURL = "http://stub.test/"
        cfg.delayMs = 0
        cfg.concurrency = 4
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seopars-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = CrawlSession(config: cfg, protocolClasses: [StubProtocol.self])
        session.analysisInterval = .milliseconds(50)
        try session.start(in: dir)
        await session.waitUntilIdle()

        #expect(session.state == .finished)
        // Главная + 30 страниц + редирект + запрет robots.
        #expect(session.data.pages.count == 33)
        #expect(session.rows.count == 33)
        #expect(session.analysisIsFinal)
        #expect(session.revision >= 1)
        let blocked = session.data.pages.first { $0.url == "http://stub.test/private" }
        #expect(blocked?.state == .blockedByRobots)
        let moved = session.data.pages.first { $0.url == "http://stub.test/moved" }
        #expect(moved?.statusCode == 301)
        #expect(moved?.redirectURL == "http://stub.test/p1")

        // Файл открывается заново с теми же данными.
        let file = try #require(session.fileURL)
        let reopened = try CrawlSession.open(file, protocolClasses: [StubProtocol.self])
        await reopened.waitUntilIdle()
        #expect(reopened.data.pages.count == 33)
        #expect(reopened.data.links.count == session.data.links.count)
        #expect(reopened.rows.count == 33)
        #expect(reopened.html(for: session.data.startId ?? 0)?.contains("Главная") == true)
    }

    @Test @MainActor func pauseAndResume() async throws {
        Self.site()
        var cfg = CrawlConfig()
        cfg.startURL = "http://stub.test/"
        cfg.delayMs = 40
        cfg.concurrency = 1
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seopars-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = CrawlSession(config: cfg, protocolClasses: [StubProtocol.self])
        try session.start(in: dir)
        try await Task.sleep(for: .milliseconds(400))
        session.pause()
        await session.waitUntilIdle()
        #expect(session.state == .paused)
        let partial = session.data.pages.count
        #expect(partial > 0 && partial < 33)
        #expect(session.canResume)
        session.resume()
        try await Task.sleep(for: .milliseconds(100))
        await session.waitUntilIdle()
        #expect(session.state == .finished)
        #expect(session.data.pages.count == 33)
        #expect(Set(session.data.pages.map(\.id)).count == 33)
    }
}
