#!/usr/bin/env python3
"""Демо-сайт для скриншотов README: вымышленная чайная лавка «Листок».

Около 45 URL с правдоподобным текстом и намеренными ошибками, чтобы на снимках
были заполнены все вкладки SEOpars: редирект и цепочка, 404 и 500, запрет в
robots.txt, noindex, canonical на другой URL, сирота из sitemap, дубль title,
пустой description, нет H1 и два H1, картинки без alt, короткие страницы.

Это не тестовая фикстура: для тестов — Tests/Fixtures/fixture_server.py.
Абсолютные адреса строятся из заголовка Host, поэтому сайт можно открыть
по http://demo.localhost:<порт>/.
Запуск: python3 -I scripts/screenshots/demo_site.py [порт]
"""
import random
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 18991
SHOP = "чайная лавка «Листок»"

CATEGORIES = {
    "puer": ("Пуэр", [
        ("shu-puer-guntin-2018", "Шу пуэр «Гунтин» 2018", 1450),
        ("shen-puer-bulang-2015", "Шэн пуэр «Булан» 2015", 2300),
        ("shu-puer-mini-tocha", "Шу пуэр мини-точа", 690),
        ("shen-puer-ivu-2020", "Шэн пуэр «Иу» 2020", 1890),
    ]),
    "ulun": ("Улун", [
        ("te-guan-in", "Те Гуань Инь", 980),
        ("da-hun-pao", "Да Хун Пао", 1650),
        ("molochnyj-ulun", "Молочный улун", 870),
        ("feniks-dan-cun", "Фениксовый Дань Цун", 1720),
    ]),
    "zelenyj": ("Зелёный чай", [
        ("lun-czin", "Лунцзин", 1350),
        ("bi-lo-chun", "Би Ло Чунь", 1190),
        ("sencha", "Сенча", 760),
        ("zhu-cha", "Чжу Ча", 540),
    ]),
    "krasnyj": ("Красный чай", [
        ("dyan-hun", "Дянь Хун", 820),
        ("czin-czyun-mej", "Цзинь Цзюнь Мэй", 2100),
        ("lapsang-suchong", "Лапсанг Сушонг", 890),
    ]),
    "belyj": ("Белый чай", [
        ("baj-hao-in-chzhen", "Бай Хао Инь Чжэнь", 2400),
        ("baj-mu-dan", "Бай Му Дань", 1150),
        ("shou-mej", "Шоу Мэй", 990),
    ]),
    "posuda": ("Посуда", [
        ("gaivan-farfor", "Гайвань фарфоровая 150 мл", 1200),
        ("chaban-bambuk", "Чабань бамбуковая", 2900),
        ("chahaj-steklo", "Чахай стеклянный", 650),
    ]),
}

ARTICLES = [
    ("kak-zavarivat-puer",
     "Как заваривать пуэр дома: пошаговая инструкция для начинающих с фото и видео",
     "Как заваривать пуэр дома"),
    ("chem-otlichaetsya-shen-ot-shu", "Чем шэн пуэр отличается от шу пуэра", "Шэн и шу: в чём разница"),
    ("kak-hranit-chaj", "Как хранить чай дома, чтобы он не терял вкус", "Как хранить чай дома"),
    ("gaivan-ili-chajnik", "Гайвань или чайник: что выбрать для заваривания", "Гайвань или чайник"),
    ("temperatura-vody", "Температура воды для зелёного, белого и красного чая", "Температура воды для чая"),
    ("svetlye-i-temnye-ulun", "Светлые и тёмные улуны: в чём разница и как выбрать", "Светлые и тёмные улуны"),
]

SENTENCES = [
    "{n} собирают весной, когда лист набирает больше всего аромата.",
    "Перед первой заваркой лист стоит промыть горячей водой и сразу слить настой.",
    "Вкус {n} раскрывается постепенно: первые проливы лёгкие, следующие плотнее.",
    "Для заваривания подходит гайвань или небольшой глиняный чайник.",
    "Мы храним чай в сухом помещении без посторонних запахов и солнечного света.",
    "Каждую партию {n} мы пробуем сами, прежде чем выставить её на витрину.",
    "Вода лучше мягкая, без хлора: подойдёт фильтрованная или бутилированная.",
    "Время первого пролива — около десяти секунд, затем его можно увеличивать.",
    "В настое {n} чувствуются ноты сухофруктов, мёда и тёплого хлеба.",
    "Одной порции листа хватает на шесть–восемь проливов в зависимости от вкуса.",
    "Чай отправляем в герметичной упаковке, чтобы он не впитал запахи в дороге.",
    "Если настой горчит, уменьшите количество листа или время заваривания.",
    "Остатки чая храните в плотно закрытой банке подальше от специй и кофе.",
    "{n} хорошо сочетается с несладкой выпечкой и сухофруктами.",
    "Чайная церемония не обязательна: достаточно чистой посуды и свободной минуты.",
    "Цвет настоя {n} зависит от степени ферментации и времени выдержки.",
    "Для компании из трёх человек берите чайник объёмом около двухсот миллилитров.",
    "Мы работаем напрямую с несколькими чайными хозяйствами и знаем их урожаи.",
    "Пробник на одну заварку можно добавить к любому заказу бесплатно.",
    "Ароматный пар над чашкой — хороший знак: лист свежий и правильно хранился.",
    "Не используйте кипяток для нежных сортов, иначе вкус станет плоским.",
    "Перед покупкой большой упаковки советуем взять пробник и попробовать {n}.",
]


def text(name, seed, sentences=22):
    rnd = random.Random(seed)
    parts = []
    for _ in range(3):
        picked = rnd.sample(SENTENCES, sentences // 3)
        parts.append("<p>" + " ".join(s.format(n=name) for s in picked) + "</p>")
    return "".join(parts)


def page(host, path, title, h1, body, desc=None, extra_head="", h2=None, h1_html=None):
    canonical = f'<link rel="canonical" href="http://{host}{path}">'
    desc_tag = "" if desc is None else f'<meta name="description" content="{desc}">'
    heading = h1_html if h1_html is not None else f"<h1>{h1}</h1>"
    h2_html = f"<h2>{h2 or 'Подробнее: ' + h1}</h2>"
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>{desc_tag}{canonical}{extra_head}</head>
<body><header><a href="/">Листок</a>
<nav><a href="/catalog/">Каталог</a> <a href="/blog/">Блог</a> <a href="/delivery/">Доставка</a>
<a href="/contacts/">Контакты</a> <a href="/cart/">Корзина</a></nav></header>
<main>{heading}{body}{h2_html}</main>
<footer><a href="/about/">О магазине</a> <a href="/oplata/">Оплата</a>
<a href="https://example.com/">Мы в соцсетях</a></footer></body></html>"""


def product_url(cat, slug):
    return f"/catalog/{cat}/{slug}/"


def build_routes(host):
    r = {}
    all_products = [(cat, *p) for cat, (_, items) in CATEGORIES.items() for p in items]

    top = "".join(f'<li><a href="{product_url(c, s)}">{n}</a> — {p} ₽</li>' for c, s, n, p in all_products[::5])
    r["/"] = page(host, "/", "Чайная лавка «Листок» — китайский чай с доставкой", "Китайский чай с доставкой",
                  text("китайский чай", "home") + f"<ul>{top}</ul>"
                  '<p><a href="/sale/">Акции недели</a> · <a href="/promo/">Промокоды</a> · '
                  '<a href="/blog/">Читать блог</a></p>',
                  desc="Пуэр, улун, зелёный, красный и белый чай напрямую от хозяйств. Пробник к каждому заказу, доставка по России.",
                  h2="Почему у нас")

    cats = "".join(f'<li><a href="/catalog/{c}/">{t}</a></li>' for c, (t, _) in CATEGORIES.items())
    catalog_body = text("чай из нашего каталога", "catalog") + f"<ul>{cats}</ul>" + \
        '<p><a href="/catalog/?sort=price">Сортировать по цене</a></p>'
    r["/catalog/"] = page(host, "/catalog/", "Каталог китайского чая и посуды — " + SHOP, "Каталог",
                          catalog_body, desc="Каталог китайского чая и посуды: пуэр, улун, зелёный, красный и белый чай, гайвани и чабани.",
                          h2="Как выбрать чай")
    # Тот же каталог с сортировкой: canonical указывает на /catalog/.
    r["/catalog/?sort=price"] = page(host, "/catalog/", "Каталог китайского чая и посуды — " + SHOP, "Каталог",
                                     catalog_body, desc="Каталог китайского чая и посуды: пуэр, улун, зелёный, красный и белый чай, гайвани и чабани.",
                                     h2="Как выбрать чай")

    for cat, (title, items) in CATEGORIES.items():
        lis = "".join(f'<li><a href="{product_url(cat, s)}">{n}</a> — {p} ₽</li>' for s, n, p in items)
        r[f"/catalog/{cat}/"] = page(host, f"/catalog/{cat}/", f"{title} — купить в чайной лавке «Листок»", title,
                                     text(title.lower(), cat) + f"<ul>{lis}</ul>",
                                     desc=f"{title} в чайной лавке «Листок»: описания, вкус, способы заваривания и цены. Отправляем в день заказа.",
                                     h2=f"Как заваривать: {title.lower()}")
        for slug, name, price in items:
            path = product_url(cat, slug)
            title_tag = f"{name} — купить в чайной лавке «Листок»"
            desc = f"{name}: вкус, аромат и способ заваривания. Цена {price} ₽ за упаковку, пробник бесплатно к любому заказу."
            if slug in ("baj-mu-dan", "shou-mej"):
                title_tag = "Белый чай — купить в чайной лавке «Листок»"  # дубль title
            if slug in ("sencha", "zhu-cha"):
                desc = None  # нет description
            alt = "" if cat == "posuda" else f' alt="{name}"'  # посуда — картинки без alt
            body = (f'<p><img src="/img/{slug}.jpg"{alt} width="600" height="400"></p>'
                    f"<p><b>{price} ₽</b> · <a href=\"/catalog/{cat}/\">Все: {title.lower()}</a></p>" + text(name, slug))
            r[path] = page(host, path, title_tag, name, body, desc=desc, h2=f"Как заваривать {name}")

    arts = "".join(f'<li><a href="/blog/{s}/">{t}</a></li>' for s, t, _ in ARTICLES)
    r["/blog/"] = page(host, "/blog/", "Блог о китайском чае — " + SHOP, "Блог о чае",
                       text("китайский чай", "blog") + f"<ul>{arts}</ul><p><a href=\"/blog/arhiv/\">Архив статей</a></p>",
                       desc="Статьи о китайском чае: как выбирать, заваривать и хранить пуэр, улун, зелёный и белый чай.",
                       h2="Новые статьи")
    for i, (slug, title, h1) in enumerate(ARTICLES):
        extra = ""
        if slug == "kak-zavarivat-puer":
            extra = ('<p>Подробнее о сортах — в статье <a href="/blog/udalennaya-statya/">о выдержке пуэра</a> '
                     'и в <a href="/old-catalog/">старом каталоге</a>.</p>')
        prods = "".join(f'<a href="{product_url(c, s)}">{n}</a> ' for c, s, n, _ in all_products[i::7])
        r[f"/blog/{slug}/"] = page(host, f"/blog/{slug}/", title, h1,
                                   text(h1.lower(), slug) + extra + f"<p>Чай из статьи: {prods}</p>",
                                   desc=f"{h1}: практические советы от чайной лавки «Листок» с примерами и ошибками новичков.",
                                   h2="Коротко")

    r["/about/"] = page(host, "/about/", "О чайной лавке «Листок»: кто мы и откуда чай", "О магазине",
                        text("наш чай", "about"),
                        desc="Чайная лавка «Листок» работает с 2019 года. Рассказываем, где берём чай и как проверяем каждую партию.",
                        h2="Наши хозяйства")
    # Два H1.
    r["/delivery/"] = page(host, "/delivery/", "Доставка чая по России — " + SHOP, "Доставка",
                           text("заказ", "delivery"),
                           desc="Доставка чая по России: курьер, пункты выдачи и почта. Сроки и стоимость для каждого способа.",
                           h1_html="<h1>Доставка</h1><h1>Сроки и стоимость</h1>", h2="Самовывоз")
    # Нет H1, мало слов.
    r["/contacts/"] = page(host, "/contacts/", "Контакты чайной лавки «Листок» в Москве", "",
                           "<p>Москва, ул. Чайная, 1. Ежедневно с 10 до 21.</p>",
                           desc="Адрес, телефон и часы работы чайной лавки «Листок» в Москве. Можно прийти на дегустацию.",
                           h1_html="", h2="Как добраться")
    # Короткий title, мало слов.
    r["/oplata/"] = page(host, "/oplata/", "Оплата", "Оплата",
                         "<p>Принимаем карты, СБП и наличные при получении.</p>",
                         desc="Способы оплаты в чайной лавке «Листок»: банковские карты, СБП и наличные при получении заказа.")
    # noindex.
    r["/promo/"] = page(host, "/promo/", "Промокоды и скидки чайной лавки «Листок»", "Промокоды",
                        text("промокод", "promo"),
                        desc="Действующие промокоды чайной лавки «Листок»: скидки на первый заказ и на пуэр недели.",
                        extra_head='<meta name="robots" content="noindex, follow">')
    # Сирота: есть только в sitemap.
    r["/landing-novyj-god/"] = page(host, "/landing-novyj-god/", "Чайные подарки на Новый год — " + SHOP,
                                    "Чайные подарки на Новый год", text("подарочный набор", "ny"),
                                    desc="Подарочные наборы китайского чая к Новому году: пуэр, улун и посуда в коробке.")
    return r


REDIRECTS = {"/old-catalog/": "/catalog/", "/sale/": "/akcii/", "/akcii/": "/catalog/"}
ROBOTS = "User-agent: *\nDisallow: /cart/\n\nSitemap: http://{host}/sitemap.xml\n"
SITEMAP_EXTRA = ["/landing-novyj-god/"]
GIF = bytes.fromhex("47494638396101000100800000ffffff00000021f90401000000002c00000000010001000002024401003b")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, ctype="text/html; charset=utf-8", headers=None):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        host = self.headers.get("Host", f"127.0.0.1:{PORT}")
        parts = urlsplit(self.path)
        key = parts.path + (f"?{parts.query}" if parts.query else "")
        routes = build_routes(host)
        if parts.path == "/robots.txt":
            return self.send(200, ROBOTS.format(host=host), "text/plain; charset=utf-8")
        if parts.path == "/sitemap.xml":
            urls = [u for u in routes if "?" not in u and u not in ("/promo/",)] + SITEMAP_EXTRA
            locs = "".join(f"<url><loc>http://{host}{u}</loc></url>" for u in dict.fromkeys(urls))
            xml = f'<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{locs}</urlset>'
            return self.send(200, xml, "application/xml")
        if parts.path.startswith("/img/"):
            return self.send(200, GIF, "image/gif")
        if parts.path in REDIRECTS:
            return self.send(301, "", headers={"Location": REDIRECTS[parts.path]})
        if parts.path == "/blog/arhiv/":
            return self.send(500, "<h1>Внутренняя ошибка сервера</h1>")
        if key in routes:
            return self.send(200, routes[key])
        if parts.path in routes and not parts.query:
            return self.send(200, routes[parts.path])
        self.send(404, "<!doctype html><title>Страница не найдена</title><h1>404</h1>")


if __name__ == "__main__":
    # Самопроверка: у обычных страниц текст не короче порога «мало слов» (200) и без полных дублей.
    routes = build_routes("demo.localhost")
    import re
    bodies = {}
    for path, html in routes.items():
        words = len(re.sub(r"<[^>]+>", " ", html.split("<main>")[1].split("</main>")[0]).split())
        if path not in ("/contacts/", "/oplata/"):
            assert words >= 200, (path, words)
        bodies.setdefault(html.split("<main>")[1], []).append(path)
    dups = [p for p in bodies.values() if len(p) > 1]
    assert dups == [["/catalog/", "/catalog/?sort=price"]], dups
    if "--check" in sys.argv:
        print(f"ok: {len(routes)} страниц")
        sys.exit(0)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
