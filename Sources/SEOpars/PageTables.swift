import AppKit
import SEOparsCore
import SwiftUI

enum PageTableKind: String {
    case pages, meta, headings

    var filters: [PageFilter] {
        switch self {
        case .pages: [.all, .ok, .indexable, .nonIndexable, .redirects, .errors, .html, .deep, .orphans]
        case .meta: [.all, .indexable, .noTitle, .titleLength, .noDescription, .descriptionLength, .noCanonical, .canonicalOther]
        case .headings: [.all, .indexable, .noH1, .multipleH1, .headingIssues]
        }
    }

    var csvColumns: [CSVColumn<PageRow>] {
        switch self {
        case .pages: CSVColumns.pages
        case .meta: CSVColumns.meta
        case .headings: CSVColumns.headings
        }
    }
}

enum PageFilter: String, CaseIterable, Identifiable {
    case all, ok, indexable, nonIndexable, redirects, errors, html, deep, orphans
    case noTitle, titleLength, noDescription, descriptionLength, noCanonical, canonicalOther
    case noH1, multipleH1, headingIssues

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .ok: "Код 200"
        case .indexable: "Индексируемые"
        case .nonIndexable: "Неиндексируемые"
        case .redirects: "Редиректы"
        case .errors: "4xx, 5xx и ошибки"
        case .html: "Только HTML"
        case .deep: "Глубокие"
        case .orphans: "Без входящих"
        case .noTitle: "Нет title"
        case .titleLength: "Длина title вне порога"
        case .noDescription: "Нет description"
        case .descriptionLength: "Длина description вне порога"
        case .noCanonical: "Нет canonical"
        case .canonicalOther: "Canonical на другой URL"
        case .noH1: "Нет H1"
        case .multipleH1: "Несколько H1"
        case .headingIssues: "Проблемы заголовков"
        }
    }

    func matches(_ r: PageRow, _ t: Thresholds) -> Bool {
        let isContent = r.isContent
        switch self {
        case .all: return true
        case .ok: return r.status == 200
        case .indexable: return r.indexable
        case .nonIndexable: return !r.indexable
        case .redirects: return (300..<400).contains(r.status)
        case .errors: return r.status >= 400 || (r.status == 0 && r.statusText != "robots.txt")
        case .html: return r.contentType.contains("html")
        case .deep: return r.depth > t.maxClickDepth
        case .orphans: return isContent && r.uniqueInlinks == 0
        case .noTitle: return isContent && r.title.isEmpty
        case .titleLength: return isContent && !r.title.isEmpty && (r.titleLength < t.titleMin || r.titleLength > t.titleMax)
        case .noDescription: return isContent && r.description.isEmpty
        case .descriptionLength: return isContent && !r.description.isEmpty && (r.descriptionLength < t.descriptionMin || r.descriptionLength > t.descriptionMax)
        case .noCanonical: return isContent && r.canonicalState == "нет"
        case .canonicalOther: return r.canonicalState == "на другой"
        case .noH1: return isContent && r.h1Count == 0
        case .multipleH1: return r.h1Count > 1
        case .headingIssues: return !r.headingIssues.isEmpty
        }
    }
}

/// Таблица страниц: вкладки «Страницы», «Мета-теги», «Заголовки».
struct PagesTableView: View {
    let session: CrawlSession
    let kind: PageTableKind
    @Binding var selection: Int32?
    @State private var search = ""
    @State private var filter: PageFilter = .all
    @State private var sortOrder: [KeyPathComparator<PageRow>] = []
    @SceneStorage("columns.pages") private var pagesColumns: TableColumnCustomization<PageRow>
    @SceneStorage("columns.meta") private var metaColumns: TableColumnCustomization<PageRow>
    @SceneStorage("columns.headings") private var headingsColumns: TableColumnCustomization<PageRow>

    var displayed: [PageRow] {
        let t = session.data.config.thresholds
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var rows = session.rows.filter { r in
            filter.matches(r, t) && (q.isEmpty || r.url.lowercased().contains(q) || r.title.lowercased().contains(q) || r.h1.lowercased().contains(q))
        }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        return rows
    }

    var body: some View {
        let rows = displayed
        VStack(spacing: 0) {
            HStack {
                Picker("Фильтр", selection: $filter) {
                    ForEach(kind.filters) { Text($0.title).tag($0) }
                }
                .frame(width: 300)
                TextField("Поиск по URL, title, H1", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Spacer()
                Text("\(rows.count) из \(session.rows.count)").foregroundStyle(.secondary).monospacedDigit()
                Button {
                    Export.save(CSVWriter.make(rows, columns: kind.csvColumns, delimiter: Export.delimiter), name: "\(kind.rawValue).csv")
                } label: { Label("CSV", systemImage: "square.and.arrow.down") }
                    .help("Выгрузить таблицу с текущим фильтром и сортировкой")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            table(rows)
                .contextMenu(forSelectionType: PageRow.ID.self) { ids in
                    PageContextMenu(session: session, ids: ids)
                } primaryAction: { ids in
                    if let id = ids.first, let p = session.page(id) { Export.openInBrowser(p.url) }
                }
        }
    }

    @ViewBuilder func table(_ rows: [PageRow]) -> some View {
        switch kind {
        case .pages:
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $pagesColumns) {
                Group {
                    TableColumn("URL", value: \PageRow.url) { Text($0.url).help($0.url) }
                        .width(min: 220, ideal: 380).customizationID("url")
                    TableColumn("Код", value: \PageRow.status) { r in StatusText(row: r) }
                        .width(min: 44, ideal: 56).customizationID("status")
                    TableColumn("Индексируемость", value: \PageRow.indexability) { r in
                        Text(r.indexability).foregroundStyle(r.indexable ? Color.primary : Color.orange)
                    }.width(min: 90, ideal: 130).customizationID("indexability")
                    TableColumn("Правило robots.txt", value: \PageRow.robotsRule) { Text($0.robotsRule).help($0.robotsRule) }
                        .width(min: 80, ideal: 180).customizationID("robotsRule")
                    TableColumn("Тип", value: \PageRow.contentType) { Text($0.contentType) }.width(min: 60, ideal: 90).customizationID("type")
                    TableColumn("Ответ, мс", value: \PageRow.responseMs) { Text("\($0.responseMs)").monospacedDigit() }
                        .width(min: 50, ideal: 70).customizationID("time")
                    TableColumn("КБ", value: \PageRow.sizeKB) { Text(String(format: "%.1f", $0.sizeKB)).monospacedDigit() }
                        .width(min: 40, ideal: 56).customizationID("size")
                    TableColumn("Глубина", value: \PageRow.depth) { Text($0.depthText).monospacedDigit() }
                        .width(min: 44, ideal: 56).customizationID("depth")
                }
                Group {
                    TableColumn("Входящие", value: \PageRow.inlinks) { Text("\($0.inlinks)").monospacedDigit() }
                        .width(min: 50, ideal: 64).customizationID("inlinks")
                    TableColumn("Уник. вход.", value: \PageRow.uniqueInlinks) { Text("\($0.uniqueInlinks)").monospacedDigit() }
                        .width(min: 50, ideal: 70).customizationID("uinlinks")
                    TableColumn("Исх. внутр.", value: \PageRow.outInternal) { Text("\($0.outInternal)").monospacedDigit() }
                        .width(min: 50, ideal: 70).customizationID("outint")
                    TableColumn("Исх. внеш.", value: \PageRow.outExternal) { Text("\($0.outExternal)").monospacedDigit() }
                        .width(min: 50, ideal: 70).customizationID("outext")
                    TableColumn("Слов", value: \PageRow.words) { Text("\($0.words)").monospacedDigit() }
                        .width(min: 40, ideal: 56).customizationID("words")
                    TableColumn("Sitemap", value: \PageRow.inSitemap) { Text($0.inSitemap) }.width(min: 40, ideal: 56).customizationID("sitemap")
                    TableColumn("Проблем", value: \PageRow.issuesCount) { Text("\($0.issuesCount)").monospacedDigit() }
                        .width(min: 44, ideal: 60).customizationID("issues")
                }
            }
        case .meta:
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $metaColumns) {
                Group {
                    TableColumn("URL", value: \PageRow.url) { Text($0.url).help($0.url) }
                        .width(min: 200, ideal: 300).customizationID("url")
                    TableColumn("Код", value: \PageRow.status) { r in StatusText(row: r) }
                        .width(min: 44, ideal: 56).customizationID("status")
                    TableColumn("Title", value: \PageRow.title) { Text($0.title).help($0.title) }
                        .width(min: 160, ideal: 300).customizationID("title")
                    TableColumn("Длина", value: \PageRow.titleLength) { r in
                        LengthText(value: r.titleLength, min: session.data.config.thresholds.titleMin, max: session.data.config.thresholds.titleMax, present: !r.title.isEmpty, isContent: r.isContent)
                    }.width(min: 48, ideal: 58).customizationID("titleLen")
                    TableColumn("Description", value: \PageRow.description) { Text($0.description).help($0.description) }
                        .width(min: 160, ideal: 320).customizationID("desc")
                    TableColumn("Длина ", value: \PageRow.descriptionLength) { r in
                        LengthText(value: r.descriptionLength, min: session.data.config.thresholds.descriptionMin, max: session.data.config.thresholds.descriptionMax, present: !r.description.isEmpty, isContent: r.isContent)
                    }.width(min: 48, ideal: 58).customizationID("descLen")
                }
                Group {
                    TableColumn("Canonical", value: \PageRow.canonicalState) { Text($0.canonicalState) }.width(min: 60, ideal: 80).customizationID("canonicalState")
                    TableColumn("Canonical URL", value: \PageRow.canonical) { Text($0.canonical).help($0.canonical) }
                        .width(min: 120, ideal: 220).customizationID("canonical")
                    TableColumn("Meta robots", value: \PageRow.metaRobots) { Text($0.metaRobots) }.width(min: 80, ideal: 120).customizationID("robots")
                    TableColumn("Индексируемость", value: \PageRow.indexability) { r in
                        Text(r.indexability).foregroundStyle(r.indexable ? Color.primary : Color.orange)
                    }.width(min: 90, ideal: 130).customizationID("indexability")
                }
            }
        case .headings:
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $headingsColumns) {
                Group {
                    TableColumn("URL", value: \PageRow.url) { Text($0.url).help($0.url) }
                        .width(min: 200, ideal: 320).customizationID("url")
                    TableColumn("H1", value: \PageRow.h1) { r in
                        Text(r.h1.isEmpty ? (r.h1Count > 0 ? "(пусто)" : "") : r.h1).help(r.h1)
                    }.width(min: 160, ideal: 300).customizationID("h1")
                    TableColumn("Число H1", value: \PageRow.h1Count) { r in
                        Text("\(r.h1Count)").monospacedDigit().foregroundStyle(r.h1Count == 1 ? Color.primary : Color.red)
                    }.width(min: 50, ideal: 64).customizationID("h1count")
                    TableColumn("H2", value: \PageRow.h2Count) { Text("\($0.h2Count)").monospacedDigit() }.width(min: 30, ideal: 40).customizationID("h2")
                    TableColumn("H3", value: \PageRow.h3Count) { Text("\($0.h3Count)").monospacedDigit() }.width(min: 30, ideal: 40).customizationID("h3")
                    TableColumn("H4", value: \PageRow.h4Count) { Text("\($0.h4Count)").monospacedDigit() }.width(min: 30, ideal: 40).customizationID("h4")
                    TableColumn("H5", value: \PageRow.h5Count) { Text("\($0.h5Count)").monospacedDigit() }.width(min: 30, ideal: 40).customizationID("h5")
                    TableColumn("H6", value: \PageRow.h6Count) { Text("\($0.h6Count)").monospacedDigit() }.width(min: 30, ideal: 40).customizationID("h6")
                }
                Group {
                    TableColumn("Проблемы", value: \PageRow.headingIssues) { Text($0.headingIssues).foregroundStyle(.orange) }
                        .width(min: 100, ideal: 160).customizationID("hissues")
                    TableColumn("Title", value: \PageRow.title) { Text($0.title).help($0.title) }
                        .width(min: 120, ideal: 220).customizationID("title")
                }
            }
        }
    }
}

struct StatusText: View {
    let row: PageRow
    var body: some View {
        Text(row.statusText)
            .monospacedDigit()
            .foregroundStyle(color)
            .help(row.statusText)
    }

    var color: Color {
        row.statusText == "robots.txt" ? .secondary : StatusColor.of(row.status, failed: row.status == 0)
    }
}

/// Цвет кода ответа (компонент «Код ответа» в Penpot): 2xx — `color.status.ok`, 3xx — `redirect`,
/// 4xx/5xx и ошибка соединения — `error`. Без ответа (не проверялся) — основной цвет текста.
enum StatusColor {
    static func of(_ status: Int, failed: Bool = false) -> Color {
        switch status {
        case 200..<300: .green
        case 300..<400: .orange
        case 400...: .red
        default: failed ? .red : .primary
        }
    }
}

/// Длина title или description: отклонение видно стрелкой, а не только цветом (HANDOFF §4.4, §10).
struct LengthText: View {
    let value: Int
    let verdict: LengthVerdict

    init(value: Int, min: Int, max: Int, present: Bool, isContent: Bool) {
        self.value = value
        self.verdict = .of(length: value, present: present, min: min, max: max, isContent: isContent)
    }

    var body: some View {
        Text(verdict.cellText(value))
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel(verdict.spokenText(value))
    }

    var color: Color {
        switch verdict {
        case .notApplicable: .secondary
        case .missing: .red
        case .tooShort, .tooLong: .orange
        case .normal: .primary
        }
    }
}

struct PageContextMenu: View {
    let session: CrawlSession
    let ids: Set<Int32>

    var body: some View {
        let urls = ids.compactMap { session.page($0)?.url }
        Button("Открыть в браузере") { urls.prefix(10).forEach(Export.openInBrowser) }
            .disabled(urls.isEmpty)
        Button("Скопировать URL") { Export.copy(urls.map(URLNormalizer.display).joined(separator: "\n")) }
            .disabled(urls.isEmpty)
        Button("Скопировать URL (закодированный)") { Export.copy(urls.joined(separator: "\n")) }
            .disabled(urls.isEmpty)
    }
}
