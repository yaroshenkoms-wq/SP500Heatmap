"""Тексты уведомлений на 9 языках. Ключ -> (заголовок, текст). Поля: {ticker} {value} {price} {chg} {name} {top} {title}."""

LANGS = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]

T = {
    "en": {
        "price_above": ("{ticker} is above {value}", "{ticker} trades at {price} ({chg} today)"),
        "price_below": ("{ticker} is below {value}", "{ticker} trades at {price} ({chg} today)"),
        "day_move_up": ("{ticker} is up {chg}", "{ticker} at {price} - a move above your {value}% alert"),
        "day_move_down": ("{ticker} is down {chg}", "{ticker} at {price} - a move above your {value}% alert"),
        "index_move_up": ("{name} is up {chg}", "Biggest mover: {top}"),
        "index_move_down": ("{name} is down {chg}", "Biggest mover: {top}"),
        "daily_summary": ("Market summary", "{name} {chg} today. Biggest mover: {top}"),
        "news": ("{ticker}: news", "{title}"),
        "news_market": ("Market news", "{title}"),
        "la_start": ("{name} Live", "{name} {chg} today"),
    },
    "es": {
        "price_above": ("{ticker} supera {value}", "{ticker} cotiza a {price} ({chg} hoy)"),
        "price_below": ("{ticker} cae por debajo de {value}", "{ticker} cotiza a {price} ({chg} hoy)"),
        "day_move_up": ("{ticker} sube {chg}", "{ticker} a {price}: supera tu alerta del {value}%"),
        "day_move_down": ("{ticker} baja {chg}", "{ticker} a {price}: supera tu alerta del {value}%"),
        "index_move_up": ("{name} sube {chg}", "Mayor movimiento: {top}"),
        "index_move_down": ("{name} baja {chg}", "Mayor movimiento: {top}"),
        "daily_summary": ("Resumen del mercado", "{name} {chg} hoy. Mayor movimiento: {top}"),
        "news": ("{ticker}: noticia", "{title}"),
        "news_market": ("Noticias del mercado", "{title}"),
        "la_start": ("{name} en directo", "{name} {chg} hoy"),
    },
    "zh-Hans": {
        "price_above": ("{ticker} 突破 {value}", "{ticker} 现价 {price}（今日 {chg}）"),
        "price_below": ("{ticker} 跌破 {value}", "{ticker} 现价 {price}（今日 {chg}）"),
        "day_move_up": ("{ticker} 上涨 {chg}", "{ticker} 现价 {price}，超过您设置的 {value}% 提醒"),
        "day_move_down": ("{ticker} 下跌 {chg}", "{ticker} 现价 {price}，超过您设置的 {value}% 提醒"),
        "index_move_up": ("{name} 上涨 {chg}", "波动最大：{top}"),
        "index_move_down": ("{name} 下跌 {chg}", "波动最大：{top}"),
        "daily_summary": ("市场日报", "{name} 今日 {chg}。波动最大：{top}"),
        "news": ("{ticker}：新闻", "{title}"),
        "news_market": ("市场新闻", "{title}"),
        "la_start": ("{name} 实时", "{name} 今日 {chg}"),
    },
    "ar": {
        "price_above": ("{ticker} فوق {value}", "{ticker} يتداول عند {price} ({chg} اليوم)"),
        "price_below": ("{ticker} تحت {value}", "{ticker} يتداول عند {price} ({chg} اليوم)"),
        "day_move_up": ("{ticker} يرتفع {chg}", "{ticker} عند {price} - تجاوز تنبيه {value}%"),
        "day_move_down": ("{ticker} ينخفض {chg}", "{ticker} عند {price} - تجاوز تنبيه {value}%"),
        "index_move_up": ("{name} يرتفع {chg}", "الأكبر حركة: {top}"),
        "index_move_down": ("{name} ينخفض {chg}", "الأكبر حركة: {top}"),
        "daily_summary": ("ملخص السوق", "{name} {chg} اليوم. الأكبر حركة: {top}"),
        "news": ("{ticker}: خبر", "{title}"),
        "news_market": ("أخبار السوق", "{title}"),
        "la_start": ("{name} مباشر", "{name} {chg} اليوم"),
    },
    "fr": {
        "price_above": ("{ticker} dépasse {value}", "{ticker} cote {price} ({chg} aujourd'hui)"),
        "price_below": ("{ticker} passe sous {value}", "{ticker} cote {price} ({chg} aujourd'hui)"),
        "day_move_up": ("{ticker} gagne {chg}", "{ticker} à {price} : au-dessus de votre alerte de {value}%"),
        "day_move_down": ("{ticker} perd {chg}", "{ticker} à {price} : au-dessus de votre alerte de {value}%"),
        "index_move_up": ("{name} progresse de {chg}", "Plus forte variation : {top}"),
        "index_move_down": ("{name} recule de {chg}", "Plus forte variation : {top}"),
        "daily_summary": ("Résumé du marché", "{name} {chg} aujourd'hui. Plus forte variation : {top}"),
        "news": ("{ticker} : actualité", "{title}"),
        "news_market": ("Actualité des marchés", "{title}"),
        "la_start": ("{name} en direct", "{name} {chg} aujourd'hui"),
    },
    "bn": {
        "price_above": ("{ticker} {value} ছাড়িয়েছে", "{ticker} এখন {price} ({chg} আজ)"),
        "price_below": ("{ticker} {value}-এর নিচে নেমেছে", "{ticker} এখন {price} ({chg} আজ)"),
        "day_move_up": ("{ticker} {chg} বেড়েছে", "{ticker} {price}-এ - আপনার {value}% সতর্কতা ছাড়িয়েছে"),
        "day_move_down": ("{ticker} {chg} কমেছে", "{ticker} {price}-এ - আপনার {value}% সতর্কতা ছাড়িয়েছে"),
        "index_move_up": ("{name} {chg} বেড়েছে", "সবচেয়ে বেশি নড়াচড়া: {top}"),
        "index_move_down": ("{name} {chg} কমেছে", "সবচেয়ে বেশি নড়াচড়া: {top}"),
        "daily_summary": ("বাজারের সারসংক্ষেপ", "{name} আজ {chg}। সবচেয়ে বেশি নড়াচড়া: {top}"),
        "news": ("{ticker}: খবর", "{title}"),
        "news_market": ("বাজারের খবর", "{title}"),
        "la_start": ("{name} লাইভ", "{name} আজ {chg}"),
    },
    "hi": {
        "price_above": ("{ticker} {value} से ऊपर", "{ticker} अभी {price} पर ({chg} आज)"),
        "price_below": ("{ticker} {value} से नीचे", "{ticker} अभी {price} पर ({chg} आज)"),
        "day_move_up": ("{ticker} {chg} चढ़ा", "{ticker} {price} पर - आपके {value}% अलर्ट से ज़्यादा"),
        "day_move_down": ("{ticker} {chg} गिरा", "{ticker} {price} पर - आपके {value}% अलर्ट से ज़्यादा"),
        "index_move_up": ("{name} {chg} चढ़ा", "सबसे बड़ी चाल: {top}"),
        "index_move_down": ("{name} {chg} गिरा", "सबसे बड़ी चाल: {top}"),
        "daily_summary": ("बाज़ार सारांश", "{name} आज {chg}। सबसे बड़ी चाल: {top}"),
        "news": ("{ticker}: ख़बर", "{title}"),
        "news_market": ("बाज़ार की ख़बरें", "{title}"),
        "la_start": ("{name} लाइव", "{name} आज {chg}"),
    },
    "ru": {
        "price_above": ("{ticker} выше {value}", "{ticker} торгуется по {price} ({chg} за день)"),
        "price_below": ("{ticker} ниже {value}", "{ticker} торгуется по {price} ({chg} за день)"),
        "day_move_up": ("{ticker} вырос на {chg}", "{ticker} по {price} - выше вашего порога {value}%"),
        "day_move_down": ("{ticker} упал на {chg}", "{ticker} по {price} - выше вашего порога {value}%"),
        "index_move_up": ("{name} вырос на {chg}", "Сильнее всех двигался: {top}"),
        "index_move_down": ("{name} упал на {chg}", "Сильнее всех двигался: {top}"),
        "daily_summary": ("Итоги рынка", "{name} {chg} за день. Сильнее всех двигался: {top}"),
        "news": ("{ticker}: новость", "{title}"),
        "news_market": ("Новости рынка", "{title}"),
        "la_start": ("{name} онлайн", "{name} {chg} за день"),
    },
    "uk": {
        "price_above": ("{ticker} вище {value}", "{ticker} торгується по {price} ({chg} за день)"),
        "price_below": ("{ticker} нижче {value}", "{ticker} торгується по {price} ({chg} за день)"),
        "day_move_up": ("{ticker} зріс на {chg}", "{ticker} по {price} - вище вашого порогу {value}%"),
        "day_move_down": ("{ticker} впав на {chg}", "{ticker} по {price} - вище вашого порогу {value}%"),
        "index_move_up": ("{name} зріс на {chg}", "Найбільший рух: {top}"),
        "index_move_down": ("{name} впав на {chg}", "Найбільший рух: {top}"),
        "daily_summary": ("Підсумки ринку", "{name} {chg} за день. Найбільший рух: {top}"),
        "news": ("{ticker}: новина", "{title}"),
        "news_market": ("Новини ринку", "{title}"),
        "la_start": ("{name} наживо", "{name} {chg} за день"),
    },
}


def normalize_lang(lang):
    l = (lang or "en").replace("_", "-")
    for code in LANGS:
        if l.lower() == code.lower():
            return code
    base = l.split("-")[0].lower()
    if base == "zh":
        return "zh-Hans"
    return base if base in T else "en"


def render(lang, key, **params):
    title, body = T[normalize_lang(lang)][key]
    safe = {k: ("" if v is None else v) for k, v in params.items()}
    return title.format(**safe), body.format(**safe)
