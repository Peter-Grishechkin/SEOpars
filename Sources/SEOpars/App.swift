import AppKit
import SEOparsCore
import SwiftUI

@main
struct SEOparsApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("SEOpars", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый обход") { app.newCrawl() }
                    .keyboardShortcut("n")
                Button("Открыть файл обхода…") { app.openWithPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("Telegram-канал автора") { NSWorkspace.shared.open(URL(string: "https://t.me/seo_and_sem")!) }
            }
        }
    }
}

/// Состояние приложения: список обходов, текущий обход, черновик настроек нового обхода.
@MainActor
@Observable
final class AppModel {
    var library: [CrawlStore.Summary] = []
    var session: CrawlSession?
    var selectedFile: URL?
    var draft: CrawlConfig {
        didSet { saveDraft() }
    }
    var errorMessage: String?

    private static let draftKey = "draftConfig"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.draftKey),
           let cfg = try? JSONDecoder().decode(CrawlConfig.self, from: data) {
            draft = cfg
        } else {
            draft = CrawlConfig()
        }
        refreshLibrary()
        // open -a SEOpars --args --start https://example.ru/  — сразу начать обход.
        let args = CommandLine.arguments
        // Настройки берутся из черновика, но сам черновик не меняется.
        if let i = args.firstIndex(of: "--start"), i + 1 < args.count {
            var cfg = draft
            cfg.mode = .spider
            cfg.startURL = args[i + 1]
            if let d = args.firstIndex(of: "--delay"), d + 1 < args.count, let ms = Int(args[d + 1]) { cfg.delayMs = ms }
            Task { @MainActor in self.startCrawl(cfg) }
        }
    }

    private func saveDraft() {
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: Self.draftKey)
        }
    }

    func refreshLibrary() {
        library = CrawlLibrary.list()
    }

    /// Пустой экран нового обхода. Если идёт обход — ставим на паузу (его можно продолжить).
    func newCrawl() {
        if let s = session {
            if s.isRunning { s.pause() }
            draft = s.config
            draft.listURLs = s.config.listURLs
        }
        session = nil
        selectedFile = nil
    }

    func startCrawl(_ config: CrawlConfig? = nil) {
        var cfg = config ?? draft
        cfg.startURL = cfg.startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cfg.mode == .spider, cfg.startURL.isEmpty {
            errorMessage = "Укажите адрес сайта"
            return
        }
        if cfg.mode == .list, cfg.listURLs.isEmpty {
            errorMessage = "Список URL пуст"
            return
        }
        let s = CrawlSession(config: cfg)
        do {
            try s.start(in: CrawlLibrary.defaultDirectory)
            session = s
            selectedFile = s.fileURL
            refreshLibrary()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func open(_ url: URL) {
        if session?.fileURL == url { return }
        if let s = session, s.isRunning { s.pause() }
        do {
            session = try CrawlSession.open(url)
            selectedFile = url
        } catch {
            errorMessage = "Не удалось открыть обход: \(error)"
            session = nil
        }
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: CrawlStore.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func moveToTrash(_ url: URL) {
        if session?.fileURL == url {
            if session?.isRunning == true { session?.stop() }
            session = nil
            selectedFile = nil
        }
        for suffix in ["", "-wal", "-shm"] {
            let f = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: f.path) {
                try? FileManager.default.trashItem(at: f, resultingItemURL: nil)
            }
        }
        refreshLibrary()
    }
}
