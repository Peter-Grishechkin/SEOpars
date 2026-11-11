import Foundation
import Testing
@testable import SEOparsCore

@Suite struct URLNormalizerTests {
    let n = URLNormalizer(ignoredParams: CrawlConfig().ignoredParams)

    @Test func cyrillicPathVariantsAreOneURL() {
        let raw = n.normalize("https://example.com/каталог/")
        let lowerHex = n.normalize("https://example.com/%d0%ba%d0%b0%d1%82%d0%b0%d0%bb%d0%be%d0%b3/")
        let upperHex = n.normalize("https://example.com/%D0%BA%D0%B0%D1%82%D0%B0%D0%BB%D0%BE%D0%B3/")
        #expect(raw != nil)
        #expect(raw == lowerHex)
        #expect(raw == upperHex)
    }

    @Test func cyrillicDomainToPunycode() {
        #expect(n.normalize("https://сайт.рф/путь/") == "https://xn--80aswg.xn--p1ai/%D0%BF%D1%83%D1%82%D1%8C/")
        #expect(n.normalize("https://САЙТ.РФ/") == "https://xn--80aswg.xn--p1ai/")
        #expect(URLNormalizer.display("https://xn--80aswg.xn--p1ai/%D0%BF%D1%83%D1%82%D1%8C/") == "https://сайт.рф/путь/")
    }

    @Test func schemeHostPortFragmentDots() {
        #expect(n.normalize("HTTP://Example.COM:80/A/../b/./c#top") == "http://example.com/b/c")
        #expect(n.normalize("https://example.com:443") == "https://example.com/")
        #expect(n.normalize("https://example.com:8443/x") == "https://example.com:8443/x")
    }

    @Test func trailingSlashAndCaseStayDifferent() {
        #expect(n.normalize("https://example.com/Page") != n.normalize("https://example.com/page"))
        #expect(n.normalize("https://example.com/page/") != n.normalize("https://example.com/page"))
    }

    @Test func ignoredParamsDropped() {
        #expect(n.normalize("https://example.com/p?utm_source=ya&utm_medium=cpc") == "https://example.com/p")
        #expect(n.normalize("https://example.com/p?id=5&yclid=123&gclid=x") == "https://example.com/p?id=5")
        #expect(n.normalize("https://example.com/p?") == "https://example.com/p")
    }

    @Test func cleanParamAppliesOnlyUnderPrefix() {
        let cp = URLNormalizer(cleanParams: [CleanParamRule(params: ["sort", "ref"], pathPrefix: "/catalog/")])
        #expect(cp.normalize("https://example.com/catalog/phones?sort=price&page=2") == "https://example.com/catalog/phones?page=2")
        #expect(cp.normalize("https://example.com/blog/?sort=price") == "https://example.com/blog/?sort=price")
        let global = URLNormalizer(cleanParams: [CleanParamRule(params: ["ref"], pathPrefix: "")])
        #expect(global.normalize("https://example.com/a?ref=1") == "https://example.com/a")
    }

    @Test func relativeLinks() throws {
        let base = try #require(URL(string: "https://example.com/blog/post/"))
        #expect(n.normalize("../other", base: base) == "https://example.com/blog/other")
        #expect(n.normalize("/контакты", base: base) == "https://example.com/%D0%BA%D0%BE%D0%BD%D1%82%D0%B0%D0%BA%D1%82%D1%8B")
        #expect(n.normalize("//cdn.example.com/x", base: base) == "https://cdn.example.com/x")
        #expect(n.normalize("?page=2", base: base) == "https://example.com/blog/post/?page=2")
        #expect(n.normalize("#comments", base: base) == nil)
        #expect(n.normalize("mailto:a@b.ru", base: base) == nil)
        #expect(n.normalize("tel:+7999", base: base) == nil)
        #expect(n.normalize("javascript:void(0)", base: base) == nil)
    }

    @Test func percentEncodingEdgeCases() {
        // %7E — незарезервированный «~», раскрывается.
        #expect(n.normalize("https://example.com/%7Euser") == "https://example.com/~user")
        #expect(n.normalize("https://example.com/a b") == "https://example.com/a%20b")
    }

    @Test func punycodeDecode() {
        #expect(Punycode.decode("80aswg") == "сайт")
        #expect(Punycode.decode("p1ai") == "рф")
        #expect(Punycode.decodeHost("www.xn--e1afmkfd.xn--p1ai") == "www.пример.рф")
    }
}

@Suite struct RobotsTxtTests {
    let text = """
    User-agent: *
    Disallow: /admin/
    Disallow: /*?sort=
    Allow: /admin/public/

    User-agent: Yandex
    Disallow: /search
    Crawl-delay: 2
    Clean-param: utm_source&ref /catalog/

    User-agent: YandexBot
    Disallow: /private$

    User-agent: Googlebot
    User-agent: Bingbot
    Disallow: /nogoogle
    Disallow:

    Sitemap: https://example.com/sitemap.xml
    """

    @Test func groupSelection() {
        let r = RobotsTxt(text: text)
        #expect(r.group(for: "seopars")?.agents == ["*"])
        #expect(r.group(for: "yandexbot")?.agents == ["yandexbot"])
        #expect(r.group(for: "googlebot")?.agents == ["googlebot"])
        #expect(r.sitemaps == ["https://example.com/sitemap.xml"])
        #expect(r.cleanParams == [CleanParamRule(params: ["utm_source", "ref"], pathPrefix: "/catalog/")])
    }

    @Test func longestMatchAndAllowTie() {
        let r = RobotsTxt(text: text)
        #expect(!r.isAllowed("/admin/users", token: "seopars"))
        #expect(r.isAllowed("/admin/public/page", token: "seopars"))
        #expect(!r.isAllowed("/catalog?sort=price", token: "seopars"))
        #expect(r.isAllowed("/catalog?page=2", token: "seopars"))
        let tie = RobotsTxt(text: "User-agent: *\nDisallow: /page\nAllow: /page\n")
        #expect(tie.isAllowed("/page", token: "seopars"))
    }

    @Test func dollarAnchor() {
        let r = RobotsTxt(text: text)
        #expect(!r.isAllowed("/private", token: "yandexbot"))
        #expect(r.isAllowed("/private/page", token: "yandexbot"))
        // YandexBot-группа точнее Yandex, поэтому /search для него разрешён.
        #expect(r.isAllowed("/search", token: "yandexbot"))
        #expect(!r.isAllowed("/nogoogle/x", token: "googlebot"))
    }

    @Test func crawlDelay() {
        let r = RobotsTxt(text: text)
        #expect(r.crawlDelay(token: "yandex") == 2)
        #expect(r.crawlDelay(token: "seopars") == nil)
    }

    @Test func cyrillicPattern() {
        let r = RobotsTxt(text: "User-agent: *\nDisallow: /корзина\n")
        let path = RobotsTxt.pathAndQuery(of: URLNormalizer().normalize("https://example.com/корзина/1")!)
        #expect(!r.isAllowed(path, token: "seopars"))
    }

    @Test func pathAndQuery() {
        #expect(RobotsTxt.pathAndQuery(of: "https://example.com/a?b=1") == "/a?b=1")
        #expect(RobotsTxt.pathAndQuery(of: "https://example.com") == "/")
    }
}

@Suite struct TextDecodingTests {
    let russian = "<html><head><title>Привет, мир</title></head></html>"

    @Test func headerCharsetWins() {
        let data = russian.data(using: .windowsCP1251)!
        let r = HTMLTextDecoder.decode(data, contentType: "text/html; charset=windows-1251")
        #expect(r.text.contains("Привет, мир"))
        #expect(r.charset == "windows-1251")
    }

    @Test func metaCharsetWithoutHeader() {
        let html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1251\"><title>Привет</title></head></html>"
        let r = HTMLTextDecoder.decode(html.data(using: .windowsCP1251)!, contentType: "text/html")
        #expect(r.text.contains("<title>Привет</title>"))
        #expect(r.charset == "windows-1251")
    }

    @Test func koi8() {
        let html = "<meta charset=\"koi8-r\"><title>Привет</title>"
        let r = HTMLTextDecoder.decode(html.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue))))!, contentType: nil)
        #expect(r.text.contains("Привет"))
    }

    @Test func undeclaredFallsBackTo1251() {
        let r = HTMLTextDecoder.decode(russian.data(using: .windowsCP1251)!, contentType: "text/html")
        #expect(r.text.contains("Привет, мир"))
        #expect(r.charset == "windows-1251")
    }

    @Test func utf8Default() {
        let r = HTMLTextDecoder.decode(russian.data(using: .utf8)!, contentType: nil)
        #expect(r.text.contains("Привет, мир"))
        #expect(r.charset == "utf-8")
    }
}
