import Foundation
import SEOparsCore

// Обход без интерфейса: для проверки ядра и выгрузок.
//   seopars-cli crawl <url> [--max N] [--threads N] [--delay MS] [--ua seopars|googlebot|yandexbot]
//                     [--scope host|subdomains|subfolder] [--depth N] [--no-robots] [--no-sitemap]
//                     [--exclude REGEX]... [--list FILE] [--out FILE] [--csv DIR]
//   seopars-cli resume <file.seocrawl> [--csv DIR]
//   seopars-cli report <file.seocrawl> [--csv DIR]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("Использование: seopars-cli crawl <url> | resume <файл> | report <файл>  [--csv папка]")
}
args.removeFirst()

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func runCrawler(_ crawler: Crawler) async {
    let printer = Task {
        var last = Date.distantPast
        for await batch in crawler.events {
            for m in batch.messages { print("  · \(m)") }
            if Date().timeIntervalSince(last) > 1 || !batch.state.isActive {
                let s = batch.stats
                print("[\(batch.state.title)] обойдено \(s.crawled), в очереди \(s.queued), 2xx \(s.status2xx), 3xx \(s.status3xx), 4xx \(s.status4xx), 5xx \(s.status5xx), ошибок \(s.errors), robots \(s.blocked), \(String(format: "%.1f", s.urlsPerSecond)) URL/с")
                last = Date()
            }
            if !batch.state.isActive, batch.state != .idle { break }
        }
    }
    await crawler.start()
    await crawler.waitUntilIdle()
    await printer.value
}

func report(_ file: URL, csvDir: String?) throws {
    let stored = try CrawlStore.open(at: file, readOnly: true).load()
    let data = CrawlData(stored: stored)
    let a = CrawlAnalyzer.analyze(data)
    let indexable = a.metrics.values.filter { $0.indexability.isIndexable }.count
    print("\nФайл: \(file.path)")
    print("Страниц: \(data.pages.count), индексируются: \(indexable), ссылок: \(data.links.count), URL в sitemap: \(data.sitemapIds.count), в очереди: \(stored.queue.filter { data.pageIndex[$0.id] == nil }.count)")
    print("Проблемы:")
    let t = data.config.thresholds
    for id in IssueID.allCases {
        guard let pages = a.issues[id], !pages.isEmpty else { continue }
        print(String(format: "  %-14@ %4d  %@", id.severity.title as NSString, pages.count, id.title(t) as NSString))
    }
    guard let dir = csvDir else { return }
    let out = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let rows = PageRow.build(data, a)
    try CSVWriter.make(rows, columns: CSVColumns.pages).write(to: out.appendingPathComponent("pages.csv"))
    try CSVWriter.make(rows, columns: CSVColumns.meta).write(to: out.appendingPathComponent("meta.csv"))
    try CSVWriter.make(rows, columns: CSVColumns.headings).write(to: out.appendingPathComponent("headings.csv"))
    try CSVColumns.headingOutline(data).write(to: out.appendingPathComponent("headings-outline.csv"))
    let links = data.links.enumerated().map { LinkRow.make($0.offset, $0.element, data) }
    try CSVWriter.make(links, columns: CSVColumns.links).write(to: out.appendingPathComponent("links.csv"))
    try CSVWriter.make(RedirectRow.build(data, a), columns: CSVColumns.redirects).write(to: out.appendingPathComponent("redirects.csv"))
    struct IssueLine { var issue: String; var severity: String; var url: String; var fix: String }
    var lines: [IssueLine] = []
    for id in IssueID.allCases {
        let fix = id.howToFix(t)
        for pid in a.issues[id] ?? [] {
            lines.append(IssueLine(issue: id.title(t), severity: id.severity.title, url: URLNormalizer.display(data.url(pid)), fix: fix))
        }
    }
    try CSVWriter.make(lines, columns: [.init("Проблема") { $0.issue }, .init("Важность") { $0.severity }, .init("URL") { $0.url },
                                        .init("Как исправить") { $0.fix }])
        .write(to: out.appendingPathComponent("issues.csv"))
    print("CSV: \(out.path)")
}

switch command {
case "crawl":
    var cfg = CrawlConfig()
    if let v = option("--max").flatMap(Int.init) { cfg.maxPages = v }
    if let v = option("--threads").flatMap(Int.init) { cfg.concurrency = v }
    if let v = option("--delay").flatMap(Int.init) { cfg.delayMs = v }
    if let v = option("--depth").flatMap(Int.init) { cfg.maxDepth = v }
    if let v = option("--ua").flatMap(UserAgentPreset.init(rawValue:)) { cfg.userAgentPreset = v }
    if let v = option("--scope").flatMap(CrawlScopeKind.init(rawValue:)) { cfg.scope = v }
    if flag("--no-robots") { cfg.respectRobots = false }
    if flag("--no-sitemap") { cfg.useSitemap = false }
    while let ex = option("--exclude") { cfg.excludePatterns.append(ex) }
    if let listFile = option("--list") {
        cfg.mode = .list
        cfg.listURLs = (try? String(contentsOfFile: listFile, encoding: .utf8))?
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    }
    let outPath = option("--out")
    let csv = option("--csv")
    if cfg.mode == .spider {
        guard let url = args.first else { fail("Не указан адрес") }
        cfg.startURL = url
    }
    let file = outPath.map { URL(fileURLWithPath: $0) } ?? CrawlLibrary.newFileURL(for: cfg, in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    if FileManager.default.fileExists(atPath: file.path) { fail("Файл уже существует: \(file.path)") }
    let store = try CrawlStore.create(at: file, config: cfg)
    await runCrawler(Crawler(config: cfg, store: store))
    try report(file, csvDir: csv)

case "resume":
    guard let path = args.first else { fail("Не указан файл") }
    let csv = option("--csv")
    let file = URL(fileURLWithPath: path)
    let store = try CrawlStore.open(at: file)
    let stored = try store.load()
    print("Продолжаю: \(stored.pages.count) страниц уже обойдено, в очереди \(stored.queue.filter { !Set(stored.pages.map(\.id)).contains($0.id) }.count)")
    await runCrawler(Crawler(config: stored.config, store: store, restored: stored))
    try report(file, csvDir: csv)

case "report":
    guard let path = args.first else { fail("Не указан файл") }
    let csv = option("--csv")
    try report(URL(fileURLWithPath: path), csvDir: csv)

default:
    fail("Неизвестная команда: \(command)")
}
