import AppKit
import SEOparsCore
import SwiftUI

/// Настройки нового обхода.
struct SettingsView: View {
    @Binding var config: CrawlConfig
    let editable: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Область") {
                    Picker("Границы", selection: $config.scope) {
                        ForEach(CrawlScopeKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Stepper("Лимит URL: \(config.maxPages)", value: $config.maxPages, in: 10...50_000, step: 500)
                    Stepper(config.maxDepth == 0 ? "Глубина: без ограничения" : "Глубина: до \(config.maxDepth)", value: $config.maxDepth, in: 0...50)
                }
                Section("Скорость") {
                    Stepper("Потоков: \(config.concurrency)", value: $config.concurrency, in: 1...10)
                    Stepper("Пауза между запросами: \(config.delayMs) мс", value: $config.delayMs, in: 0...10_000, step: 100)
                    Stepper("Тайм-аут: \(config.timeoutSeconds) с", value: $config.timeoutSeconds, in: 5...120, step: 5)
                    Text("Пауза общая для всех потоков. Если в robots.txt задан Crawl-delay больше паузы, используется он.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Робот") {
                    Picker("User-Agent", selection: $config.userAgentPreset) {
                        ForEach(UserAgentPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if config.userAgentPreset == .custom {
                        TextField("Строка User-Agent", text: $config.customUserAgent)
                    }
                    Toggle("Учитывать robots.txt", isOn: $config.respectRobots)
                    Text("Для YandexBot применяется Clean-param из robots.txt. Группа правил выбирается по роботу: YandexBot → Yandex → *, Googlebot → *.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sitemap") {
                    Toggle("Загружать sitemap.xml", isOn: $config.useSitemap)
                    TextField("Адрес sitemap (пусто — из robots.txt или /sitemap.xml)", text: $config.sitemapURL)
                        .disabled(!config.useSitemap)
                    Toggle("Обходить адреса из sitemap", isOn: $config.crawlSitemapURLs)
                        .disabled(!config.useSitemap)
                    Text("Нужно для поиска страниц-сирот: есть в sitemap, но на них никто не ссылается.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Фильтры URL (регулярные выражения, по одному в строке)") {
                    LinesEditor(title: "Исключить", lines: $config.excludePatterns, placeholder: "/wp-admin/\n\\?add-to-cart=")
                    LinesEditor(title: "Обходить только", lines: $config.includePatterns, placeholder: "/blog/")
                    LinesEditor(title: "Игнорировать параметры (* в конце — по префиксу)", lines: $config.ignoredParams, placeholder: "utm_*")
                }
                ZoneRulesSection(rules: $config.zoneRules)
                ThresholdsSection(thresholds: $config.thresholds)
            }
            .formStyle(.grouped)
            .disabled(!editable)
            HStack {
                Button("Сбросить настройки") { config = CrawlConfig(startURL: config.startURL, mode: config.mode, listURLs: config.listURLs) }
                    .disabled(!editable)
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 680)
    }
}

extension CrawlConfig {
    init(startURL: String, mode: CrawlMode, listURLs: [String]) {
        self.init()
        self.startURL = startURL
        self.mode = mode
        self.listURLs = listURLs
    }
}

/// Свои правила зон ссылок (№ 115) и проверка на вставленном HTML.
struct ZoneRulesSection: View {
    @Binding var rules: [ZoneRule]
    @State private var sample = ""

    var body: some View {
        Section("Зоны ссылок: свои правила раньше эвристики") {
            ForEach(rules) { rule in
                let bound = binding(for: rule.id)
                HStack {
                    Picker("Зона", selection: bound.zone) {
                        ForEach(ZoneRule.assignableZones, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Text("←").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("CSS-селектор предка", text: bound.selector, prompt: Text(".elementor-location-header"))
                        .font(.system(.callout, design: .monospaced))
                        .accessibilityLabel("CSS-селектор для зоны «\(rule.zone.title)»")
                    Button { rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Удалить правило")
                        .accessibilityLabel("Удалить правило")
                }
                if !rule.selector.isEmpty, let error = HTMLAnalyzer.selectorError(rule.selector) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Button("Добавить правило") { rules.append(ZoneRule(zone: .header, selector: "")) }
            Text("Ссылка внутри элемента, подходящего под селектор, получает зону правила. Срабатывает ближайший подходящий предок, при равенстве — правило выше. Правила применяются во время обхода: в готовом обходе зоны не пересчитываются.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Проверить на вставленном HTML") {
                TextEditor(text: $sample)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 90)
                    .accessibilityLabel("HTML для проверки правил")
                let results = preview
                if results.isEmpty {
                    Text("Вставьте HTML со ссылками — появятся их зоны.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(results.indices, id: \.self) { i in
                    let r = results[i]
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.link).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(r.zone.title)
                        if r.zone != r.heuristic {
                            Text("(эвристика: \(r.heuristic.title))").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Привязка к правилу по id, а не по индексу, как у `ForEach($rules)`. Поле ввода удалённого правила,
    /// если в нём был фокус, ещё раз читает свою привязку, а индекс уже за концом массива: приложение
    /// падало на `Array._checkSubscript` (2026-11-12). Здесь такое поле читает пустое правило, запись теряется.
    private func binding(for id: UUID) -> Binding<ZoneRule> {
        Binding(
            get: { rules.first { $0.id == id } ?? ZoneRule(zone: .header, selector: "") },
            set: { new in
                guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
                rules[i] = new
            }
        )
    }

    /// Ссылки из вставленного HTML: зона по правилам и зона по одной эвристике.
    var preview: [(link: String, zone: LinkZone, heuristic: LinkZone)] {
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let byRules = HTMLAnalyzer.parse(sample, zoneRules: rules).links
        let byHeuristic = HTMLAnalyzer.parse(sample).links
        return zip(byRules, byHeuristic).prefix(50).map { r, h in
            (link: r.anchor.isEmpty ? r.href : "\(r.anchor) — \(r.href)", zone: r.zone, heuristic: h.zone)
        }
    }
}

struct ThresholdsSection: View {
    @Binding var thresholds: Thresholds

    var body: some View {
        Section("Пороги проверок (ориентиры, не нормы поисковиков)") {
            Stepper("Title: от \(thresholds.titleMin)", value: $thresholds.titleMin, in: 1...200)
            Stepper("Title: до \(thresholds.titleMax)", value: $thresholds.titleMax, in: 10...300)
            Stepper("Description: от \(thresholds.descriptionMin)", value: $thresholds.descriptionMin, in: 1...300, step: 5)
            Stepper("Description: до \(thresholds.descriptionMax)", value: $thresholds.descriptionMax, in: 10...500, step: 5)
            Stepper("Глубокие страницы: глубже \(thresholds.maxClickDepth) кликов", value: $thresholds.maxClickDepth, in: 1...20)
            Stepper("Мало текста: меньше \(thresholds.minWords) слов", value: $thresholds.minWords, in: 0...2000, step: 10)
            Stepper("Медленный ответ: дольше \(thresholds.slowResponseMs) мс", value: $thresholds.slowResponseMs, in: 100...20_000, step: 100)
            Stepper("Мало входящих: 1–\(thresholds.fewInlinksMax)", value: $thresholds.fewInlinksMax, in: 1...20)
            Stepper("H1: до \(thresholds.h1Max) символов", value: $thresholds.h1Max, in: 10...300, step: 5)
            Stepper("H2: до \(thresholds.h2Max) символов", value: $thresholds.h2Max, in: 10...300, step: 5)
            Stepper("Alt картинки: до \(thresholds.altMax) символов", value: $thresholds.altMax, in: 10...500, step: 10)
        }
    }
}

struct LinesEditor: View {
    let title: String
    @Binding var lines: [String]
    let placeholder: String
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 54)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, new in
                    lines = new.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            if let bad = lines.first(where: { (try? NSRegularExpression(pattern: $0)) == nil }), title != "Игнорировать параметры (* в конце — по префиксу)" {
                Text("Ошибка в выражении: \(bad)").font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { text = lines.joined(separator: "\n") }
    }
}

/// Пороги уже сделанного обхода: меняются без повторного обхода.
struct ThresholdsSheet: View {
    let session: CrawlSession
    @State private var thresholds = Thresholds()
    @State private var config = CrawlConfig()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ThresholdsSection(thresholds: $thresholds)
                Section("Настройки этого обхода") {
                    LabeledContent("Границы", value: config.scope.title)
                    LabeledContent("Лимит URL", value: "\(config.maxPages)")
                    LabeledContent("Глубина", value: config.maxDepth == 0 ? "без ограничения" : "\(config.maxDepth)")
                    LabeledContent("Потоков / пауза", value: "\(config.concurrency) / \(config.delayMs) мс")
                    LabeledContent("Робот", value: config.userAgentPreset.title)
                    LabeledContent("robots.txt", value: config.respectRobots ? "учитывается" : "игнорируется")
                    LabeledContent("Sitemap", value: config.useSitemap ? (config.sitemapURL.isEmpty ? "авто" : config.sitemapURL) : "не загружается")
                    if !config.excludePatterns.isEmpty { LabeledContent("Исключить", value: config.excludePatterns.joined(separator: ", ")) }
                    if !config.includePatterns.isEmpty { LabeledContent("Только", value: config.includePatterns.joined(separator: ", ")) }
                    Text("Чтобы обойти сайт с другими настройками, начните новый обход (⌘N): настройки этого подставятся.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Применить") {
                    session.updateThresholds(thresholds)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            config = session.data.config
            thresholds = session.data.config.thresholds
        }
    }
}

// MARK: - Экспорт

struct ExportMenu: View {
    let session: CrawlSession
    @AppStorage("csvDelimiter") private var delimiter = CSVDelimiter.semicolon.rawValue

    var body: some View {
        Menu {
            Button("Всё в папку (CSV)…") { Export.exportAll(session) }
            Divider()
            Button("Страницы") { Export.save(CSVWriter.make(session.rows, columns: CSVColumns.pages, delimiter: Export.delimiter), name: "pages.csv") }
            Button("Мета-теги") { Export.save(CSVWriter.make(session.rows, columns: CSVColumns.meta, delimiter: Export.delimiter), name: "meta.csv") }
            Button("Заголовки (сводка)") { Export.save(CSVWriter.make(session.rows, columns: CSVColumns.headings, delimiter: Export.delimiter), name: "headings.csv") }
            Button("Заголовки (все по порядку)") { Export.save(CSVColumns.headingOutline(session.data), name: "headings-outline.csv") }
            Button("Ссылки") {
                Task {
                    let rows = await session.allLinkRows()
                    Export.save(CSVWriter.make(rows, columns: CSVColumns.links, delimiter: Export.delimiter), name: "links.csv")
                }
            }
            Button("Редиректы") { Export.save(CSVWriter.make(session.redirectRows, columns: CSVColumns.redirects, delimiter: Export.delimiter), name: "redirects.csv") }
            Button("Проблемы") { Export.save(Export.issuesCSV(session), name: "issues.csv") }
            Divider()
            Picker("Разделитель", selection: $delimiter) {
                ForEach(CSVDelimiter.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
        } label: {
            Label("Экспорт", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
    }
}

@MainActor
enum Export {
    static var delimiter: CSVDelimiter {
        CSVDelimiter(rawValue: UserDefaults.standard.string(forKey: "csvDelimiter") ?? ";") ?? .semicolon
    }

    static func save(_ data: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = datedName(name)
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
    }

    static func datedName(_ name: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return "\(base)-\(f.string(from: Date())).\(ext)"
    }

    static func issuesCSV(_ session: CrawlSession) -> Data {
        struct Line { var issue: String; var severity: String; var url: String }
        let t = session.data.config.thresholds
        var lines: [Line] = []
        for id in IssueID.allCases {
            for pid in session.analysis.issues[id] ?? [] {
                lines.append(Line(issue: id.title(t), severity: id.severity.title, url: session.displayURL(pid)))
            }
        }
        return CSVWriter.make(lines, columns: [.init("Проблема") { $0.issue }, .init("Важность") { $0.severity }, .init("URL") { $0.url }], delimiter: delimiter)
    }

    static func exportAll(_ session: CrawlSession) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Выгрузить сюда"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let host = CrawlScope.host(of: session.data.url(session.data.startId ?? 0)).map { Punycode.decodeHost($0) } ?? "crawl"
        let folder = dir.appendingPathComponent(datedName("\(host).csv").replacingOccurrences(of: ".csv", with: ""), isDirectory: true)
        let d = delimiter
        Task {
            let links = await session.allLinkRows()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try CSVWriter.make(session.rows, columns: CSVColumns.pages, delimiter: d).write(to: folder.appendingPathComponent("pages.csv"))
                try CSVWriter.make(session.rows, columns: CSVColumns.meta, delimiter: d).write(to: folder.appendingPathComponent("meta.csv"))
                try CSVWriter.make(session.rows, columns: CSVColumns.headings, delimiter: d).write(to: folder.appendingPathComponent("headings.csv"))
                try CSVColumns.headingOutline(session.data).write(to: folder.appendingPathComponent("headings-outline.csv"))
                try CSVWriter.make(links, columns: CSVColumns.links, delimiter: d).write(to: folder.appendingPathComponent("links.csv"))
                try CSVWriter.make(session.redirectRows, columns: CSVColumns.redirects, delimiter: d).write(to: folder.appendingPathComponent("redirects.csv"))
                try issuesCSV(session).write(to: folder.appendingPathComponent("issues.csv"))
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    static func openInBrowser(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
