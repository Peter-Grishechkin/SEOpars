#!/usr/bin/env python3
"""Тестовый сайт для SEOpars: редиректы, 404/500, robots.txt, sitemap из двух файлов, кириллица,
windows-1251, utm, дубли по слэшу и регистру, сирота, глубокие страницы, петля, meta refresh,
HTML с неверным Content-Type, ошибки разметки head и body.
Запуск: python3 -I fixture_server.py [порт]"""
import sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import quote, unquote, urlsplit

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18990
BASE = f"http://127.0.0.1:{PORT}"

def page(title, h1, body, desc="Описание страницы тестового сайта SEOpars для проверки парсера, достаточно длинное.", extra_head="", h2=None, bare=False):
    # H2 в конце контента, свой у каждой страницы (№ 106): иначе «нет H2» и «дубль H2» были бы везде.
    # h2=False — страница без H2. bare=True — без шапки, меню и подвала, то есть без их ссылок (№ 102, тупик).
    h2_html = "" if h2 is False else f"<h2>{h2 if h2 is not None else 'Подробнее: ' + h1}</h2>"
    header = "" if bare else """<header><a href="/">Главная</a></header>
<nav><a href="/about/">О нас</a> <a href="/каталог/">Каталог</a></nav>"""
    footer = "" if bare else """<footer><a href="/about/">О компании</a> <a href="https://external.example.org/">Партнёр</a></footer>"""
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>{title}</title><meta name="description" content="{desc}">{extra_head}</head>
<body>{header}
<main><h1>{h1}</h1>{body}{h2_html}</main>
{footer}</body></html>"""

LOREM = "<p>" + " ".join(["слово"] * 120) + "</p>"

ROUTES = {
    "/": (200, page("Главная тестового сайта SEOpars — проверка парсера", "Главная",
        LOREM + """
        <a href="/catalog/phones?utm_source=test&utm_medium=cpc">Телефоны</a>
        <a href="/old-page">Старая страница</a>
        <a href="/missing">Битая ссылка</a>
        <a href="/error">Ошибка сервера</a>
        <a href="/win1251">Страница в 1251</a>
        <a href="/about">О нас без слэша</a>
        <a href="/blocked/secret">Закрытая</a>
        <a href="/noindex-page">Noindex</a>
        <a href="/canonical-other">Canonical</a>
        <a href="/loop-a">Петля</a>
        <a href="/file.pdf">Прайс PDF</a>
        <a href="/photo.jpg"><img src="/photo.jpg"></a>
        <a href="/deep1" rel="nofollow">Глубже</a>
        <a href="mailto:test@example.org">Почта</a>
        <a href="/headings">Заголовки</a>
        <a href="/duplicate-a">Дубль А</a> <a href="/duplicate-b">Дубль Б</a>
        <a href="/images">Картинки</a>
        <a href="/h1-long">Длинный H1</a> <a href="/no-h2">Без H2</a> <a href="/h2-long">Длинный H2</a>
        <a href="/h2-dup-a">H2 А</a> <a href="/h2-dup-b">H2 Б</a>
        <a href="/canonical-none">Без canonical</a> <a href="/canonical-two-same">Два одинаковых canonical</a>
        <a href="/canonical-two-diff">Два разных canonical</a> <a href="/canonical-relative">Относительный canonical</a>
        <a href="/hreflang/ru/">Hreflang ru</a> <a href="/hreflang/no-return">Hreflang без обратной</a>
        <a href="/hreflang/no-self-ru">Hreflang без себя</a> <a href="/hreflang/no-xdefault">Hreflang без x-default</a>
        <a href="/hreflang/broken">Hreflang на 404</a> <a href="/hreflang/bad-code">Hreflang с неверным кодом</a>
        <a href="/nofollow-only" rel="nofollow">Только nofollow</a> <a href="/dead-end">Тупик</a>
        <a href="/meta-refresh">Meta refresh</a> <a href="/plain-html">HTML как text/plain</a> <a href="/no-content-type">Без Content-Type</a>
        <a href="/head-img">Картинка в head</a> <a href="/head-noscript">Счётчик в head</a>
        <a href="/two-bodies">Два body</a> <a href="/no-head-body">Без head и body</a>
        """), "text/html; charset=utf-8"),
    "/about/": (200, page("О компании — тестовый сайт SEOpars для парсера", "О компании", LOREM), "text/html; charset=utf-8"),
    "/about": (200, page("О компании — тестовый сайт SEOpars для парсера", "О компании", LOREM), "text/html; charset=utf-8"),
    "/каталог/": (200, page("Каталог товаров тестового сайта SEOpars парсер", "Каталог", LOREM + '<a href="/%d0%ba%d0%b0%d1%82%d0%b0%d0%bb%d0%be%d0%b3/">Каталог в нижнем регистре hex</a>'), "text/html; charset=utf-8"),
    "/catalog/phones": (200, page("Телефоны — каталог тестового сайта SEOpars", "Телефоны", LOREM), "text/html; charset=utf-8"),
    "/old-page": (301, "/redirect-step", None),
    "/redirect-step": (302, "/about/", None),
    "/error": (500, "<h1>500</h1>", "text/html"),
    "/blocked/secret": (200, page("Секрет", "Секрет", ""), "text/html; charset=utf-8"),
    "/noindex-page": (200, page("Страница с noindex на тестовом сайте SEOpars", "Noindex", LOREM + '<a href="/from-noindex">Ссылка только отсюда</a>',
        extra_head='<meta name="robots" content="noindex, follow">'), "text/html; charset=utf-8"),
    "/canonical-other": (200, page("Страница с canonical на другой адрес SEOpars", "Canonical", LOREM, extra_head=f'<link rel="canonical" href="{BASE}/about/">'), "text/html; charset=utf-8"),
    "/loop-a": (301, "/loop-b", None),
    "/loop-b": (301, "/loop-a", None),
    "/deep1": (200, page("Глубина 1 тестового сайта SEOpars для проверки", "Глубина 1", LOREM + '<a href="/deep2">дальше</a>'), "text/html; charset=utf-8"),
    "/deep2": (200, page("Глубина 2 тестового сайта SEOpars для проверки", "Глубина 2", LOREM + '<a href="/deep3">дальше</a>'), "text/html; charset=utf-8"),
    "/deep3": (200, page("Глубина 3 тестового сайта SEOpars для проверки", "Глубина 3", LOREM + '<a href="/deep4">дальше</a>'), "text/html; charset=utf-8"),
    "/deep4": (200, page("Глубина 4 тестового сайта SEOpars для проверки", "Глубина 4", LOREM + '<a href="/deep5">дальше</a>'), "text/html; charset=utf-8"),
    "/deep5": (200, page("Глубина 5 тестового сайта SEOpars для проверки", "Глубина 5", LOREM), "text/html; charset=utf-8"),
    "/orphan": (200, page("Сирота: только в sitemap тестового сайта SEOpars", "Сирота", LOREM), "text/html; charset=utf-8"),
    "/headings": (200, page("", "", "<h3>Сразу H3</h3><h2></h2>" + LOREM, desc=""), "text/html; charset=utf-8"),
    "/duplicate-a": (200, page("Дубль", "Дубль", "<p>Один и тот же текст</p>"), "text/html; charset=utf-8"),
    "/duplicate-b": (200, page("Дубль", "Дубль", "<p>Один и тот же текст</p>"), "text/html; charset=utf-8"),
    "/file.pdf": (200, b"%PDF-1.4 test", "application/pdf"),
    # № 113: без атрибута alt, пустой alt, alt длиннее 100 символов и нормальный alt.
    "/images": (200, page("Картинки с разными alt на тестовом сайте SEOpars", "Картинки", LOREM
        + '<img src="/no-alt.png"> <img src="/decor.png" alt=""> <img src="/long.png" alt="' + "длинный " * 15
        + '"> <img src="/ok.png" alt="Нормальная подпись">'), "text/html; charset=utf-8"),
    # № 106: H1 и H2 длиннее 70 символов, страница без H2, одинаковый первый H2 на двух страницах.
    "/h1-long": (200, page("Длинный H1 на тестовом сайте SEOpars для парсера",
        "Очень длинный заголовок первого уровня, который не помещается в семьдесят символов", LOREM,
        h2="Раздел страницы с длинным H1"), "text/html; charset=utf-8"),
    "/no-h2": (200, page("Страница без H2 на тестовом сайте SEOpars парсер", "Без H2", LOREM, h2=False), "text/html; charset=utf-8"),
    "/h2-long": (200, page("Длинный H2 на тестовом сайте SEOpars для парсера", "Длинный H2", LOREM,
        h2="Очень длинный заголовок второго уровня, который не помещается в семьдесят символов"), "text/html; charset=utf-8"),
    "/h2-dup-a": (200, page("Первая страница с общим H2 на сайте SEOpars", "Общий H2, страница А", LOREM, h2="Похожие товары"), "text/html; charset=utf-8"),
    "/h2-dup-b": (200, page("Вторая страница с общим H2 на сайте SEOpars", "Общий H2, страница Б", LOREM, h2="Похожие товары"), "text/html; charset=utf-8"),
    # № 100: без canonical, два одинаковых, два разных, относительный адрес.
    "/canonical-none": (200, page("Страница без canonical на тестовом сайте SEOpars", "Без canonical", LOREM), "text/html; charset=utf-8"),
    "/canonical-two-same": (200, page("Два одинаковых canonical на сайте SEOpars", "Два одинаковых canonical", LOREM,
        extra_head=f'<link rel="canonical" href="{BASE}/canonical-two-same"><link rel="canonical" href="{BASE}/canonical-two-same">'), "text/html; charset=utf-8"),
    "/canonical-two-diff": (200, page("Два разных canonical на тестовом сайте SEOpars", "Два разных canonical", LOREM,
        extra_head=f'<link rel="canonical" href="{BASE}/canonical-two-diff"><link rel="canonical" href="{BASE}/about/">'), "text/html; charset=utf-8"),
    "/canonical-relative": (200, page("Относительный canonical на сайте SEOpars парсер", "Относительный canonical", LOREM,
        extra_head='<link rel="canonical" href="/canonical-relative">'), "text/html; charset=utf-8"),
    # № 102: на страницу ведёт только nofollow (с главной); ссылка только с noindex-страницы; тупик.
    # Уже существующие /deep1 (только nofollow с главной) и /win1251 (ссылок нет) тоже попадают в эти проверки.
    "/nofollow-only": (200, page("Страница только с nofollow-ссылками на сайте SEOpars", "Только nofollow", LOREM), "text/html; charset=utf-8"),
    "/from-noindex": (200, page("Страница со ссылкой только с noindex на сайте SEOpars", "Ссылка только с noindex", LOREM), "text/html; charset=utf-8"),
    "/dead-end": (200, page("Тупик без внутренних ссылок на тестовом сайте SEOpars", "Тупик", LOREM
        + '<a href="/dead-end">Эта же страница</a> <a href="https://external.example.org/">Внешняя</a>', bare=True), "text/html; charset=utf-8"),
    # № 103: переход по meta refresh; HTML с Content-Type text/plain; HTML без заголовка Content-Type.
    "/meta-refresh": (200, page("Переход по meta refresh на тестовом сайте SEOpars", "Meta refresh", LOREM,
        extra_head='<meta http-equiv="refresh" content="0; url=/about/">'), "text/html; charset=utf-8"),
    "/plain-html": (200, page("HTML с Content-Type text/plain на сайте SEOpars", "HTML как текст", LOREM), "text/plain; charset=utf-8"),
    "/no-content-type": (200, page("HTML без заголовка Content-Type на сайте SEOpars", "Без Content-Type", LOREM), None),
    # № 112: <img> в <head> перед canonical; счётчик в <noscript> в <head> — не ошибка; два <body>.
    "/head-img": (200, page("Картинка в head перед canonical на сайте SEOpars", "Картинка в head", LOREM,
        extra_head=f'<img src="/pixel.gif" alt="Пиксель счётчика"><link rel="canonical" href="{BASE}/head-img">'), "text/html; charset=utf-8"),
    "/head-noscript": (200, page("Счётчик в noscript в head на сайте SEOpars", "Счётчик в head", LOREM,
        extra_head='<script>(function(){ var counter = "<body>"; })();</script><noscript><div><img src="https://mc.example.org/watch/1" style="position:absolute; left:-9999px;" alt="" /></div></noscript>'),
        "text/html; charset=utf-8"),
    "/two-bodies": (200, page("Два тега body на тестовом сайте SEOpars парсер", "Два body", '<body class="widget">' + LOREM), "text/html; charset=utf-8"),
}

# № 112: без <head> и <body> — HTML это разрешает, проверка отмечает.
ROUTES["/no-head-body"] = (200, f"""<!doctype html><html lang="ru"><meta charset="utf-8">
<title>Страница без head и body на тестовом сайте SEOpars</title>
<meta name="description" content="Описание страницы тестового сайта SEOpars для проверки парсера, достаточно длинное.">
<link rel="canonical" href="{BASE}/no-head-body">
<header><a href="/">Главная</a></header>
<main><h1>Без head и body</h1>{LOREM}<h2>Подробнее: без head и body</h2></main></html>""", "text/html; charset=utf-8")

# № 101: правильная пара ru/ ↔ en/ и по странице на каждую ошибку. en/, no-self-en и missing-en (404)
# находятся только через hreflang — так проверяется, что обходчик ставит цели hreflang в очередь.
HREFLANG = {
    "ru/": [("ru", "ru/"), ("en", "en/"), ("x-default", "ru/")],
    "en/": [("ru", "ru/"), ("en", "en/"), ("x-default", "ru/")],
    "no-return": [("ru", "no-return"), ("en", "en/"), ("x-default", "no-return")],
    "no-self-ru": [("en", "no-self-en"), ("x-default", "no-self-en")],
    "no-self-en": [("ru", "no-self-ru"), ("en", "no-self-en"), ("x-default", "no-self-en")],
    "no-xdefault": [("ru", "no-xdefault")],
    "broken": [("ru", "broken"), ("en", "missing-en"), ("x-default", "broken")],
    "bad-code": [("ru-RUS", "bad-code"), ("x-default", "bad-code")],
}
for name, pairs in HREFLANG.items():
    head = "".join(f'<link rel="alternate" hreflang="{lang}" href="{BASE}/hreflang/{target}">' for lang, target in pairs)
    ROUTES["/hreflang/" + name] = (200, page(f"Hreflang {name} — тестовый сайт SEOpars", f"Hreflang {name}", LOREM, extra_head=head),
                                   "text/html; charset=utf-8")

# Остальные HTML-страницы получают canonical на себя полным адресом: иначе «нет canonical» было бы везде.
NO_SELF_CANONICAL = {"/canonical-none"}

def with_canonical(path, html):
    if path in NO_SELF_CANONICAL or 'rel="canonical"' in html: return html
    return html.replace("</head>", f'<link rel="canonical" href="{BASE}{quote(path)}"></head>', 1)

ROBOTS = f"""User-agent: *
Disallow: /blocked/
Sitemap: {BASE}/sitemap.xml
"""
SITEMAP_INDEX = f"""<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<sitemap><loc>{BASE}/sitemap-pages.xml</loc></sitemap><sitemap><loc>{BASE}/sitemap-extra.xml</loc></sitemap></sitemapindex>"""
# № 104: /about/ записан и здесь, и в sitemap-pages.xml.
SITEMAP_EXTRA = f"""<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>{BASE}/about/</loc></url></urlset>"""
SITEMAP_PAGES = f"""<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>{BASE}/</loc></url><url><loc>{BASE}/about/</loc></url>
<url><loc>{BASE}/orphan</loc></url><url><loc>{BASE}/noindex-page</loc></url>
<url><loc>{BASE}/%D0%BA%D0%B0%D1%82%D0%B0%D0%BB%D0%BE%D0%B3/</loc></url></urlset>"""

WIN1251 = """<html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1251">
<title>Страница в кодировке windows-1251 тестового сайта</title>
<meta name="description" content="Проверка: кириллица в windows-1251 должна читаться без кракозябр в парсере SEOpars.">
</head><body><h1>Кириллица в 1251</h1><p>Съешь же ещё этих мягких французских булок, да выпей чаю.</p><h2>Раздел в 1251</h2></body></html>"""

GEN_TOTAL = 5000

def gen_page(path):
    """Нагрузочный сайт: /gen/0 … /gen/4999. Общее меню на 80 ссылок, подвал, по 10 ссылок в контенте."""
    try: n = int(path.split("/")[2])
    except ValueError: n = 0
    nav = " ".join(f'<a href="/gen/{i}">Раздел {i}</a>' for i in range(80))
    kids = " ".join(f'<a href="/gen/{c}">Товар {c}</a>' for c in range(10 * n + 1, min(10 * n + 11, GEN_TOTAL)))
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Страница {n} нагрузочного теста SEOpars</title>
<meta name="description" content="Описание страницы {n} для нагрузочного теста парсера SEOpars на пять тысяч страниц."></head>
<body><header><a href="/gen/0">Главная</a></header><nav>{nav}</nav><main><h1>Страница {n}</h1><h2>Подраздел</h2>
<p>{" ".join(["текст"] * 150)} {n}</p>{kids}</main>
<footer><a href="/gen/1">Доставка</a> <a href="/gen/2">Контакты</a> <a href="https://external.example.org/">Партнёр</a></footer></body></html>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype, headers=None):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        if ctype: self.send_header("Content-Type", ctype)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if path == "/robots.txt": return self.send(200, ROBOTS, "text/plain; charset=utf-8")
        if path == "/sitemap.xml": return self.send(200, SITEMAP_INDEX, "application/xml")
        if path == "/sitemap-pages.xml": return self.send(200, SITEMAP_PAGES, "application/xml")
        if path == "/sitemap-extra.xml": return self.send(200, SITEMAP_EXTRA, "application/xml")
        if path.startswith("/gen/"):
            return self.send(200, gen_page(path), "text/html; charset=utf-8")
        if path == "/win1251": return self.send(200, with_canonical(path, WIN1251).encode("cp1251"), "text/html")
        if path in ROUTES:
            code, body, ctype = ROUTES[path]
            if 300 <= code < 400: return self.send(code, "", "text/html", {"Location": body})
            if path.startswith("/deep"): time.sleep(0.05)
            if code == 200 and isinstance(body, str): body = with_canonical(path, body)
            return self.send(code, body, ctype)
        return self.send(404, page("404", "Не найдено", ""), "text/html; charset=utf-8")

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
