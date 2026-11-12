import Foundation
import Observation

/// Модель обхода для интерфейса. Принимает пачки от обходчика, держит данные в памяти
/// и пересчитывает анализ в фоне не чаще раза в `analysisInterval`.
@MainActor
@Observable
public final class CrawlSession {
    public private(set) var fileURL: URL?
    public var config: CrawlConfig
    public private(set) var data: CrawlData
    public private(set) var analysis = CrawlAnalysis.empty
    public private(set) var rows: [PageRow] = []
    public private(set) var redirectRows: [RedirectRow] = []
    public private(set) var state: CrawlState = .idle
    public private(set) var stats = CrawlStats()
    public private(set) var messages: [String] = []
    /// Растёт при каждом обновлении анализа: по нему таблицы понимают, что пора перестроиться.
    public private(set) var revision = 0
    /// Анализ сделан на полных данных (обход не идёт).
    public private(set) var analysisIsFinal = true
    public private(set) var lastError: String?

    @ObservationIgnored private var crawler: Crawler?
    @ObservationIgnored private var readStore: CrawlStore?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var analysisRunning = false
    @ObservationIgnored private var analysisDirty = false
    @ObservationIgnored private var lastAnalysisAt = ContinuousClock.now - .seconds(10)
    @ObservationIgnored public var analysisInterval: Duration = .milliseconds(500)
    @ObservationIgnored private let protocolClasses: [AnyClass]?

    public init(config: CrawlConfig = CrawlConfig(), protocolClasses: [AnyClass]? = nil) {
        self.config = config
        data = CrawlData(config: config)
        self.protocolClasses = protocolClasses
    }

    /// Открывает сохранённый обход.
    public static func open(_ url: URL, protocolClasses: [AnyClass]? = nil) throws -> CrawlSession {
        let store = try CrawlStore.open(at: url)
        let stored = try store.load()
        let s = CrawlSession(config: stored.config, protocolClasses: protocolClasses)
        s.fileURL = url
        s.data = CrawlData(stored: stored)
        s.state = stored.state.isActive ? .interrupted : stored.state
        var st = CrawlStats()
        for p in stored.pages { st.add(p) }
        st.queued = stored.queue.filter { s.data.pageIndex[$0.id] == nil }.count
        s.stats = st
        s.readStore = try? CrawlStore.open(at: url, readOnly: true)
        s.crawler = Crawler(config: stored.config, store: store, restored: stored, protocolClasses: protocolClasses)
        s.listen()
        s.scheduleAnalysis()
        return s
    }

    public var isRunning: Bool { state.isActive }
    public var canStart: Bool { crawler == nil && !state.isActive }
    public var canResume: Bool {
        crawler != nil && !state.isActive && (state == .paused || state == .interrupted || state == .finished) && stats.queued > 0
    }

    /// Новый обход: создаёт файл в `directory` и запускает.
    public func start(in directory: URL) throws {
        guard canStart else { return }
        let url = CrawlLibrary.newFileURL(for: config, in: directory)
        let store = try CrawlStore.create(at: url, config: config)
        fileURL = url
        data = CrawlData(config: config)
        analysis = .empty
        rows = []
        redirectRows = []
        messages = []
        readStore = try? CrawlStore.open(at: url, readOnly: true)
        let crawler = Crawler(config: config, store: store, protocolClasses: protocolClasses)
        self.crawler = crawler
        listen()
        // Состояние меняем сразу, чтобы интерфейс не ждал первой пачки от обходчика.
        state = .preparing
        startTask = Task { await crawler.start() }
    }

    public func resume() {
        guard let crawler, canResume else { return }
        state = .running
        startTask = Task { await crawler.start() }
    }

    public func pause() {
        guard let crawler else { return }
        Task { await crawler.pause() }
    }

    public func stop() {
        guard let crawler else { return }
        Task { await crawler.stop() }
    }

    /// Ждёт окончания текущего прогона обходчика и последнего анализа (для тестов и CLI).
    public func waitUntilIdle() async {
        await startTask?.value
        await crawler?.waitUntilIdle()
        // Дать дочитать события и досчитать анализ.
        for _ in 0..<400 {
            if !state.isActive, !analysisRunning, !analysisDirty, analysis.pageCount == data.pages.count { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func listen() {
        eventsTask?.cancel()
        guard let crawler else { return }
        let stream = crawler.events
        eventsTask = Task { [weak self] in
            for await batch in stream {
                self?.apply(batch)
            }
        }
    }

    func apply(_ batch: CrawlBatch) {
        data.apply(batch)
        stats = batch.stats
        if batch.state != state {
            state = batch.state
        }
        if !batch.messages.isEmpty { messages += batch.messages }
        if !batch.pages.isEmpty || !batch.links.isEmpty || !state.isActive || !batch.sitemapIds.isEmpty || !batch.sitemapFiles.isEmpty {
            scheduleAnalysis()
        }
    }

    private func scheduleAnalysis() {
        if analysisRunning {
            analysisDirty = true
            return
        }
        analysisRunning = true
        analysisDirty = false
        Task { [weak self] in
            guard let self else { return }
            let since = ContinuousClock.now - self.lastAnalysisAt
            if since < self.analysisInterval, self.state.isActive {
                try? await Task.sleep(for: self.analysisInterval - since)
            }
            let snapshot = self.data
            let final = !self.state.isActive
            let (a, rows, redirects) = await Task.detached(priority: .userInitiated) {
                let a = CrawlAnalyzer.analyze(snapshot)
                return (a, PageRow.build(snapshot, a), RedirectRow.build(snapshot, a))
            }.value
            self.analysis = a
            self.rows = rows
            self.redirectRows = redirects
            self.analysisIsFinal = final
            self.revision += 1
            self.lastAnalysisAt = .now
            self.analysisRunning = false
            if self.analysisDirty || (final != !self.state.isActive) || a.pageCount != self.data.pages.count {
                self.scheduleAnalysis()
            }
        }
    }

    // MARK: - Доступ к данным

    public func page(_ id: Int32) -> PageRecord? { data.page(id) }
    public func url(_ id: Int32) -> String { data.url(id) }
    public func html(for id: Int32) -> String? { readStore?.html(for: id) }

    public func linkRows(_ indices: [Int]) -> [LinkRow] {
        let display = displayURLs()
        return indices.compactMap { i in i < data.links.count ? LinkRow.make(i, data.links[i], data, display: display) : nil }
    }

    /// Все ссылки строками таблицы; строится в фоне.
    public func allLinkRows() async -> [LinkRow] {
        let snapshot = data
        let display = displayURLs()
        return await Task.detached(priority: .userInitiated) {
            snapshot.links.enumerated().map { LinkRow.make($0.offset, $0.element, snapshot, display: display) }
        }.value
    }

    @ObservationIgnored private var displayCache: [String] = []

    /// Читаемые адреса по id (кэш растёт вместе со списком URL).
    public func displayURLs() -> [String] {
        if displayCache.count < data.urls.count {
            displayCache += data.urls[displayCache.count...].map(URLNormalizer.display)
        }
        return displayCache
    }

    public func displayURL(_ id: Int32) -> String {
        let d = displayURLs()
        return Int(id) < d.count ? d[Int(id)] : ""
    }

    /// Пересохранить настройки (например, пороги) — анализ пересчитается.
    public func updateThresholds(_ t: Thresholds) {
        config.thresholds = t
        data.config.thresholds = t
        if let url = fileURL, let store = try? CrawlStore.open(at: url) {
            try? store.saveConfig(data.config)
        }
        scheduleAnalysis()
    }
}

/// Папка с обходами.
public enum CrawlLibrary {
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SEOpars/Crawls", isDirectory: true)
    }

    public static func newFileURL(for config: CrawlConfig, in directory: URL) -> URL {
        let start = config.mode == .list ? (config.listURLs.first ?? "list") : config.startURL
        let normalized = URLNormalizer().normalize(Crawler.withScheme(start)) ?? start
        var host = CrawlScope.host(of: normalized).map { Punycode.decodeHost($0) } ?? "crawl"
        host = host.replacingOccurrences(of: "/", with: "-")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "\(host)-\(f.string(from: Date())).\(CrawlStore.fileExtension)"
        return directory.appendingPathComponent(name)
    }

    public static func list(in directory: URL = defaultDirectory) -> [CrawlStore.Summary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == CrawlStore.fileExtension }
            .compactMap { CrawlStore.summary(at: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
