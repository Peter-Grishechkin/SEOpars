import AppKit
import SEOparsCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let session = app.session {
                CrawlView(session: session)
                    .id(ObjectIdentifier(session))
            } else {
                NewCrawlView()
            }
        }
        .alert("Ошибка", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

// MARK: - Боковая панель

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingTrash: URL?

    var body: some View {
        @Bindable var app = app
        List(selection: Binding(get: { app.selectedFile }, set: { url in
            if let url { app.open(url) }
        })) {
            Section("Обходы") {
                ForEach(app.library, id: \.fileURL) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URLNormalizer.display(item.startURL))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        let live = app.session?.fileURL == item.fileURL ? app.session : nil
                        let pages = live?.stats.crawled ?? item.pages
                        let state = live?.state ?? (item.state.isActive ? .interrupted : item.state)
                        HStack(spacing: 6) {
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("· \(pages) стр.")
                            if state != .finished {
                                Text("· \(state.title)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(item.fileURL)
                    .contextMenu {
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                        Divider()
                        Button("Переместить в корзину…", role: .destructive) { pendingTrash = item.fileURL }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { app.newCrawl() } label: { Label("Новый обход", systemImage: "plus") }
                    .help("Новый обход (⌘N)")
            }
        }
        .confirmationDialog("Переместить обход в корзину?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("В корзину", role: .destructive) {
                if let url = pendingTrash { app.moveToTrash(url) }
                pendingTrash = nil
            }
        } message: {
            Text("Файл можно будет восстановить из корзины.")
        }
    }
}

// MARK: - Новый обход

struct NewCrawlView: View {
    @Environment(AppModel.self) private var app
    @State private var showSettings = false
    @State private var showList = false

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $app.draft.mode) {
                    ForEach(CrawlMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if app.draft.mode == .spider {
                    TextField("https://example.ru/", text: $app.draft.startURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { app.startCrawl() }
                } else {
                    Button("Список URL (\(app.draft.listURLs.count))…") { showList = true }
                    Spacer()
                }
                Button { showSettings = true } label: { Label("Настройки", systemImage: "slider.horizontal.3") }
                Button { app.startCrawl() } label: { Label("Старт", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Новый обход").font(.title2.bold())
                Text(summary(app.draft))
                    .foregroundStyle(.secondary)
                Text("Обходы сохраняются в «\(CrawlLibrary.defaultDirectory.path)». Обход можно поставить на паузу и продолжить даже после перезапуска приложения.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 320, idealWidth: 640, maxWidth: 640, alignment: .leading)
            .padding(32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showSettings) {
            SettingsView(config: $app.draft, editable: true)
        }
        .sheet(isPresented: $showList) {
            URLListSheet(urls: $app.draft.listURLs)
        }
    }

    func summary(_ c: CrawlConfig) -> String {
        var parts = [c.scope.title.lowercased(), "до \(c.maxPages) URL", "потоков: \(c.concurrency)", "пауза \(c.delayMs) мс", "робот: \(c.userAgentPreset.title)"]
        if c.maxDepth > 0 { parts.append("глубина до \(c.maxDepth)") }
        parts.append(c.respectRobots ? "robots.txt учитывается" : "robots.txt игнорируется")
        if c.useSitemap { parts.append("sitemap загружается") }
        return "Настройки: " + parts.joined(separator: ", ") + "."
    }
}

struct URLListSheet: View {
    @Binding var urls: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Список URL").font(.headline)
            Text("По одному адресу в строке. Ссылки со страниц не обходятся, редиректы — да.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 320)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Загрузить из .txt…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.plainText]
                    if panel.runModal() == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) {
                        text = s
                    }
                }
                Spacer()
                Text("\(parsed.count) URL").foregroundStyle(.secondary)
                Button("Отмена") { dismiss() }
                Button("Готово") {
                    urls = parsed
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = urls.joined(separator: "\n") }
    }

    var parsed: [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Экран обхода

enum CrawlTab: String, CaseIterable, Identifiable {
    case overview, pages, meta, headings, links, redirects, issues
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Обзор"
        case .pages: "Страницы"
        case .meta: "Мета-теги"
        case .headings: "Заголовки"
        case .links: "Ссылки"
        case .redirects: "Редиректы"
        case .issues: "Проблемы"
        }
    }
}

struct CrawlView: View {
    @Environment(AppModel.self) private var app
    let session: CrawlSession
    @SceneStorage("crawlTab") private var tab: CrawlTab = .pages
    @State private var selectedPage: Int32?
    @State private var showSettings = false
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            CrawlTopBar(session: session, showSettings: $showSettings, showInspector: $showInspector)
            StatsBar(session: session)
            Divider()
            Picker("", selection: $tab) {
                ForEach(CrawlTab.allCases) { t in
                    Text(tabTitle(t)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            VSplitView {
                tabContent
                    .frame(minHeight: 200, maxHeight: .infinity)
                if showInspector {
                    InspectorView(session: session, pageId: $selectedPage)
                        .frame(minHeight: 160, idealHeight: 280, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ThresholdsSheet(session: session)
        }
        .onChange(of: session.state) { _, new in
            if !new.isActive { app.refreshLibrary() }
        }
    }

    func tabTitle(_ t: CrawlTab) -> String {
        switch t {
        case .pages:
            return "\(t.title) · \(session.rows.count)"
        case .issues:
            let n = session.analysis.issues.values.reduce(0) { $0 + $1.count }
            return n > 0 ? "\(t.title) · \(n)" : t.title
        case .redirects:
            return session.redirectRows.isEmpty ? t.title : "\(t.title) · \(session.redirectRows.count)"
        default:
            return t.title
        }
    }

    @ViewBuilder var tabContent: some View {
        switch tab {
        case .overview: OverviewView(session: session, tab: $tab)
        case .pages: PagesTableView(session: session, kind: .pages, selection: $selectedPage)
        case .meta: PagesTableView(session: session, kind: .meta, selection: $selectedPage)
        case .headings: PagesTableView(session: session, kind: .headings, selection: $selectedPage)
        case .links: LinksView(session: session, selection: $selectedPage)
        case .redirects: RedirectsView(session: session, selection: $selectedPage)
        case .issues: IssuesView(session: session, selection: $selectedPage)
        }
    }
}

struct CrawlTopBar: View {
    @Environment(AppModel.self) private var app
    let session: CrawlSession
    @Binding var showSettings: Bool
    @Binding var showInspector: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.config.mode == .spider ? "globe" : "list.bullet")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if session.isRunning {
                Button { session.pause() } label: { Label("Пауза", systemImage: "pause.fill") }
                    .disabled(session.state == .pausing)
                Button { session.stop() } label: { Label("Стоп", systemImage: "stop.fill") }
                    .disabled(session.state == .pausing)
            } else if session.canResume {
                Button { session.resume() } label: { Label("Продолжить", systemImage: "play.fill") }
            }
            Button { showSettings = true } label: { Label("Пороги", systemImage: "slider.horizontal.3") }
                .help("Пороги проверок и настройки этого обхода")
            ExportMenu(session: session)
            Toggle(isOn: $showInspector) { Label("Инспектор", systemImage: "rectangle.bottomthird.inset.filled") }
                .toggleStyle(.button)
                .help("Показать или скрыть инспектор страницы")
        }
        .padding(12)
    }

    var title: String {
        let c = session.config
        return c.mode == .spider ? URLNormalizer.display(c.startURL) : "Список: \(c.listURLs.count) URL"
    }
}

struct StatsBar: View {
    let session: CrawlSession

    var body: some View {
        let s = session.stats
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                if session.isRunning { ProgressView().controlSize(.small) }
                Text(session.state.title)
            }
            .fixedSize()
            stat("Обойдено", s.crawled)
            stat("В очереди", s.queued)
            stat("2xx", s.status2xx, .green)
            stat("3xx", s.status3xx, .orange)
            stat("4xx", s.status4xx, .red)
            stat("5xx", s.status5xx, .red)
            stat("Ошибки", s.errors, .red)
            stat("robots", s.blocked)
            if session.isRunning {
                Text(String(format: "%.1f URL/с", s.urlsPerSecond)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if !session.analysisIsFinal {
                // Узкое окно: вместо текста остаётся значок, текст — в подсказке и для VoiceOver (HANDOFF §10, вопрос 3).
                ViewThatFits(in: .horizontal) {
                    Label(Self.provisionalText, systemImage: "hourglass").lineLimit(1)
                    Image(systemName: "hourglass")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Self.provisionalText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.provisionalText)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    static let provisionalText = "Обход не завершён: дубли, сироты и глубина — промежуточные"

    func stat(_ title: String, _ value: Int, _ color: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").monospacedDigit().foregroundStyle(value > 0 ? color : .secondary)
        }
        .fixedSize()
    }
}
