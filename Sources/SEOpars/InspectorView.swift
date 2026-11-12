import AppKit
import SEOparsCore
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case summary, headings, inlinks, outlinks, http, source
    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: "Сводка"
        case .headings: "Заголовки"
        case .inlinks: "Входящие"
        case .outlinks: "Исходящие"
        case .http: "HTTP"
        case .source: "Код"
        }
    }
}

struct InspectorView: View {
    let session: CrawlSession
    @Binding var pageId: Int32?
    @SceneStorage("inspectorTab") private var tab: InspectorTab = .summary

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let id = pageId, let page = session.page(id) {
                HStack {
                    Picker("", selection: $tab) {
                        ForEach(InspectorTab.allCases) { t in Text(title(t, id)).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(session.displayURL(id))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button { Export.openInBrowser(page.url) } label: { Image(systemName: "safari") }
                        .help("Открыть в браузере")
                    Button { Export.copy(session.displayURL(id)) } label: { Image(systemName: "doc.on.doc") }
                        .help("Скопировать URL")
                }
                .padding(8)
                Group {
                    switch tab {
                    case .summary: SummaryPane(session: session, page: page)
                    case .headings: HeadingsPane(page: page)
                    case .inlinks: LinksPane(session: session, indices: session.analysis.inlinks[id] ?? [], incoming: true, pageId: $pageId)
                    case .outlinks: LinksPane(session: session, indices: session.analysis.outlinks[id] ?? [], incoming: false, pageId: $pageId)
                    case .http: HTTPPane(page: page)
                    case .source: SourcePane(session: session, pageId: id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Выберите страницу в таблице")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func title(_ t: InspectorTab, _ id: Int32) -> String {
        switch t {
        case .inlinks: "\(t.title) · \(session.analysis.inlinks[id]?.count ?? 0)"
        case .outlinks: "\(t.title) · \(session.analysis.outlinks[id]?.count ?? 0)"
        case .headings: "\(t.title) · \(session.page(id)?.html?.headings.count ?? 0)"
        default: t.title
        }
    }
}

struct SummaryPane: View {
    let session: CrawlSession
    let page: PageRecord

    var body: some View {
        let m = session.analysis.metrics[page.id]
        let t = session.data.config.thresholds
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(lines(m, t).enumerated()), id: \.offset) { _, line in
                    if line.0.isEmpty {
                        Divider().gridCellColumns(2)
                    } else {
                        GridRow(alignment: .top) {
                            Text(line.0).foregroundStyle(.secondary)
                            Text(line.1.isEmpty ? "—" : line.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let issues = m?.issues, !issues.isEmpty {
                    Divider().gridCellColumns(2)
                    GridRow(alignment: .top) {
                        Text("Проблемы").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(issues, id: \.self) { i in
                                HStack(spacing: 6) {
                                    SeverityIcon(severity: i.severity)
                                    Text(i.title(t))
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Пары «название — значение»; пустое название — разделитель.
    func lines(_ m: PageMetrics?, _ t: Thresholds) -> [(String, String)] {
        var r: [(String, String)] = []
        r.append(("URL", session.displayURL(page.id)))
        r.append(("Код ответа", page.state == .blockedByRobots ? "не загружалась (robots.txt)" : (page.error ?? "\(page.statusCode)")))
        let robotsRule = session.data.robotsRule(for: page)
        if !robotsRule.isEmpty { r.append(("Правило robots.txt", robotsRule)) }
        if let red = page.redirectURL { r.append(("Редирект на", URLNormalizer.display(red))) }
        r.append(("Индексируемость", m?.indexability.title ?? "—"))
        var type = [page.contentType, page.charset].filter { !$0.isEmpty }.joined(separator: " · ")
        if page.sniffedHTML == true {
            type += page.headers["content-type"] == nil ? "\nзаголовка Content-Type нет, внутри HTML" : "\nвнутри HTML, а Content-Type не text/html"
        }
        r.append(("Тип / кодировка", type))
        r.append(("Время ответа", "\(page.responseTimeMs) мс"))
        r.append(("Размер", String(format: "%.1f КБ", Double(page.sizeBytes) / 1024) + (page.truncated ? " (обрезано)" : "")))
        r.append(("Глубина", m?.depth.map(String.init) ?? "— (не найдена по ссылкам от стартовой)"))
        r.append(("Входящие ссылки", "\(m?.inlinks ?? 0), с уникальных страниц: \(m?.uniqueInlinks ?? 0)"))
        r.append(("Исходящие", "внутренних \(m?.outInternal ?? 0), внешних \(m?.outExternal ?? 0)"))
        let sitemapFiles = (session.data.sitemapFiles[page.id] ?? []).map(URLNormalizer.display)
        switch sitemapFiles.count {
        case 0: r.append(("В sitemap", session.data.sitemapIds.contains(page.id) ? "да" : "нет"))
        case 1: r.append(("В sitemap", "да: \(sitemapFiles[0])"))
        default: r.append(("В sitemap", "да, в \(sitemapFiles.count) файлах:\n" + sitemapFiles.joined(separator: "\n")))
        }
        guard let h = page.html else { return r }
        r.append(("", ""))
        r.append(("Title", lengthLabel(h.title, min: t.titleMin, max: t.titleMax) + (h.titles.count > 1 ? " · title на странице: \(h.titles.count)" : "")))
        r.append(("Description", lengthLabel(h.description, min: t.descriptionMin, max: t.descriptionMax)))
        r.append(("H1", h.h1s.isEmpty ? "нет" : h.h1s.map { $0.isEmpty ? "(пусто)" : $0 }.joined(separator: " | ")))
        r.append(("Canonical", m?.canonicalTarget.map { session.displayURL($0) + ($0 == page.id ? " (на себя)" : " (на другой URL)") } ?? "нет"))
        if h.canonicals.count > 1 || h.canonicals.contains(where: { CrawlAnalyzer.isRelativeURL($0) }) {
            r.append(("Canonical в коде", h.canonicals.joined(separator: "\n")))
        }
        var robots: [String] = []
        if !h.metaRobots.isEmpty { robots.append(h.metaRobots.joined(separator: "; ")) }
        if !h.metaYandex.isEmpty { robots.append("yandex: " + h.metaYandex.joined(separator: "; ")) }
        if !h.metaGooglebot.isEmpty { robots.append("googlebot: " + h.metaGooglebot.joined(separator: "; ")) }
        r.append(("Meta robots", robots.joined(separator: " · ")))
        if !page.xRobotsTag.isEmpty { r.append(("X-Robots-Tag", page.xRobotsTag)) }
        if let k = h.keywords, !k.isEmpty { r.append(("Meta keywords", k)) }
        if !h.hreflang.isEmpty { r.append(("hreflang", h.hreflang.map { "\($0.lang): \($0.href)" }.joined(separator: "\n"))) }
        r.append(("lang / viewport", [h.lang ?? "—", h.viewport ?? "нет viewport"].joined(separator: " · ")))
        let og = [h.ogTitle.map { "title: \($0)" }, h.ogDescription.map { "description: \($0)" }, h.ogImage.map { "image: \($0)" }].compactMap { $0 }
        if !og.isEmpty { r.append(("Open Graph", og.joined(separator: "\n"))) }
        if let tw = h.twitterCard { r.append(("Twitter Card", tw)) }
        if let refresh = h.metaRefresh, let summary = h.metaRefreshSummary { r.append(("Meta refresh", "\(summary)\nв коде: \(refresh)")) }
        if let markup = h.headMarkupSummary { r.append(("Разметка head", markup)) }
        r.append(("Слов", "\(h.wordCount)"))
        r.append(("Картинки", "\(h.imagesCount), без alt: \(h.imagesWithoutAlt), пустой alt: \(h.imagesEmptyAlt), alt длиннее \(t.altMax): \(h.longAltCount(max: t.altMax))"))
        if !h.imagesWithoutAltSamples.isEmpty { r.append(("Без alt", h.imagesWithoutAltSamples.prefix(5).joined(separator: "\n"))) }
        if !h.imagesEmptyAltSamples.isEmpty { r.append(("Пустой alt", h.imagesEmptyAltSamples.prefix(5).joined(separator: "\n"))) }
        let longAlts = h.longestAlts.filter { $0.length > t.altMax }
        if !longAlts.isEmpty { r.append(("Длинный alt", longAlts.map { "\($0.src) — \($0.length) симв." }.joined(separator: "\n"))) }
        return r
    }

    func lengthLabel(_ s: String?, min: Int, max: Int) -> String {
        guard let s, !s.isEmpty else { return "нет" }
        let mark = s.count < min ? " — короче \(min)" : (s.count > max ? " — длиннее \(max)" : "")
        return "\(s)  [\(s.count) симв.\(mark)]"
    }
}

struct HeadingsPane: View {
    let page: PageRecord

    var body: some View {
        let headings = page.html?.headings ?? []
        if headings.isEmpty {
            Text(page.html == nil ? "Страница не HTML или не загружена" : "Заголовков нет")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // «Дерево заголовков» из Penpot: столбец с промежутком 6 и отступом 12.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(headings.enumerated()), id: \.offset) { i, h in
                        let prev = i > 0 ? headings[i - 1].level : 0
                        HStack(spacing: 8) {
                            Text("H\(h.level)")
                                .font(.caption.monospaced().bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(color(h.level).opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(color(h.level))
                            Text(h.text.isEmpty ? "(пустой заголовок)" : h.text)
                                .foregroundStyle(h.text.isEmpty ? Color.red : Color.primary)
                                .textSelection(.enabled)
                            if prev > 0, h.level > prev + 1 {
                                Text("пропуск уровня: H\(prev) → H\(h.level)").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.leading, CGFloat(max(0, h.level - 1)) * 18)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func color(_ level: Int) -> Color {
        switch level {
        case 1: .red
        case 2: .orange
        case 3: .green
        case 4: .blue
        default: .purple
        }
    }
}

struct LinksPane: View {
    let session: CrawlSession
    let indices: [Int]
    let incoming: Bool
    @Binding var pageId: Int32?
    @State private var sortOrder: [KeyPathComparator<LinkRow>] = []
    @State private var selected: LinkRow.ID?

    var sortedRows: [LinkRow] {
        var rows = session.linkRows(indices)
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        return rows
    }

    var body: some View {
        let rows = sortedRows
        VStack(spacing: 0) {
            if incoming, !rows.isEmpty { anchorSummary(rows) }
            table(rows)
        }
    }

    /// Распределение анкоров: какими словами ссылаются на страницу.
    func anchorSummary(_ rows: [LinkRow]) -> some View {
        var counts: [String: Int] = [:]
        // Только настоящие ссылки: у canonical и редиректа анкора нет, у hreflang в анкоре код языка.
        for l in rows where l.kind == LinkKind.anchor.title || l.kind == LinkKind.image.title {
            counts[l.anchor.isEmpty ? "(пустой анкор)" : l.anchor, default: 0] += 1
        }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Анкоры (\(counts.count)):").foregroundStyle(.secondary)
                ForEach(top.prefix(30), id: \.key) { item in
                    Text("\(item.key) × \(item.value)")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .help("\(item.key): \(item.value)")
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    func table(_ rows: [LinkRow]) -> some View {
        Table(rows, selection: $selected, sortOrder: $sortOrder) {
            TableColumn(incoming ? "Откуда" : "Куда", value: incoming ? \LinkRow.source : \LinkRow.target) { l in
                Text(incoming ? l.source : l.target).help(incoming ? l.source : l.target)
            }.width(min: 200, ideal: 360)
            TableColumn("Анкор", value: \LinkRow.anchor) { Text($0.anchor).help($0.anchor) }.width(min: 100, ideal: 200)
            TableColumn("Тип", value: \LinkRow.kind) { Text($0.kind) }.width(min: 60, ideal: 90)
            TableColumn("rel", value: \LinkRow.rel) { Text($0.rel) }.width(min: 40, ideal: 70)
            TableColumn("Зона", value: \LinkRow.zone) { Text($0.zone) }.width(min: 60, ideal: 90)
            TableColumn("Код цели", value: \LinkRow.targetStatus) { l in
                Text(l.targetStatusText).monospacedDigit()
                    .foregroundStyle(StatusColor.of(l.targetStatus, failed: l.isBroken))
            }.width(min: 50, ideal: 64)
            TableColumn("Где", value: \LinkRow.place) { Text($0.place) }.width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: LinkRow.ID.self) { ids in
            if let l = rows.first(where: { ids.contains($0.id) }) {
                let other = incoming ? l.sourceId : l.targetId
                Button(incoming ? "Перейти к источнику" : "Перейти к цели") { if session.page(other) != nil { pageId = other } }
                Button("Открыть в браузере") { Export.openInBrowser(session.url(other)) }
                Button("Скопировать URL") { Export.copy(incoming ? l.source : l.target) }
            }
        } primaryAction: { ids in
            if let l = rows.first(where: { ids.contains($0.id) }) {
                let other = incoming ? l.sourceId : l.targetId
                if session.page(other) != nil { pageId = other }
            }
        }
    }
}

struct HTTPPane: View {
    let page: PageRecord
    var body: some View {
        let headers = page.headers.sorted { $0.key < $1.key }
        if headers.isEmpty {
            Text("Заголовков ответа нет").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(headers, id: \.key) { item in
                        GridRow(alignment: .top) {
                            Text(item.key).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                            Text(item.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SourcePane: View {
    let session: CrawlSession
    let pageId: Int32
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                SourceTextView(text: text)
            } else {
                ProgressView()
            }
        }
        .task(id: pageId) {
            text = nil
            text = session.html(for: pageId) ?? "Исходный код сохраняется только для HTML-страниц с кодом 2xx."
        }
    }
}

/// NSTextView: SwiftUI Text тормозит на больших HTML.
struct SourceTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .textColor
    }
}
