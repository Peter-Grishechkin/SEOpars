import AppKit
import SEOparsCore
import SwiftUI

// MARK: - Ссылки

enum LinkFilter: String, CaseIterable, Identifiable {
    case internalLinks, all, external, broken, toRedirect, nofollow, nav, footer, content
    var id: String { rawValue }
    var title: String {
        switch self {
        case .internalLinks: "Внутренние"
        case .all: "Все"
        case .external: "Внешние"
        case .broken: "Битые (4xx, 5xx, ошибка)"
        case .toRedirect: "На редирект"
        case .nofollow: "nofollow"
        case .nav: "Зона: меню и шапка"
        case .footer: "Зона: подвал"
        case .content: "Зона: контент"
        }
    }

    func matches(_ l: LinkRow) -> Bool {
        switch self {
        case .all: true
        case .internalLinks: !l.external
        case .external: l.external
        case .broken: !l.external && l.isBroken
        case .toRedirect: !l.external && l.isToRedirect
        case .nofollow: l.rel.contains("nofollow")
        case .nav: l.zone == LinkZone.nav.title || l.zone == LinkZone.header.title
        case .footer: l.zone == LinkZone.footer.title
        case .content: l.zone == LinkZone.content.title
        }
    }
}

struct LinksView: View {
    let session: CrawlSession
    @Binding var selection: Int32?
    @State private var all: [LinkRow] = []
    @State private var builtRevision = -1
    @State private var building = false
    @State private var visible = false
    @State private var filter: LinkFilter = .internalLinks
    @State private var search = ""
    @State private var sortOrder: [KeyPathComparator<LinkRow>] = []
    @State private var selectedLink: LinkRow.ID?
    @SceneStorage("columns.links") private var columns: TableColumnCustomization<LinkRow>

    @State private var shown: [LinkRow] = []
    @State private var matched = 0

    /// В таблице показываем не больше стольких строк: SwiftUI Table держит объект на каждую строку
    /// (~1 КБ), и 400 тысяч ссылок съедают гигабайт. CSV выгружается полностью.
    nonisolated static let displayLimit = 5000

    nonisolated static func filtered(_ all: [LinkRow], filter: LinkFilter, search: String, sort: [KeyPathComparator<LinkRow>]) -> [LinkRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var rows = all.filter { l in
            filter.matches(l) && (q.isEmpty || l.anchor.lowercased().contains(q) || l.source.lowercased().contains(q) || l.target.lowercased().contains(q))
        }
        if !sort.isEmpty { rows.sort(using: sort) }
        return rows
    }

    func refilter() async {
        let (all, filter, search, sort) = (self.all, self.filter, self.search, self.sortOrder)
        let (rows, count) = await Task.detached(priority: .userInitiated) {
            let r = Self.filtered(all, filter: filter, search: search, sort: sort)
            return (Array(r.prefix(Self.displayLimit)), r.count)
        }.value
        shown = rows
        matched = count
    }

    var body: some View {
        let rows = shown
        VStack(spacing: 0) {
            HStack {
                Picker("Фильтр", selection: $filter) {
                    ForEach(LinkFilter.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 300)
                TextField("Поиск по анкору, источнику, цели", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                if building { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(matched) из \(all.count)").foregroundStyle(.secondary).monospacedDigit()
                Button {
                    let full = Self.filtered(all, filter: filter, search: search, sort: sortOrder)
                    Export.save(CSVWriter.make(full, columns: CSVColumns.links, delimiter: Export.delimiter), name: "links.csv")
                } label: { Label("CSV", systemImage: "square.and.arrow.down") }
                    .help("Выгрузить все ссылки под текущий фильтр, без ограничения в \(Self.displayLimit) строк")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Text("Зона определяется своими правилами из настроек обхода, затем эвристикой по разметке (nav, header, footer, main и классы). Эвристика на сайтах без семантической вёрстки может ошибаться.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, matched > rows.count ? 2 : 6)
            if matched > rows.count {
                Text("В таблице первые \(rows.count) из \(matched). Уточните фильтр или поиск, все строки — в CSV.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            Table(rows, selection: $selectedLink, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("Источник", value: \LinkRow.source) { Text($0.source).help($0.source) }
                    .width(min: 160, ideal: 280).customizationID("source")
                TableColumn("Цель", value: \LinkRow.target) { Text($0.target).help($0.target) }
                    .width(min: 160, ideal: 280).customizationID("target")
                TableColumn("Анкор", value: \LinkRow.anchor) { Text($0.anchor).help($0.anchor) }
                    .width(min: 100, ideal: 200).customizationID("anchor")
                TableColumn("Код цели", value: \LinkRow.targetStatus) { l in
                    Text(l.targetStatusText).monospacedDigit()
                        .foregroundStyle(StatusColor.of(l.targetStatus, failed: l.isBroken))
                }.width(min: 50, ideal: 64).customizationID("status")
                TableColumn("Тип", value: \LinkRow.kind) { Text($0.kind) }.width(min: 60, ideal: 90).customizationID("kind")
                TableColumn("rel", value: \LinkRow.rel) { Text($0.rel) }.width(min: 50, ideal: 80).customizationID("rel")
                TableColumn("Зона", value: \LinkRow.zone) { Text($0.zone) }.width(min: 60, ideal: 90).customizationID("zone")
                TableColumn("Где", value: \LinkRow.place) { Text($0.place) }.width(min: 60, ideal: 80).customizationID("place")
            }
            .contextMenu(forSelectionType: LinkRow.ID.self) { ids in
                let links = all.filter { ids.contains($0.id) }
                Button("Перейти к источнику") { if let l = links.first { selection = l.sourceId } }
                Button("Перейти к цели") { if let l = links.first, session.page(l.targetId) != nil { selection = l.targetId } }
                Divider()
                Button("Открыть источник в браузере") { links.prefix(5).forEach { Export.openInBrowser(session.url($0.sourceId)) } }
                Button("Открыть цель в браузере") { links.prefix(5).forEach { Export.openInBrowser(session.url($0.targetId)) } }
                Button("Скопировать строку") {
                    Export.copy(links.map { "\($0.source)\t\($0.target)\t\($0.anchor)" }.joined(separator: "\n"))
                }
            } primaryAction: { ids in
                if let l = all.first(where: { ids.contains($0.id) }) { selection = l.sourceId }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: session.revision) { await rebuild() }
        .task(id: FilterKey(filter: filter, search: search, sort: sortOrder.map { "\($0.keyPath)\($0.order == .forward)" })) {
            await refilter()
        }
    }

    struct FilterKey: Equatable {
        var filter: LinkFilter
        var search: String
        var sort: [String]
    }

    /// Одна пересборка за раз; во время обхода — не чаще раза в 2 с: ссылок в сотни раз больше, чем страниц.
    func rebuild() async {
        guard !building else { return }
        building = true
        defer { building = false }
        while visible || builtRevision < 0, builtRevision != session.revision {
            if session.isRunning, builtRevision >= 0 {
                // Отдельная задача: .task отменяется при каждом новом revision, а пауза должна выдержаться.
                await Task { try? await Task.sleep(for: .seconds(2)) }.value
            }
            let rev = session.revision
            all = await session.allLinkRows()
            builtRevision = rev
            await refilter()
        }
    }
}

// MARK: - Редиректы

struct RedirectsView: View {
    let session: CrawlSession
    @Binding var selection: Int32?
    @State private var sortOrder: [KeyPathComparator<RedirectRow>] = []

    var body: some View {
        var rows = session.redirectRows
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        return VStack(spacing: 0) {
            HStack {
                Text("Внутренние адреса с ответом 3xx и куда они в итоге ведут.").foregroundStyle(.secondary)
                Spacer()
                Button {
                    Export.save(CSVWriter.make(rows, columns: CSVColumns.redirects, delimiter: Export.delimiter), name: "redirects.csv")
                } label: { Label("CSV", systemImage: "square.and.arrow.down") }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("URL", value: \RedirectRow.url) { Text($0.url).help($0.url) }.width(min: 180, ideal: 300)
                TableColumn("Код", value: \RedirectRow.status) { Text("\($0.status)").monospacedDigit().foregroundStyle(.orange) }.width(min: 40, ideal: 50)
                TableColumn("Куда", value: \RedirectRow.target) { Text($0.target).help($0.target) }.width(min: 160, ideal: 260)
                TableColumn("Конечный URL", value: \RedirectRow.finalURL) { Text($0.finalURL).help($0.finalURL) }.width(min: 160, ideal: 260)
                TableColumn("Код конечного", value: \RedirectRow.finalStatus) { r in
                    Text(r.finalStatus == 0 ? "—" : "\(r.finalStatus)").monospacedDigit()
                        .foregroundStyle(r.finalStatus == 200 ? Color.green : Color.red)
                }.width(min: 50, ideal: 70)
                TableColumn("Шагов", value: \RedirectRow.hops) { r in
                    Text("\(r.hops)").monospacedDigit().foregroundStyle(r.hops > 1 ? Color.orange : Color.primary)
                }.width(min: 40, ideal: 50)
                TableColumn("Петля", value: \RedirectRow.loop) { Text($0.loop).foregroundStyle(.red) }.width(min: 40, ideal: 50)
                TableColumn("Входящие", value: \RedirectRow.inlinks) { Text("\($0.inlinks)").monospacedDigit() }.width(min: 50, ideal: 64)
            }
        }
    }
}

// MARK: - Проблемы

struct IssuesView: View {
    let session: CrawlSession
    @Binding var selection: Int32?
    @State private var selectedIssue: IssueID?

    var body: some View {
        let t = session.data.config.thresholds
        let issues = session.analysis.issues
        HSplitView {
            List(selection: $selectedIssue) {
                ForEach(IssueGroup.allCases, id: \.self) { group in
                    let items = IssueID.allCases.filter { $0.group == group && !(issues[$0]?.isEmpty ?? true) }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items, id: \.self) { id in
                                HStack(spacing: 8) {
                                    SeverityIcon(severity: id.severity)
                                    Text(id.title(t)).lineLimit(2)
                                    Spacer()
                                    if id.needsFullCrawl, !session.analysisIsFinal {
                                        Image(systemName: "hourglass").foregroundStyle(.secondary).help("Обход не завершён — число промежуточное")
                                    }
                                    Text("\(issues[id]?.count ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .tag(id)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 380)
            .overlay {
                if issues.isEmpty {
                    Text(session.rows.isEmpty ? "Пока нет данных" : "Проблем не найдено").foregroundStyle(.secondary)
                }
            }

            IssueDetail(session: session, issue: selectedIssue, selection: $selection)
                .frame(minWidth: 400)
        }
    }
}

struct IssueDetail: View {
    let session: CrawlSession
    let issue: IssueID?
    @Binding var selection: Int32?
    @State private var sortOrder: [KeyPathComparator<PageRow>] = []

    var body: some View {
        if let issue {
            let rows = rows(for: issue)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SeverityIcon(severity: issue.severity)
                    Text(issue.title(session.data.config.thresholds)).font(.headline)
                    Spacer()
                    Button {
                        let details = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, detailValue(issue, $0)) })
                        let cols: [CSVColumn<PageRow>] = [
                            .init("URL") { $0.url },
                            .init("Код") { $0.statusText },
                            .init(detailTitle(issue)) { details[$0.id] ?? "" },
                            .init("Уникальные входящие") { String($0.uniqueInlinks) },
                            .init("Глубина") { $0.depthText },
                        ]
                        Export.save(CSVWriter.make(rows, columns: cols, delimiter: Export.delimiter), name: "issue-\(issue.rawValue).csv")
                    } label: { Label("CSV", systemImage: "square.and.arrow.down") }
                }
                Text(IssueHelp.text(issue)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("URL", value: \PageRow.url) { Text($0.url).help($0.url) }.width(min: 200, ideal: 340)
                    TableColumn("Код", value: \PageRow.status) { r in StatusText(row: r) }.width(min: 40, ideal: 50)
                    TableColumn(detailTitle(issue)) { r in Text(detailValue(issue, r)).help(detailValue(issue, r)) }.width(min: 160, ideal: 320)
                    TableColumn("Уник. вход.", value: \PageRow.uniqueInlinks) { Text("\($0.uniqueInlinks)").monospacedDigit() }.width(min: 50, ideal: 70)
                    TableColumn("Глубина", value: \PageRow.depth) { Text($0.depthText).monospacedDigit() }.width(min: 40, ideal: 56)
                }
                .contextMenu(forSelectionType: PageRow.ID.self) { ids in
                    PageContextMenu(session: session, ids: ids)
                } primaryAction: { ids in
                    if let id = ids.first, let p = session.page(id) { Export.openInBrowser(p.url) }
                }
            }
            .padding(12)
        } else {
            Text("Выберите проблему слева").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func detailTitle(_ i: IssueID) -> String {
        switch i.group {
        case .title: "Title"
        case .description: "Description"
        case .h1, .headings: [.h2Missing, .h2TooLong, .h2Duplicate].contains(i) ? "H2" : "H1"
        case .responses: "Ответ"
        case .indexing: "Индексируемость"
        case .hreflang: "hreflang"
        case .links: "Ссылки"
        case .content: "Title"
        }
    }

    func detailValue(_ i: IssueID, _ r: PageRow) -> String {
        switch i.group {
        case .title: return r.title.isEmpty ? "—" : "\(r.title) (\(r.titleLength))"
        case .description: return r.description.isEmpty ? "—" : "\(r.description) (\(r.descriptionLength))"
        case .h1, .headings:
            switch i {
            case .h1TooLong: return "\(r.h1) (\(r.h1.count))"
            case .h2TooLong, .h2Duplicate: return "\(r.h2) (\(r.h2.count))"
            case .h2Missing: return "H2: \(r.h2Count)"
            default: return r.headingIssues.isEmpty ? r.h1 : "\(r.h1) · \(r.headingIssues)"
            }
        case .responses: return r.redirectTarget.isEmpty ? "\(r.statusText), \(r.responseMs) мс" : "→ \(r.redirectTarget)"
        case .indexing:
            switch i {
            case .canonicalMultipleSame, .canonicalMultipleDifferent:
                let targets = session.analysis.metrics[r.id]?.canonicalTargets ?? []
                return targets.map { session.displayURL($0) }.joined(separator: " | ")
            case .canonicalRelative: return (session.page(r.id)?.html?.canonicals ?? []).joined(separator: " | ")
            default: return r.canonical.isEmpty ? r.indexability : "\(r.indexability) → \(r.canonical)"
            }
        case .hreflang:
            return (session.page(r.id)?.html?.hreflang ?? []).map(\.lang).joined(separator: ", ")
        case .links:
            let m = session.analysis.metrics[r.id]
            switch i {
            case .brokenInternalLinks: return "битых: \(m?.brokenOutlinks ?? 0)"
            case .linksToRedirects: return "на редирект: \(m?.redirectOutlinks ?? 0)"
            case .internalNofollow: return "nofollow: \(m?.nofollowOutlinks ?? 0)"
            // У тупика все внутренние исходящие — ссылки на себя.
            case .noInternalOutlinks: return "на себя: \(m?.outInternal ?? 0), внешних: \(m?.outExternal ?? 0)"
            default: return "входящих: \(r.inlinks), уникальных: \(r.uniqueInlinks)"
            }
        case .content:
            switch i {
            case .lowWordCount: return "слов: \(r.words)"
            case .imagesWithoutAlt: return "без alt: \(r.imagesWithoutAlt)"
            case .imagesEmptyAlt: return "пустой alt: \(r.imagesEmptyAlt)"
            case .imagesLongAlt: return "длинный alt: \(r.imagesLongAlt)"
            default: return r.title
            }
        }
    }

    func rows(for issue: IssueID) -> [PageRow] {
        let ids = Set(session.analysis.issues[issue] ?? [])
        var rows = session.rows.filter { ids.contains($0.id) }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        return rows
    }
}

struct SeverityIcon: View {
    let severity: IssueSeverity
    var body: some View {
        switch severity {
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notice: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        }
    }
}

enum IssueHelp {
    static func text(_ i: IssueID) -> String {
        switch i {
        case .titleTooShort, .titleTooLong, .descriptionTooShort, .descriptionTooLong, .h1TooLong, .h2TooLong, .imagesLongAlt:
            "Пороги длины — рабочие ориентиры, а не нормы Яндекса или Google. Меняются в «Порогах»."
        case .titleDuplicate, .descriptionDuplicate, .h1Duplicate, .h2Duplicate, .duplicateContent:
            "Сравниваются только индексируемые страницы с кодом 200. Во время обхода число растёт."
        case .brokenInternalLinks:
            "Страницы, на которых есть ссылки на адреса с кодом 4xx/5xx или ошибкой. Сами ссылки — во вкладке «Исходящие» инспектора или в «Ссылках» с фильтром «Битые»."
        case .linksToRedirects:
            "Ссылку лучше заменить на конечный адрес редиректа. Список — «Ссылки» → «На редирект»."
        case .orphanPages:
            "Адрес есть в sitemap, но ни одна обойдённая страница на него не ссылается."
        case .deepPages:
            "Глубина — кратчайший путь в кликах от стартовой страницы по ссылкам и редиректам."
        case .nofollowInlinksOnly:
            "Индексируемая страница, на которую все внутренние ссылки с других страниц стоят с rel=\"nofollow\". Считаются ссылки с обойдённых страниц, только в режиме «паук». Источники — вкладка «Входящие» инспектора."
        case .nonIndexableInlinksOnly:
            "Индексируемая страница, на которую ссылаются только неиндексируемые страницы: с noindex или с canonical на другой адрес. Считаются ссылки с обойдённых страниц, только в режиме «паук». Источники — вкладка «Входящие» инспектора."
        case .noInternalOutlinks:
            "На странице нет ссылок на другие внутренние страницы. Ссылка на саму себя и внешние ссылки не в счёт. Ссылки, которые строит JavaScript, без отрисовки не видны."
        case .urlVariantDuplicate:
            "Адреса отличаются только слэшем на конце или регистром и оба отдают 200. Нужен редирект или canonical."
        case .headingSkippedLevel:
            "Уровень заголовка вырос больше чем на один шаг (H2 → H4). Скрытые стилями заголовки без отрисовки CSS не определяются."
        case .noindex:
            "Учитываются meta robots, meta для выбранного робота и X-Robots-Tag."
        case .lowWordCount:
            "Считается видимый текст без script, style, noscript и svg, включая меню и подвал."
        case .blockedByRobots:
            "Адрес закрыт правилами robots.txt для выбранного робота и не загружался. Какое правило сработало — колонка «Правило robots.txt» в «Страницах»."
        case .imagesEmptyAlt:
            "Пустой alt допустим для декоративных картинок: программы чтения с экрана их пропускают. Проверьте, что среди них нет содержательных."
        case .canonicalMissing:
            "Canonical нет ни в HTML, ни в заголовке Link."
        case .canonicalMultipleSame, .canonicalMultipleDifferent:
            "Учитываются canonical из HTML и заголовка Link. Адреса сравниваются после нормализации: относительный и полный адрес одной страницы — одинаковые."
        case .canonicalRelative:
            "Google поддерживает относительный адрес в canonical, но советует указывать полный."
        case .hreflangNoReturn, .hreflangTargetNon200, .hreflangNoSelf:
            "Проверяются цели hreflang, загруженные в этом обходе. Обходы до 2026-11-11 связей hreflang не хранят — нужен повторный обход."
        case .hreflangInvalidCode:
            "Язык — ISO 639-1, регион — ISO 3166-1 alpha-2 через дефис: en-GB, а не en-UK; ru, а не ru-RUS."
        default:
            ""
        }
    }
}

// MARK: - Обзор

struct OverviewView: View {
    let session: CrawlSession
    @Binding var tab: CrawlTab

    var body: some View {
        let s = session.stats
        let a = session.analysis
        let indexable = a.metrics.values.filter { $0.indexability.isIndexable }.count
        let content = session.data.pages.filter(\.isContentPage).count
        let internalLinks = session.data.links.filter { !$0.external && ($0.kind == .anchor || $0.kind == .image) }.count
        let avgTime = session.data.pages.isEmpty ? 0 : session.data.pages.map(\.responseTimeMs).reduce(0, +) / session.data.pages.count
        let t = session.data.config.thresholds
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    Tile(title: "Обойдено URL", value: "\(s.crawled)")
                    Tile(title: "HTML-страниц с кодом 200", value: "\(content)")
                    Tile(title: "Индексируются", value: "\(indexable)")
                    Tile(title: "Редиректы 3xx", value: "\(s.status3xx)", color: .orange)
                    Tile(title: "Ошибки 4xx", value: "\(s.status4xx)", color: .red)
                    Tile(title: "Ошибки 5xx", value: "\(s.status5xx)", color: .red)
                    Tile(title: "Нет соединения", value: "\(s.errors)", color: .red)
                    Tile(title: "Закрыто robots.txt", value: "\(s.blocked)")
                    Tile(title: "Внутренних ссылок", value: "\(internalLinks)")
                    Tile(title: "URL в sitemap", value: "\(session.data.sitemapIds.count)")
                    Tile(title: "Среднее время ответа", value: "\(avgTime) мс")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Главные проблемы").font(.headline)
                        Spacer()
                        Button("Все проблемы") { tab = .issues }
                    }
                    let top = IssueID.allCases
                        .compactMap { id -> (IssueID, Int)? in
                            let n = a.issues[id]?.count ?? 0
                            return n > 0 ? (id, n) : nil
                        }
                        .sorted { ($0.0.severity, -$0.1) < ($1.0.severity, -$1.1) }
                        .prefix(12)
                    if top.isEmpty {
                        Text(session.rows.isEmpty ? "Данных пока нет" : "Проблем не найдено").foregroundStyle(.secondary)
                    }
                    ForEach(Array(top), id: \.0) { id, n in
                        // «Строка проблемы» из Penpot: промежуток 8, отступ сверху и снизу 4.
                        HStack(spacing: 8) {
                            SeverityIcon(severity: id.severity)
                            Text(id.title(t))
                            Spacer()
                            Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !session.messages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Журнал").font(.headline)
                        ForEach(Array(session.messages.enumerated()), id: \.offset) { _, m in
                            Text("· " + m).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }

                if let robots = session.data.robotsText {
                    DisclosureGroup("robots.txt") {
                        Text(robots.isEmpty ? "(пусто или не найден)" : robots)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
    }
}

struct Tile: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.bold()).monospacedDigit().foregroundStyle(value == "0" ? .secondary : color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
