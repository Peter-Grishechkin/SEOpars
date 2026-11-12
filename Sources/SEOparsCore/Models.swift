import Foundation

// MARK: - Настройки обхода

public struct Thresholds: Codable, Sendable, Equatable {
    /// Пороги длины — рабочие ориентиры, а не нормы поисковиков (см. SPEC, п. 1.5).
    public var titleMin = 30
    public var titleMax = 65
    public var descriptionMin = 70
    public var descriptionMax = 160
    /// Страницы глубже этого числа кликов от главной попадают в проблему «глубокие страницы».
    public var maxClickDepth = 3
    /// Меньше слов — проблема «мало текста».
    public var minWords = 200
    /// Медленный ответ, мс.
    public var slowResponseMs = 1500
    /// Страница с числом уникальных входящих от 1 до этого значения — «мало входящих ссылок».
    public var fewInlinksMax = 2
    /// H1 и первый H2 длиннее — замечание (порог Screaming Frog 18.4, SPEC п. 1.8).
    public var h1Max = 70
    public var h2Max = 70
    /// Alt картинки длиннее — замечание (порог Screaming Frog 18.4).
    public var altMax = 100

    public init() {}

    // Порогов становится больше: ключа нет в старом обходе или черновике — берём значение по умолчанию.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Thresholds()
        titleMin = try c.decodeIfPresent(Int.self, forKey: .titleMin) ?? d.titleMin
        titleMax = try c.decodeIfPresent(Int.self, forKey: .titleMax) ?? d.titleMax
        descriptionMin = try c.decodeIfPresent(Int.self, forKey: .descriptionMin) ?? d.descriptionMin
        descriptionMax = try c.decodeIfPresent(Int.self, forKey: .descriptionMax) ?? d.descriptionMax
        maxClickDepth = try c.decodeIfPresent(Int.self, forKey: .maxClickDepth) ?? d.maxClickDepth
        minWords = try c.decodeIfPresent(Int.self, forKey: .minWords) ?? d.minWords
        slowResponseMs = try c.decodeIfPresent(Int.self, forKey: .slowResponseMs) ?? d.slowResponseMs
        fewInlinksMax = try c.decodeIfPresent(Int.self, forKey: .fewInlinksMax) ?? d.fewInlinksMax
        h1Max = try c.decodeIfPresent(Int.self, forKey: .h1Max) ?? d.h1Max
        h2Max = try c.decodeIfPresent(Int.self, forKey: .h2Max) ?? d.h2Max
        altMax = try c.decodeIfPresent(Int.self, forKey: .altMax) ?? d.altMax
    }
}

/// Длина title или description относительно порогов — для ячеек таблиц, чтобы отклонение
/// было видно не только цветом (HANDOFF §10, вопрос 2). Сравнение то же, что в `CrawlAnalyzer`.
public enum LengthVerdict: Sendable, Equatable {
    /// Не HTML-страница с кодом 200: title и description не проверяются.
    case notApplicable
    case missing
    case tooShort
    case normal
    case tooLong

    public static func of(length: Int, present: Bool, min: Int, max: Int, isContent: Bool = true) -> LengthVerdict {
        guard isContent else { return .notApplicable }
        guard present else { return .missing }
        if length < min { return .tooShort }
        if length > max { return .tooLong }
        return .normal
    }

    /// Текст ячейки: «72 ↑» — длиннее порога, «24 ↓» — короче, «нет» — пусто, «—» — не проверяется.
    public func cellText(_ length: Int) -> String {
        switch self {
        case .notApplicable: "—"
        case .missing: "нет"
        case .tooShort: "\(length) ↓"
        case .normal: "\(length)"
        case .tooLong: "\(length) ↑"
        }
    }

    /// Подпись для VoiceOver: стрелки он читает как символы.
    public func spokenText(_ length: Int) -> String {
        switch self {
        case .notApplicable: "не проверяется"
        case .missing: "нет"
        case .tooShort: "\(length), короче порога"
        case .normal: "\(length)"
        case .tooLong: "\(length), длиннее порога"
        }
    }
}

public enum CrawlMode: String, Codable, Sendable, CaseIterable {
    case spider, list
    public var title: String { self == .spider ? "Паук" : "Список URL" }
}

public enum CrawlScopeKind: String, Codable, Sendable, CaseIterable {
    case host, subdomains, subfolder
    public var title: String {
        switch self {
        case .host: "Только этот хост"
        case .subdomains: "С поддоменами"
        case .subfolder: "Только подпапка"
        }
    }
}

public enum UserAgentPreset: String, Codable, Sendable, CaseIterable {
    case seopars, googlebot, yandexbot, custom

    public var title: String {
        switch self {
        case .seopars: "SEOpars (браузер)"
        case .googlebot: "Googlebot"
        case .yandexbot: "YandexBot"
        case .custom: "Свой"
        }
    }

    public var userAgent: String {
        switch self {
        case .seopars, .custom:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) SEOpars/0.2"
        case .googlebot:
            "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        case .yandexbot:
            "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)"
        }
    }

    /// Токен для выбора группы в robots.txt.
    public var robotsToken: String {
        switch self {
        case .seopars, .custom: "seopars"
        case .googlebot: "googlebot"
        case .yandexbot: "yandexbot"
        }
    }
}

public struct CrawlConfig: Codable, Sendable, Equatable {
    public var startURL: String = ""
    public var mode: CrawlMode = .spider
    public var listURLs: [String] = []
    public var scope: CrawlScopeKind = .host
    /// 0 — без ограничения.
    public var maxDepth = 0
    public var maxPages = 5000
    public var concurrency = 3
    public var delayMs = 200
    public var timeoutSeconds = 20
    public var userAgentPreset: UserAgentPreset = .seopars
    public var customUserAgent = ""
    public var respectRobots = true
    public var useSitemap = true
    /// Пусто — sitemap из robots.txt или /sitemap.xml.
    public var sitemapURL = ""
    public var crawlSitemapURLs = true
    public var includePatterns: [String] = []
    public var excludePatterns: [String] = []
    public var ignoredParams: [String] = ["utm_*", "yclid", "gclid", "fbclid", "_openstat", "ysclid"]
    /// Ссылки на такие файлы записываются, но не загружаются.
    public var skipExtensions: [String] = [
        "jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "ico", "bmp", "tif", "tiff",
        "mp4", "webm", "mov", "avi", "mp3", "wav", "ogg",
        "zip", "rar", "7z", "gz", "tar", "dmg", "exe",
        "css", "js", "woff", "woff2", "ttf", "otf", "eot",
    ]
    public var maxBodyBytes = 10 * 1024 * 1024
    public var thresholds = Thresholds()
    /// Свои правила зон ссылок: срабатывают раньше эвристики (№ 115). Применяются во время обхода.
    public var zoneRules: [ZoneRule] = []

    public init() {}

    public var userAgent: String {
        if userAgentPreset == .custom, !customUserAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            return customUserAgent
        }
        return userAgentPreset.userAgent
    }

    // Новые поля добавляются с значениями по умолчанию, чтобы старые файлы обходов открывались.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CrawlConfig.defaults
        startURL = try c.decodeIfPresent(String.self, forKey: .startURL) ?? d.startURL
        mode = try c.decodeIfPresent(CrawlMode.self, forKey: .mode) ?? d.mode
        listURLs = try c.decodeIfPresent([String].self, forKey: .listURLs) ?? d.listURLs
        scope = try c.decodeIfPresent(CrawlScopeKind.self, forKey: .scope) ?? d.scope
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth) ?? d.maxDepth
        maxPages = try c.decodeIfPresent(Int.self, forKey: .maxPages) ?? d.maxPages
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? d.concurrency
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? d.delayMs
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        userAgentPreset = try c.decodeIfPresent(UserAgentPreset.self, forKey: .userAgentPreset) ?? d.userAgentPreset
        customUserAgent = try c.decodeIfPresent(String.self, forKey: .customUserAgent) ?? d.customUserAgent
        respectRobots = try c.decodeIfPresent(Bool.self, forKey: .respectRobots) ?? d.respectRobots
        useSitemap = try c.decodeIfPresent(Bool.self, forKey: .useSitemap) ?? d.useSitemap
        sitemapURL = try c.decodeIfPresent(String.self, forKey: .sitemapURL) ?? d.sitemapURL
        crawlSitemapURLs = try c.decodeIfPresent(Bool.self, forKey: .crawlSitemapURLs) ?? d.crawlSitemapURLs
        includePatterns = try c.decodeIfPresent([String].self, forKey: .includePatterns) ?? d.includePatterns
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? d.excludePatterns
        ignoredParams = try c.decodeIfPresent([String].self, forKey: .ignoredParams) ?? d.ignoredParams
        skipExtensions = try c.decodeIfPresent([String].self, forKey: .skipExtensions) ?? d.skipExtensions
        maxBodyBytes = try c.decodeIfPresent(Int.self, forKey: .maxBodyBytes) ?? d.maxBodyBytes
        thresholds = try c.decodeIfPresent(Thresholds.self, forKey: .thresholds) ?? d.thresholds
        zoneRules = try c.decodeIfPresent([ZoneRule].self, forKey: .zoneRules) ?? d.zoneRules
    }

    static let defaults = CrawlConfig()
}

// MARK: - Данные страницы

public struct Heading: Codable, Sendable, Hashable {
    public var level: Int
    public var text: String
    public init(level: Int, text: String) { self.level = level; self.text = text }
}

public struct Hreflang: Codable, Sendable, Hashable {
    public var lang: String
    public var href: String
}

public struct ImageAltSample: Codable, Sendable, Hashable {
    public var src: String
    public var length: Int
}

public enum LinkKind: UInt8, Codable, Sendable, CaseIterable {
    /// `hreflang` — `<link rel="alternate" hreflang>`, в анкоре код языка (№ 101).
    case anchor = 0, image = 1, canonical = 2, redirect = 3, hreflang = 4
    public var title: String {
        switch self {
        case .anchor: "ссылка"
        case .image: "картинка-ссылка"
        case .canonical: "canonical"
        case .redirect: "редирект"
        case .hreflang: "hreflang"
        }
    }
}

/// Правило «зона ← CSS-селектор предка»: ссылка внутри элемента, подходящего под селектор, получает эту зону.
public struct ZoneRule: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var zone: LinkZone
    public var selector: String

    public init(zone: LinkZone, selector: String) {
        self.zone = zone
        self.selector = selector
    }

    /// Зоны, которые можно назначить правилом.
    public static let assignableZones: [LinkZone] = [.header, .nav, .content, .aside, .footer]
}

/// Зона на странице. Определяется своими правилами, затем эвристикой по разметке.
public enum LinkZone: UInt8, Codable, Sendable, CaseIterable {
    case other = 0, content = 1, nav = 2, header = 3, footer = 4, aside = 5
    public var title: String {
        switch self {
        case .other: "не определено"
        case .content: "контент"
        case .nav: "меню"
        case .header: "шапка"
        case .footer: "подвал"
        case .aside: "боковая колонка"
        }
    }
}

public struct RelFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let nofollow = RelFlags(rawValue: 1)
    public static let sponsored = RelFlags(rawValue: 2)
    public static let ugc = RelFlags(rawValue: 4)

    public init(relAttribute: String) {
        var f: RelFlags = []
        for token in relAttribute.lowercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            switch token {
            case "nofollow": f.insert(.nofollow)
            case "sponsored": f.insert(.sponsored)
            case "ugc": f.insert(.ugc)
            default: break
            }
        }
        self = f
    }

    public var title: String {
        var parts: [String] = []
        if contains(.nofollow) { parts.append("nofollow") }
        if contains(.sponsored) { parts.append("sponsored") }
        if contains(.ugc) { parts.append("ugc") }
        return parts.joined(separator: " ")
    }
}

/// Ссылка в разметке до нормализации.
public struct RawLink: Sendable, Hashable {
    public var href: String
    public var anchor: String
    public var rel: RelFlags
    public var kind: LinkKind
    public var zone: LinkZone
}

/// Результат разбора HTML.
public struct HTMLInfo: Codable, Sendable, Equatable {
    public var titles: [String] = []
    public var descriptions: [String] = []
    public var keywords: String?
    public var metaRobots: [String] = []
    public var metaGooglebot: [String] = []
    public var metaYandex: [String] = []
    public var canonicals: [String] = []
    public var hreflang: [Hreflang] = []
    public var lang: String?
    public var viewport: String?
    public var ogTitle: String?
    public var ogDescription: String?
    public var ogImage: String?
    public var twitterCard: String?
    public var metaRefresh: String?
    public var headings: [Heading] = []
    public var wordCount = 0
    public var contentHash = ""
    public var imagesCount = 0
    /// Картинки без атрибута alt.
    public var imagesWithoutAlt = 0
    public var imagesWithoutAltSamples: [String] = []
    /// Картинки с пустым `alt=""` (или из одних пробелов): допустимо для декора.
    public var imagesEmptyAlt = 0
    public var imagesEmptyAltSamples: [String] = []
    /// Длины непустых alt: порог «alt длиннее N» меняется без повторного обхода.
    public var altLengths: [Int] = []
    /// Картинки с самыми длинными alt (до 5), по убыванию длины.
    public var longestAlts: [ImageAltSample] = []

    public init() {}

    // Полей становится больше, а записи страниц в старых обходах без них: ключа нет — значение по умолчанию.
    // Без этого `CrawlStore.load()` молча пропустил бы такие страницы.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titles = try c.decodeIfPresent([String].self, forKey: .titles) ?? []
        descriptions = try c.decodeIfPresent([String].self, forKey: .descriptions) ?? []
        keywords = try c.decodeIfPresent(String.self, forKey: .keywords)
        metaRobots = try c.decodeIfPresent([String].self, forKey: .metaRobots) ?? []
        metaGooglebot = try c.decodeIfPresent([String].self, forKey: .metaGooglebot) ?? []
        metaYandex = try c.decodeIfPresent([String].self, forKey: .metaYandex) ?? []
        canonicals = try c.decodeIfPresent([String].self, forKey: .canonicals) ?? []
        hreflang = try c.decodeIfPresent([Hreflang].self, forKey: .hreflang) ?? []
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
        viewport = try c.decodeIfPresent(String.self, forKey: .viewport)
        ogTitle = try c.decodeIfPresent(String.self, forKey: .ogTitle)
        ogDescription = try c.decodeIfPresent(String.self, forKey: .ogDescription)
        ogImage = try c.decodeIfPresent(String.self, forKey: .ogImage)
        twitterCard = try c.decodeIfPresent(String.self, forKey: .twitterCard)
        metaRefresh = try c.decodeIfPresent(String.self, forKey: .metaRefresh)
        headings = try c.decodeIfPresent([Heading].self, forKey: .headings) ?? []
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        imagesCount = try c.decodeIfPresent(Int.self, forKey: .imagesCount) ?? 0
        imagesWithoutAlt = try c.decodeIfPresent(Int.self, forKey: .imagesWithoutAlt) ?? 0
        imagesWithoutAltSamples = try c.decodeIfPresent([String].self, forKey: .imagesWithoutAltSamples) ?? []
        imagesEmptyAlt = try c.decodeIfPresent(Int.self, forKey: .imagesEmptyAlt) ?? 0
        imagesEmptyAltSamples = try c.decodeIfPresent([String].self, forKey: .imagesEmptyAltSamples) ?? []
        altLengths = try c.decodeIfPresent([Int].self, forKey: .altLengths) ?? []
        longestAlts = try c.decodeIfPresent([ImageAltSample].self, forKey: .longestAlts) ?? []
    }

    /// Сколько картинок с alt длиннее порога.
    public func longAltCount(max: Int) -> Int { altLengths.filter { $0 > max }.count }

    public var title: String? { titles.first }
    public var description: String? { descriptions.first }
    public var h1s: [String] { headings.filter { $0.level == 1 }.map(\.text) }
    public var firstH2: String? { headings.first { $0.level == 2 }?.text }
}

public enum PageState: String, Codable, Sendable {
    /// Загружена (код ответа есть).
    case fetched
    /// Запрещена в robots.txt, не загружалась.
    case blockedByRobots
    /// Ошибка соединения: нет кода ответа.
    case failed
}

public struct PageRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: Int32
    public var url: String
    public var state: PageState
    public var statusCode: Int = 0
    public var error: String?
    public var redirectURL: String?
    public var redirectTo: Int32?
    public var contentType: String = ""
    public var charset: String = ""
    public var responseTimeMs: Int = 0
    public var sizeBytes: Int = 0
    public var truncated = false
    public var headers: [String: String] = [:]
    public var html: HTMLInfo?
    /// Глубина обнаружения при обходе (-1 — пришла из sitemap или списка).
    public var discoveryDepth: Int = 0
    public var crawledAt: Date = Date()

    public init(id: Int32, url: String, state: PageState) {
        self.id = id; self.url = url; self.state = state
    }

    public var isHTML: Bool { contentType.lowercased().contains("html") }
    public var isRedirect: Bool { (300..<400).contains(statusCode) }
    /// Страница с контентом: HTML и код 200.
    public var isContentPage: Bool { statusCode == 200 && html != nil }
    public var xRobotsTag: String { headers["x-robots-tag"] ?? "" }
}

/// Ссылка между URL. URL хранятся числовыми id (см. CrawlData.urls).
public struct LinkRecord: Codable, Sendable, Equatable {
    public var source: Int32
    public var target: Int32
    public var anchor: String
    public var rel: RelFlags
    public var kind: LinkKind
    public var zone: LinkZone
    public var external: Bool

    public init(source: Int32, target: Int32, anchor: String, rel: RelFlags, kind: LinkKind, zone: LinkZone, external: Bool) {
        self.source = source; self.target = target; self.anchor = anchor
        self.rel = rel; self.kind = kind; self.zone = zone; self.external = external
    }
}

// MARK: - Состояние обхода

public enum CrawlState: String, Codable, Sendable {
    case idle, preparing, running, pausing, paused, finished, interrupted

    public var title: String {
        switch self {
        case .idle: "Не запущен"
        case .preparing: "Загружаю robots.txt и sitemap"
        case .running: "Идёт обход"
        case .pausing: "Останавливаю"
        case .paused: "Пауза"
        case .finished: "Завершён"
        case .interrupted: "Прерван"
        }
    }

    public var isActive: Bool { self == .preparing || self == .running || self == .pausing }
}

public struct CrawlStats: Sendable, Equatable {
    public var crawled = 0
    public var queued = 0
    public var inFlight = 0
    public var errors = 0
    public var blocked = 0
    public var status2xx = 0
    public var status3xx = 0
    public var status4xx = 0
    public var status5xx = 0
    public var urlsPerSecond: Double = 0
    public init() {}
}

public struct URLEntry: Sendable, Equatable {
    public var id: Int32
    public var url: String
}

/// Пачка изменений от обходчика к интерфейсу.
public struct CrawlBatch: Sendable {
    public var newURLs: [URLEntry] = []
    public var pages: [PageRecord] = []
    public var links: [LinkRecord] = []
    public var sitemapIds: [Int32] = []
    public var stats = CrawlStats()
    public var state: CrawlState = .idle
    public var messages: [String] = []
    public var robotsText: String?
    public var startId: Int32?
    public init() {}

    public var isEmpty: Bool {
        newURLs.isEmpty && pages.isEmpty && links.isEmpty && sitemapIds.isEmpty && messages.isEmpty && robotsText == nil
    }
}
