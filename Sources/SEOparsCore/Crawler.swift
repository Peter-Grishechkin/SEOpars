import Foundation

/// Простая очередь FIFO.
struct FIFO<T> {
    private var items: [T] = []
    private var head = 0
    var count: Int { items.count - head }
    var isEmpty: Bool { count == 0 }
    mutating func append(_ x: T) { items.append(x) }
    mutating func popFirst() -> T? {
        guard head < items.count else { return nil }
        let x = items[head]
        head += 1
        if head > 4096, head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return x
    }
}

/// Границы обхода.
public struct CrawlScope: Sendable {
    public var kind: CrawlScopeKind
    /// Хосты без `www.`.
    public var hosts: Set<String>
    public var pathPrefix: String

    public init(kind: CrawlScopeKind, startURLs: [String]) {
        self.kind = kind
        hosts = Set(startURLs.compactMap { Self.host(of: $0) }.map(Self.baseHost))
        if kind == .subfolder, let first = startURLs.first {
            let path = Self.path(of: first)
            if path.hasSuffix("/") {
                pathPrefix = path
            } else if let last = path.split(separator: "/").last, last.contains(".") {
                pathPrefix = String(path[...(path.lastIndex(of: "/") ?? path.startIndex)])
            } else {
                pathPrefix = path + "/"
            }
        } else {
            pathPrefix = "/"
        }
    }

    public static func host(of url: String) -> String? {
        guard let r = url.range(of: "://") else { return nil }
        let rest = url[r.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == ":" || $0 == "#" }) ?? rest.endIndex
        let h = rest[..<end]
        return h.isEmpty ? nil : String(h)
    }

    public static func origin(of url: String) -> String? {
        guard let r = url.range(of: "://") else { return nil }
        let rest = url[r.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        return String(url[..<end])
    }

    static func path(of url: String) -> String {
        let pq = RobotsTxt.pathAndQuery(of: url)
        return String(pq.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
    }

    static func baseHost(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }

    /// Внутренний ли адрес (тот же сайт). `www.` и без него — один сайт.
    public func isInternal(_ url: String) -> Bool {
        guard let h = Self.host(of: url) else { return false }
        let b = Self.baseHost(h)
        if kind == .subdomains {
            return hosts.contains { b == $0 || b.hasSuffix("." + $0) }
        }
        return hosts.contains(b)
    }

    /// Попадает ли адрес в границы обхода (с учётом подпапки).
    public func inCrawlScope(_ url: String) -> Bool {
        guard isInternal(url) else { return false }
        if kind == .subfolder { return Self.path(of: url).hasPrefix(pathPrefix) }
        return true
    }
}

/// Обходчик сайта. Владеет очередью и пишет в файл обхода; интерфейсу отдаёт пачки через `events`.
public actor Crawler {
    public nonisolated let config: CrawlConfig
    public nonisolated let events: AsyncStream<CrawlBatch>
    nonisolated let fetcher: Fetcher
    nonisolated let token: String
    let store: CrawlStore?
    private let continuation: AsyncStream<CrawlBatch>.Continuation

    private var scope: CrawlScope
    private var normalizer: URLNormalizer
    private let includeRes: [NSRegularExpression]
    private let excludeRes: [NSRegularExpression]
    private let skipExtensions: Set<String>

    private var urlIds: [String: Int32] = [:]
    private var urlList: [String] = []
    private var queueMain = FIFO<QueueItem>()
    private var queueSecondary = FIFO<QueueItem>()
    private var seen = Set<Int32>()
    private var done = Set<Int32>()
    private var inFlight = Set<Int32>()
    private var sitemapSet = Set<Int32>()
    private var seq = 0
    private var startId: Int32?

    public private(set) var state: CrawlState = .idle
    private var stats = CrawlStats()
    private var lastEmittedStats = CrawlStats()
    private var lastEmittedState: CrawlState = .idle
    private var completions: [ContinuousClock.Instant] = []

    private var delay: Duration
    private var nextSlot = ContinuousClock.now
    private var robotsCache: [String: RobotsTxt] = [:]
    private var robotsTasks: [String: Task<RobotsTxt, Never>] = [:]

    private var pendingBatch = CrawlBatch()
    private var pendingWrite = StoreWrite()
    private var runTask: Task<Void, Never>?
    private var pauseRequested = false
    private var stopRequested = false

    public init(config: CrawlConfig, store: CrawlStore?, restored: StoredCrawl? = nil, protocolClasses: [AnyClass]? = nil) {
        self.config = config
        self.store = store
        fetcher = Fetcher(timeout: TimeInterval(config.timeoutSeconds), maxConnections: config.concurrency, protocolClasses: protocolClasses)
        token = config.userAgentPreset.robotsToken
        (events, continuation) = AsyncStream.makeStream(of: CrawlBatch.self, bufferingPolicy: .unbounded)
        normalizer = URLNormalizer(ignoredParams: config.ignoredParams)
        delay = .milliseconds(max(0, config.delayMs))
        includeRes = config.includePatterns.compactMap { $0.isEmpty ? nil : try? NSRegularExpression(pattern: $0) }
        excludeRes = config.excludePatterns.compactMap { $0.isEmpty ? nil : try? NSRegularExpression(pattern: $0) }
        skipExtensions = Set(config.skipExtensions.map { $0.lowercased() })

        let starts = config.mode == .list ? config.listURLs : [config.startURL]
        let normalizedStarts = starts.compactMap { URLNormalizer(ignoredParams: config.ignoredParams).normalize(Self.withScheme($0)) }
        scope = CrawlScope(kind: config.scope, startURLs: normalizedStarts)

        if let r = restored {
            urlList = r.urls
            for (i, u) in r.urls.enumerated() where !u.isEmpty { urlIds[u] = Int32(i) }
            startId = r.startId
            for p in r.pages {
                done.insert(p.id)
                stats.add(p)
            }
            for q in r.queue where !done.contains(q.id) {
                if q.priority == 0 { queueMain.append(q) } else { queueSecondary.append(q) }
                seq = max(seq, q.seq)
            }
            seen = done.union(r.queue.map(\.id))
            sitemapSet = Set(r.sitemapIds)
            state = r.state
            if let text = r.robotsText, config.userAgentPreset == .yandexbot {
                normalizer.cleanParams = RobotsTxt(text: text).cleanParams
            }
            stats.queued = queueMain.count + queueSecondary.count
        }
    }

    static func withScheme(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
        return "https://" + t
    }

    public var hasPendingWork: Bool { !queueMain.isEmpty || !queueSecondary.isEmpty }

    // MARK: - Управление

    /// Запускает обход или продолжает его после паузы.
    public func start() {
        guard runTask == nil else { return }
        pauseRequested = false
        stopRequested = false
        runTask = Task { await self.run() }
    }

    public func pause() {
        guard runTask != nil else { return }
        pauseRequested = true
        setState(.pausing)
    }

    public func stop() {
        guard runTask != nil else { return }
        pauseRequested = true
        stopRequested = true
        setState(.pausing)
    }

    /// Ждёт окончания текущего прогона (для CLI и тестов).
    public func waitUntilIdle() async {
        await runTask?.value
    }

    private func run() async {
        if startId == nil {
            setState(.preparing)
            await prepare()
        } else {
            await refreshRobotsOnResume()
        }
        if !pauseRequested { setState(.running) }

        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await self?.flush()
            }
        }
        let workers = max(1, config.concurrency)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask { await self.workerLoop() }
            }
        }
        ticker.cancel()

        if pauseRequested && !stopRequested {
            setState(.paused)
        } else {
            if stopRequested { pendingBatch.messages.append("Обход остановлен вручную") }
            else if done.count >= config.maxPages && hasPendingWork { pendingBatch.messages.append("Достигнут лимит в \(config.maxPages) URL") }
            setState(.finished)
        }
        runTask = nil
    }

    // MARK: - Подготовка

    private func prepare() async {
        let starts = config.mode == .list ? config.listURLs : [config.startURL]
        let normalized = starts.compactMap { normalizer.normalize(Self.withScheme($0)) }
        guard let first = normalized.first else {
            pendingBatch.messages.append("Некорректный стартовый адрес")
            pauseRequested = true
            stopRequested = true
            return
        }

        if let origin = CrawlScope.origin(of: first) {
            let robots = await robots(for: origin)
            pendingBatch.robotsText = robots.raw
            pendingWrite.meta["robots"] = Data(robots.raw.utf8)
            if config.userAgentPreset == .yandexbot { normalizer.cleanParams = robots.cleanParams }
            if config.respectRobots, let cd = robots.crawlDelay(token: token), cd > 0 {
                let ms = Int(cd * 1000)
                if ms > config.delayMs {
                    delay = .milliseconds(ms)
                    pendingBatch.messages.append("Crawl-delay из robots.txt: \(cd) с")
                }
            }
            if config.useSitemap {
                var list = robots.sitemaps
                if !config.sitemapURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    list = [Self.withScheme(config.sitemapURL)]
                } else if list.isEmpty {
                    list = [origin + "/sitemap.xml"]
                }
                await loadSitemaps(list)
            }
        }

        let (sid, _) = intern(first)
        startId = sid
        pendingBatch.startId = sid
        pendingWrite.meta["startId"] = Data(String(sid).utf8)

        if config.mode == .spider {
            enqueue(sid, depth: 0, priority: 0, force: true)
            if config.crawlSitemapURLs {
                for id in sitemapSet.sorted() { enqueue(id, depth: -1, priority: 1, force: false) }
            }
        } else {
            for u in normalized {
                let (id, _) = intern(u)
                enqueue(id, depth: 0, priority: 1, force: true)
            }
        }
        flush()
    }

    private func refreshRobotsOnResume() async {
        guard let sid = startId, let origin = CrawlScope.origin(of: urlList[Int(sid)]) else { return }
        let robots = await robots(for: origin)
        if config.userAgentPreset == .yandexbot { normalizer.cleanParams = robots.cleanParams }
        if config.respectRobots, let cd = robots.crawlDelay(token: token), Int(cd * 1000) > config.delayMs {
            delay = .milliseconds(Int(cd * 1000))
        }
    }

    private func loadSitemaps(_ initial: [String]) async {
        var queue = initial
        var visited = Set<String>()
        var files = 0
        var found = 0
        while !queue.isEmpty, files < 100, found < 50_000 {
            let sm = queue.removeFirst()
            guard !visited.contains(sm), let url = URL(string: sm) else { continue }
            visited.insert(sm)
            files += 1
            let res = await fetchFollowingRedirects(url, maxHops: 5)
            guard res.statusCode == 200, !res.body.isEmpty else {
                pendingBatch.messages.append("sitemap \(URLNormalizer.display(sm)): \(res.error ?? "код \(res.statusCode)")")
                continue
            }
            if res.body.starts(with: [0x1F, 0x8B]) {
                pendingBatch.messages.append("sitemap \(URLNormalizer.display(sm)): сжатые .gz пока не поддерживаются")
                continue
            }
            let parsed = SitemapParser.parse(res.body)
            queue += parsed.sitemaps
            for u in parsed.urls {
                guard let n = normalizer.normalize(u) else { continue }
                let (id, _) = intern(n)
                if sitemapSet.insert(id).inserted {
                    pendingBatch.sitemapIds.append(id)
                    pendingWrite.sitemapIds.append(id)
                    found += 1
                }
            }
        }
        pendingBatch.messages.append("sitemap: \(found) URL из \(files) файл(ов)")
    }

    private func fetchFollowingRedirects(_ url: URL, maxHops: Int) async -> FetchResult {
        var current = url
        var res = FetchResult()
        for _ in 0...maxHops {
            res = await fetcher.fetch(current, userAgent: config.userAgent, maxBytes: 50 * 1024 * 1024) { _ in true }
            guard (300..<400).contains(res.statusCode), let loc = res.location,
                  let next = URL(string: loc, relativeTo: current)?.absoluteURL else { return res }
            current = next
        }
        return res
    }

    // MARK: - robots.txt

    func robots(for origin: String) async -> RobotsTxt {
        if let r = robotsCache[origin] { return r }
        if let t = robotsTasks[origin] { return await t.value }
        let fetcher = self.fetcher
        let ua = config.userAgent
        let task = Task<RobotsTxt, Never> {
            guard let url = URL(string: origin + "/robots.txt") else { return RobotsTxt() }
            var current = url
            for _ in 0..<5 {
                let res = await fetcher.fetch(current, userAgent: ua, maxBytes: 512 * 1024) { _ in true }
                if (300..<400).contains(res.statusCode), let loc = res.location, let next = URL(string: loc, relativeTo: current)?.absoluteURL {
                    current = next
                    continue
                }
                if res.statusCode == 200 {
                    return RobotsTxt(text: HTMLTextDecoder.decode(res.body, contentType: res.contentType).text)
                }
                return RobotsTxt()
            }
            return RobotsTxt()
        }
        robotsTasks[origin] = task
        let r = await task.value
        robotsCache[origin] = r
        return r
    }

    // MARK: - Очередь

    private func intern(_ url: String) -> (Int32, Bool) {
        if let id = urlIds[url] { return (id, false) }
        let id = Int32(urlList.count)
        urlList.append(url)
        urlIds[url] = id
        let entry = URLEntry(id: id, url: url)
        pendingBatch.newURLs.append(entry)
        pendingWrite.newURLs.append(entry)
        return (id, true)
    }

    private func enqueue(_ id: Int32, depth: Int, priority: Int, force: Bool) {
        guard !seen.contains(id) else { return }
        let url = urlList[Int(id)]
        guard scope.inCrawlScope(url) else { return }
        if !force {
            if config.maxDepth > 0, depth > config.maxDepth { return }
            if hasSkippedExtension(url) { return }
            let ns = url as NSString
            let range = NSRange(location: 0, length: ns.length)
            if !includeRes.isEmpty, !includeRes.contains(where: { $0.firstMatch(in: url, range: range) != nil }) { return }
            if excludeRes.contains(where: { $0.firstMatch(in: url, range: range) != nil }) { return }
        }
        seen.insert(id)
        seq += 1
        let item = QueueItem(id: id, depth: depth, priority: priority, seq: seq)
        if priority == 0 { queueMain.append(item) } else { queueSecondary.append(item) }
        pendingWrite.queueAdd.append(item)
    }

    private func hasSkippedExtension(_ url: String) -> Bool {
        let path = CrawlScope.path(of: url)
        guard let last = path.split(separator: "/").last, let dot = last.lastIndex(of: ".") else { return false }
        return skipExtensions.contains(last[last.index(after: dot)...].lowercased())
    }

    struct Job: Sendable {
        var item: QueueItem
        var url: String
        var normalizer: URLNormalizer
    }

    enum Next: Sendable {
        case job(Job), wait, done
    }

    private func nextJob() -> Next {
        if pauseRequested { return .done }
        if done.count + inFlight.count >= config.maxPages { return inFlight.isEmpty ? .done : .wait }
        while let item = queueMain.popFirst() ?? queueSecondary.popFirst() {
            if done.contains(item.id) || inFlight.contains(item.id) { continue }
            inFlight.insert(item.id)
            return .job(Job(item: item, url: urlList[Int(item.id)], normalizer: normalizer))
        }
        return inFlight.isEmpty ? .done : .wait
    }

    /// Общая пауза между запросами для всех потоков.
    private func reserveSlot() -> Duration {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot)
        nextSlot = slot + delay
        return slot - now
    }

    // MARK: - Работа потока

    private nonisolated func workerLoop() async {
        while true {
            switch await nextJob() {
            case .done: return
            case .wait: try? await Task.sleep(for: .milliseconds(80))
            case .job(let job): await process(job)
            }
        }
    }

    private nonisolated func process(_ job: Job) async {
        guard let url = URL(string: job.url) else {
            var rec = PageRecord(id: job.item.id, url: job.url, state: .failed)
            rec.error = "Некорректный URL"
            await complete(job, rec, [], nil)
            return
        }
        if config.respectRobots, let origin = CrawlScope.origin(of: job.url) {
            let robots = await robots(for: origin)
            if !robots.isAllowed(RobotsTxt.pathAndQuery(of: job.url), token: token) {
                await complete(job, PageRecord(id: job.item.id, url: job.url, state: .blockedByRobots), [], nil)
                return
            }
        }
        let wait = await reserveSlot()
        if wait > .zero { try? await Task.sleep(for: wait) }

        let res = await fetcher.fetch(url, userAgent: config.userAgent, maxBytes: config.maxBodyBytes) { ct in
            ct.isEmpty || ct.lowercased().contains("html")
        }
        let (record, links, html) = Self.buildRecord(job: job, url: url, res: res, zoneRules: config.zoneRules)
        await complete(job, record, links, html)
    }

    struct ResolvedLink: Sendable {
        var url: String
        var anchor: String
        var rel: RelFlags
        var kind: LinkKind
        var zone: LinkZone
    }

    /// Превращает ответ сервера в запись страницы и список ссылок. Без состояния — тестируется отдельно.
    static func buildRecord(job: Job, url: URL, res: FetchResult, zoneRules: [ZoneRule] = []) -> (PageRecord, [ResolvedLink], Data?) {
        var rec = PageRecord(id: job.item.id, url: job.url, state: res.error == nil ? .fetched : .failed)
        rec.statusCode = res.statusCode
        rec.error = res.error
        rec.headers = res.headers
        rec.contentType = res.contentType
        rec.responseTimeMs = res.responseTimeMs
        rec.truncated = res.truncated
        rec.sizeBytes = res.body.isEmpty ? (Int(res.headers["content-length"] ?? "") ?? 0) : res.body.count
        rec.discoveryDepth = job.item.depth

        var links: [ResolvedLink] = []
        var htmlBlob: Data?

        if (300..<400).contains(res.statusCode), let loc = res.location {
            if let target = job.normalizer.normalize(loc, base: url) {
                rec.redirectURL = target
                links.append(ResolvedLink(url: target, anchor: "", rel: [], kind: .redirect, zone: .other))
            } else {
                rec.redirectURL = loc
            }
        }

        let ct = res.contentType.lowercased()
        let looksHTML = ct.contains("html") || (ct.isEmpty && Self.sniffHTML(res.body))
        if (200..<300).contains(res.statusCode), looksHTML, !res.body.isEmpty {
            let (text, charset) = HTMLTextDecoder.decode(res.body, contentType: res.contentType)
            rec.charset = charset
            if ct.isEmpty { rec.contentType = "text/html" }
            let parsed = HTMLAnalyzer.parse(text, zoneRules: zoneRules)
            rec.html = parsed.info
            let base = parsed.baseHref.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } ?? url
            for l in parsed.links {
                if let n = job.normalizer.normalize(l.href, base: base) {
                    links.append(ResolvedLink(url: n, anchor: l.anchor, rel: l.rel, kind: l.kind, zone: l.zone))
                }
            }
            var canonicals = parsed.info.canonicals
            if let header = res.headers["link"], let c = Self.canonicalFromLinkHeader(header) { canonicals.append(c) }
            for c in canonicals {
                if let n = job.normalizer.normalize(c, base: base) {
                    links.append(ResolvedLink(url: n, anchor: "", rel: [], kind: .canonical, zone: .other))
                }
            }
            for h in parsed.info.hreflang {
                if let n = job.normalizer.normalize(h.href, base: base) {
                    links.append(ResolvedLink(url: n, anchor: h.lang, rel: [], kind: .hreflang, zone: .other))
                }
            }
            htmlBlob = CrawlStore.compressHTML(text)
        }
        return (rec, links, htmlBlob)
    }

    static func sniffHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<html") || head.contains("<!doctype html") || head.contains("<head")
    }

    static func canonicalFromLinkHeader(_ header: String) -> String? {
        for part in header.split(separator: ",") {
            let s = String(part)
            guard s.lowercased().contains("canonical"),
                  let open = s.firstIndex(of: "<"), let close = s.firstIndex(of: ">"), open < close else { continue }
            return String(s[s.index(after: open)..<close])
        }
        return nil
    }

    private func complete(_ job: Job, _ record: PageRecord, _ links: [ResolvedLink], _ html: Data?) {
        let id = job.item.id
        inFlight.remove(id)
        done.insert(id)
        var rec = record
        var linkRecords: [LinkRecord] = []
        linkRecords.reserveCapacity(links.count)
        for l in links {
            let (tid, _) = intern(l.url)
            let external = !scope.isInternal(l.url)
            linkRecords.append(LinkRecord(source: id, target: tid, anchor: l.anchor, rel: l.rel, kind: l.kind, zone: l.zone, external: external))
            if l.kind == .redirect { rec.redirectTo = tid }
            guard !external, tid != id else { continue }
            switch l.kind {
            case .redirect:
                enqueue(tid, depth: max(job.item.depth, 0), priority: 0, force: false)
            case .anchor, .image, .canonical, .hreflang:
                // Цели hreflang загружаются, чтобы проверить код ответа и обратные ссылки.
                if config.mode == .spider {
                    enqueue(tid, depth: max(job.item.depth, 0) + 1, priority: 0, force: false)
                }
            }
        }
        stats.add(rec)
        completions.append(.now)
        pendingBatch.pages.append(rec)
        pendingBatch.links += linkRecords
        pendingWrite.pages.append((rec, html))
        pendingWrite.links += linkRecords
        pendingWrite.queueRemove.append(id)
    }

    // MARK: - Сброс изменений

    private func setState(_ s: CrawlState) {
        state = s
        flush()
    }

    func flush() {
        let now = ContinuousClock.now
        completions.removeAll { now - $0 > .seconds(5) }
        stats.urlsPerSecond = Double(completions.count) / 5
        stats.queued = queueMain.count + queueSecondary.count
        stats.inFlight = inFlight.count

        if !pendingWrite.isEmpty || state != lastEmittedState {
            pendingWrite.meta["state"] = Data(state.rawValue.utf8)
            do { try store?.write(pendingWrite) } catch {
                pendingBatch.messages.append("Не удалось записать файл обхода: \(error)")
            }
            pendingWrite = StoreWrite()
        }

        if !pendingBatch.isEmpty || stats != lastEmittedStats || state != lastEmittedState {
            var batch = pendingBatch
            batch.stats = stats
            batch.state = state
            continuation.yield(batch)
            pendingBatch = CrawlBatch()
            lastEmittedStats = stats
            lastEmittedState = state
        }
    }
}

extension CrawlStats {
    mutating func add(_ p: PageRecord) {
        crawled += 1
        switch p.state {
        case .blockedByRobots: blocked += 1
        case .failed: errors += 1
        case .fetched:
            switch p.statusCode {
            case 200..<300: status2xx += 1
            case 300..<400: status3xx += 1
            case 400..<500: status4xx += 1
            case 500..<600: status5xx += 1
            default: break
            }
        }
    }
}
