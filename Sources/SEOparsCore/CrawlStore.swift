import Foundation
import SQLite3

public struct StoreError: Error, CustomStringConvertible {
    public var description: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Минимальная обёртка над SQLite.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(handle)
            throw StoreError(description: "Не открыть файл обхода: \(msg)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StoreError(description: "SQLite: \(msg)")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError(description: "SQLite: \(String(cString: sqlite3_errmsg(handle)))")
        }
        return Statement(stmt)
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    let stmt: OpaquePointer
    init(_ stmt: OpaquePointer) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let x as Int: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Int32: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Int64: sqlite3_bind_int64(stmt, idx, x)
            case let x as Bool: sqlite3_bind_int64(stmt, idx, x ? 1 : 0)
            case let x as UInt8: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as String: sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            case let x as Data:
                x.withUnsafeBytes { buf in
                    _ = sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return self
    }

    func run() throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError(description: "SQLite: \(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))")
        }
    }

    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }

    func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }
    func string(_ col: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: p)
    }
    func data(_ col: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
    }
}

/// Запись очереди обхода.
public struct QueueItem: Sendable, Equatable {
    public var id: Int32
    public var depth: Int
    /// 0 — найдено по ссылкам, 1 — из sitemap/списка.
    public var priority: Int
    public var seq: Int
}

/// Всё, что лежит в файле обхода.
public struct StoredCrawl: Sendable {
    public var config: CrawlConfig
    public var state: CrawlState
    public var createdAt: Date
    public var startId: Int32?
    public var robotsText: String?
    public var urls: [String]
    public var pages: [PageRecord]
    public var links: [LinkRecord]
    public var queue: [QueueItem]
    public var sitemapIds: [Int32]
    /// Файлы sitemap по URL (№ 104). В файлах старше 2026-11-12 таблицы нет — пусто.
    public var sitemapFiles: [SitemapEntry] = []
}

/// Изменения за один сброс на диск. Применяются одной транзакцией: если приложение упадёт,
/// файл останется согласованным — незаписанные страницы всё ещё будут в очереди.
struct StoreWrite {
    var newURLs: [URLEntry] = []
    var pages: [(PageRecord, Data?)] = []
    var links: [LinkRecord] = []
    var queueAdd: [QueueItem] = []
    var queueRemove: [Int32] = []
    var sitemapIds: [Int32] = []
    var sitemapFiles: [SitemapEntry] = []
    var meta: [String: Data] = [:]

    var isEmpty: Bool {
        newURLs.isEmpty && pages.isEmpty && links.isEmpty && queueAdd.isEmpty && queueRemove.isEmpty && sitemapIds.isEmpty
            && sitemapFiles.isEmpty && meta.isEmpty
    }
}

/// Файл обхода `.seocrawl` (SQLite).
public final class CrawlStore: @unchecked Sendable {
    public let fileURL: URL
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static let fileExtension = "seocrawl"

    private init(fileURL: URL, readOnly: Bool) throws {
        self.fileURL = fileURL
        db = try SQLiteDB(path: fileURL.path, readOnly: readOnly)
        if !readOnly {
            try db.exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value BLOB);
            CREATE TABLE IF NOT EXISTS urls(id INTEGER PRIMARY KEY, url TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS pages(id INTEGER PRIMARY KEY, record BLOB NOT NULL, html BLOB);
            CREATE TABLE IF NOT EXISTS links(source INTEGER, target INTEGER, anchor TEXT, rel INTEGER, kind INTEGER, zone INTEGER, external INTEGER);
            CREATE TABLE IF NOT EXISTS queue(id INTEGER PRIMARY KEY, depth INTEGER, priority INTEGER, seq INTEGER);
            CREATE TABLE IF NOT EXISTS sitemap(id INTEGER PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS sitemap_files(id INTEGER, file TEXT, PRIMARY KEY(id, file));
            """)
        }
    }

    public static func create(at url: URL, config: CrawlConfig) throws -> CrawlStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try CrawlStore(fileURL: url, readOnly: false)
        try store.setMeta("config", try store.encoder.encode(config))
        try store.setMeta("createdAt", Data(String(Date().timeIntervalSince1970).utf8))
        try store.setMeta("state", Data(CrawlState.idle.rawValue.utf8))
        return store
    }

    public static func open(at url: URL, readOnly: Bool = false) throws -> CrawlStore {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError(description: "Файл не найден: \(url.path)")
        }
        return try CrawlStore(fileURL: url, readOnly: readOnly)
    }

    func setMeta(_ key: String, _ value: Data) throws {
        try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)").bind(key, value).run()
    }

    func meta(_ key: String) -> Data? {
        guard let st = try? db.prepare("SELECT value FROM meta WHERE key = ?") else { return nil }
        st.bind(key)
        return st.step() ? st.data(0) : nil
    }

    public func saveConfig(_ config: CrawlConfig) throws {
        try setMeta("config", try encoder.encode(config))
    }

    public func saveState(_ state: CrawlState) throws {
        try setMeta("state", Data(state.rawValue.utf8))
    }

    func write(_ w: StoreWrite) throws {
        guard !w.isEmpty else { return }
        try db.transaction {
            if !w.newURLs.isEmpty {
                let st = try db.prepare("INSERT OR IGNORE INTO urls(id, url) VALUES(?, ?)")
                for u in w.newURLs { try st.bind(u.id, u.url).run() }
            }
            if !w.pages.isEmpty {
                let st = try db.prepare("INSERT OR REPLACE INTO pages(id, record, html) VALUES(?, ?, ?)")
                for (p, html) in w.pages { try st.bind(p.id, try encoder.encode(p), html).run() }
            }
            if !w.links.isEmpty {
                let st = try db.prepare("INSERT INTO links(source, target, anchor, rel, kind, zone, external) VALUES(?, ?, ?, ?, ?, ?, ?)")
                for l in w.links {
                    try st.bind(l.source, l.target, l.anchor, l.rel.rawValue, l.kind.rawValue, l.zone.rawValue, l.external).run()
                }
            }
            if !w.queueAdd.isEmpty {
                let st = try db.prepare("INSERT OR REPLACE INTO queue(id, depth, priority, seq) VALUES(?, ?, ?, ?)")
                for q in w.queueAdd { try st.bind(q.id, q.depth, q.priority, q.seq).run() }
            }
            if !w.queueRemove.isEmpty {
                let st = try db.prepare("DELETE FROM queue WHERE id = ?")
                for id in w.queueRemove { try st.bind(id).run() }
            }
            if !w.sitemapIds.isEmpty {
                let st = try db.prepare("INSERT OR IGNORE INTO sitemap(id) VALUES(?)")
                for id in w.sitemapIds { try st.bind(id).run() }
            }
            if !w.sitemapFiles.isEmpty {
                let st = try db.prepare("INSERT OR IGNORE INTO sitemap_files(id, file) VALUES(?, ?)")
                for e in w.sitemapFiles { try st.bind(e.id, e.file).run() }
            }
            for (k, v) in w.meta { try setMeta(k, v) }
        }
    }

    public func load() throws -> StoredCrawl {
        guard let cfgData = meta("config") else { throw StoreError(description: "В файле нет настроек обхода") }
        let config = try decoder.decode(CrawlConfig.self, from: cfgData)
        let state = meta("state").flatMap { CrawlState(rawValue: String(decoding: $0, as: UTF8.self)) } ?? .idle
        let created = meta("createdAt").flatMap { Double(String(decoding: $0, as: UTF8.self)) }.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let startId = meta("startId").flatMap { Int32(String(decoding: $0, as: UTF8.self)) }
        let robots = meta("robots").map { String(decoding: $0, as: UTF8.self) }

        var urls: [String] = []
        let us = try db.prepare("SELECT id, url FROM urls ORDER BY id")
        while us.step() {
            let id = us.int(0)
            // id выдаются подряд с нуля; на случай дыр заполняем пустыми строками.
            while urls.count < id { urls.append("") }
            urls.append(us.string(1) ?? "")
        }

        var pages: [PageRecord] = []
        let ps = try db.prepare("SELECT record FROM pages ORDER BY rowid")
        while ps.step() {
            if let d = ps.data(0), let p = try? decoder.decode(PageRecord.self, from: d) { pages.append(p) }
        }

        var links: [LinkRecord] = []
        let ls = try db.prepare("SELECT source, target, anchor, rel, kind, zone, external FROM links ORDER BY rowid")
        while ls.step() {
            links.append(LinkRecord(
                source: Int32(ls.int(0)), target: Int32(ls.int(1)), anchor: ls.string(2) ?? "",
                rel: RelFlags(rawValue: UInt8(ls.int(3))), kind: LinkKind(rawValue: UInt8(ls.int(4))) ?? .anchor,
                zone: LinkZone(rawValue: UInt8(ls.int(5))) ?? .other, external: ls.int(6) != 0
            ))
        }

        var queue: [QueueItem] = []
        let qs = try db.prepare("SELECT id, depth, priority, seq FROM queue ORDER BY priority, seq")
        while qs.step() {
            queue.append(QueueItem(id: Int32(qs.int(0)), depth: qs.int(1), priority: qs.int(2), seq: qs.int(3)))
        }

        var sitemapIds: [Int32] = []
        let ss = try db.prepare("SELECT id FROM sitemap")
        while ss.step() { sitemapIds.append(Int32(ss.int(0))) }

        // Таблицы нет в файлах старше 2026-11-12, а только для чтения она не создаётся (`report`): тогда пусто.
        var sitemapFiles: [SitemapEntry] = []
        if let fs = try? db.prepare("SELECT id, file FROM sitemap_files ORDER BY rowid") {
            while fs.step() { sitemapFiles.append(SitemapEntry(id: Int32(fs.int(0)), file: fs.string(1) ?? "")) }
        }

        return StoredCrawl(config: config, state: state, createdAt: created, startId: startId, robotsText: robots,
                           urls: urls, pages: pages, links: links, queue: queue, sitemapIds: sitemapIds, sitemapFiles: sitemapFiles)
    }

    /// Исходный код страницы для инспектора.
    public func html(for id: Int32) -> String? {
        guard let st = try? db.prepare("SELECT html FROM pages WHERE id = ?") else { return nil }
        st.bind(id)
        guard st.step(), let blob = st.data(0) else { return nil }
        guard let raw = try? (blob as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }

    static func compressHTML(_ text: String) -> Data? {
        try? (Data(text.utf8) as NSData).compressed(using: .lzfse) as Data
    }

    /// Краткие сведения для списка обходов.
    public struct Summary: Sendable, Hashable {
        public var fileURL: URL
        public var startURL: String
        public var createdAt: Date
        public var pages: Int
        public var state: CrawlState
    }

    public static func summary(at url: URL) -> Summary? {
        guard let store = try? CrawlStore(fileURL: url, readOnly: true),
              let cfgData = store.meta("config"),
              let cfg = try? store.decoder.decode(CrawlConfig.self, from: cfgData)
        else { return nil }
        let state = store.meta("state").flatMap { CrawlState(rawValue: String(decoding: $0, as: UTF8.self)) } ?? .idle
        let created = store.meta("createdAt").flatMap { Double(String(decoding: $0, as: UTF8.self)) }.map { Date(timeIntervalSince1970: $0) } ?? Date()
        var count = 0
        if let st = try? store.db.prepare("SELECT COUNT(*) FROM pages"), st.step() { count = st.int(0) }
        let start = cfg.mode == .list ? (cfg.listURLs.first ?? "Список URL") : cfg.startURL
        return Summary(fileURL: url, startURL: start, createdAt: created, pages: count, state: state)
    }
}
