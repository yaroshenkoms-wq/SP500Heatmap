#!/usr/bin/env python3
"""Adds push / Live Activity strings (9 languages) to the app and widget Localizable.xcstrings. Safe to re-run: existing keys are kept."""
import json, os
ROOT = os.path.join(os.path.dirname(__file__), "..", "SP500Heatmap")
APP = os.path.join(ROOT, "SP500Heatmap", "Localizable.xcstrings")
WIDGET = os.path.join(ROOT, "SP500HeatmapWidgets", "Localizable.xcstrings")
LANGS = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]

# key: [es, zh-Hans, ar, fr, bn, hi, ru, uk]
APP_T = {
"Push active": ["Push activo", "推送已启用", "الإشعارات الفورية مفعّلة", "Push actif", "পুশ চালু আছে", "पुश सक्रिय है", "Push включён", "Push увімкнено"],
"Checking push status…": ["Comprobando el estado del push…", "正在检查推送状态…", "جارٍ التحقق من حالة الإشعارات…", "Vérification du statut push…", "পুশের অবস্থা যাচাই হচ্ছে…", "पुश स्थिति जाँची जा रही है…", "Проверяем состояние push…", "Перевіряємо стан push…"],
"Push not configured on server — local mode": ["Push no configurado en el servidor: modo local", "服务器未配置推送：本地模式", "الإشعارات الفورية غير مُعدّة على الخادم: الوضع المحلي", "Push non configuré sur le serveur : mode local", "সার্ভারে পুশ কনফিগার করা নেই — লোকাল মোড", "सर्वर पर पुश कॉन्फ़िगर नहीं है — लोकल मोड", "Push не настроен на сервере — локальный режим", "Push не налаштовано на сервері — локальний режим"],
"News on my watchlist": ["Noticias de mi lista de seguimiento", "自选列表的新闻", "أخبار قائمة المتابعة", "Actualités de ma liste de suivi", "আমার ওয়াচলিস্টের খবর", "मेरी वॉचलिस्ट की खबरें", "Новости по моему списку", "Новини за моїм списком"],
"Send test notification": ["Enviar notificación de prueba", "发送测试通知", "إرسال إشعار تجريبي", "Envoyer une notification de test", "টেস্ট নোটিফিকেশন পাঠান", "टेस्ट सूचना भेजें", "Отправить тестовое уведомление", "Надіслати тестове сповіщення"],
"Test notification": ["Notificación de prueba", "测试通知", "إشعار تجريبي", "Notification de test", "টেস্ট নোটিফিকেশন", "टेस्ट सूचना", "Тестовое уведомление", "Тестове сповіщення"],
"This is how your alerts will look.": ["Así se verán tus alertas.", "您的提醒将如此显示。", "هكذا ستظهر تنبيهاتك.", "Voici à quoi ressembleront vos alertes.", "আপনার অ্যালার্ট এভাবেই দেখাবে।", "आपके अलर्ट ऐसे दिखेंगे।", "Так будут выглядеть ваши оповещения.", "Так виглядатимуть ваші сповіщення."],
"Push alerts are sent by our server, even when the app is closed. News alerts need push.": ["Las alertas push las envía nuestro servidor, incluso con la app cerrada. Las alertas de noticias requieren push.", "推送提醒由我们的服务器发送，即使应用已关闭也会收到。新闻提醒需要推送。", "يرسل خادمنا التنبيهات الفورية حتى عند إغلاق التطبيق. تنبيهات الأخبار تتطلب الإشعارات الفورية.", "Les alertes push sont envoyées par notre serveur, même app fermée. Les alertes d'actualités nécessitent le push.", "অ্যাপ বন্ধ থাকলেও আমাদের সার্ভার পুশ অ্যালার্ট পাঠায়। খবরের অ্যালার্টের জন্য পুশ দরকার।", "ऐप बंद होने पर भी हमारा सर्वर पुश अलर्ट भेजता है। खबरों के अलर्ट के लिए पुश ज़रूरी है।", "Push-оповещения отправляет наш сервер, даже когда приложение закрыто. Для новостей нужен push.", "Push-сповіщення надсилає наш сервер, навіть коли застосунок закрито. Для новин потрібен push."],
"Alerts are checked in the background. iOS decides when that runs, so alerts may be delayed or skipped, especially if the app has not been opened for a while. News alerts need push.": ["Las alertas se comprueban en segundo plano. iOS decide cuándo, así que pueden retrasarse u omitirse, sobre todo si no abres la app desde hace tiempo. Las alertas de noticias requieren push.", "提醒在后台检查。运行时间由 iOS 决定，因此提醒可能延迟或被跳过，尤其是长时间未打开应用时。新闻提醒需要推送。", "تُفحص التنبيهات في الخلفية. يقرر iOS وقت ذلك، لذا قد تتأخر أو تُتجاوز، خاصة إذا لم تفتح التطبيق منذ فترة. تنبيهات الأخبار تتطلب الإشعارات الفورية.", "Les alertes sont vérifiées en arrière-plan. iOS décide du moment : elles peuvent être retardées ou ignorées, surtout si l'app n'a pas été ouverte depuis un moment. Les alertes d'actualités nécessitent le push.", "অ্যালার্ট ব্যাকগ্রাউন্ডে যাচাই হয়। কখন চলবে তা iOS ঠিক করে, তাই দেরি হতে পারে বা বাদ যেতে পারে, বিশেষত অ্যাপ অনেক দিন না খুললে। খবরের অ্যালার্টের জন্য পুশ দরকার।", "अलर्ट बैकग्राउंड में जाँचे जाते हैं। यह कब चलेगा, iOS तय करता है, इसलिए अलर्ट देर से आ सकते हैं या छूट सकते हैं, खासकर अगर ऐप काफ़ी समय से नहीं खुला। खबरों के अलर्ट के लिए पुश ज़रूरी है।", "Оповещения проверяются в фоне. Когда это происходит, решает iOS, поэтому они могут опаздывать или пропускаться, особенно если приложение давно не открывали. Для новостей нужен push.", "Сповіщення перевіряються у фоні. Коли це відбувається, вирішує iOS, тому вони можуть запізнюватися або пропускатися, особливо якщо застосунок давно не відкривали. Для новин потрібен push."],
"Live Activity": ["Actividad en directo", "实时活动", "النشاط المباشر", "Activité en direct", "লাইভ অ্যাক্টিভিটি", "लाइव एक्टिविटी", "Live Activity", "Live Activity"],
"Start Live Activity at the US open": ["Iniciar la actividad en directo con la apertura de EE. UU.", "美股开盘时自动开启实时活动", "بدء النشاط المباشر عند افتتاح السوق الأمريكية", "Lancer l'activité en direct à l'ouverture américaine", "মার্কিন বাজার খুললে লাইভ অ্যাক্টিভিটি শুরু করুন", "अमेरिकी बाज़ार खुलने पर लाइव एक्टिविटी शुरू करें", "Запускать Live Activity с открытием США", "Запускати Live Activity з відкриттям США"],
"Tap the live icon on an index map to follow it on the Lock Screen and in the Dynamic Island. The server updates it even when the app is closed.": ["Toca el icono en directo en el mapa de un índice para seguirlo en la pantalla de bloqueo y en la Dynamic Island. El servidor lo actualiza incluso con la app cerrada.", "在指数地图上点按实时图标，即可在锁定屏幕和灵动岛中关注该指数。即使应用已关闭，服务器也会更新。", "اضغط على أيقونة البث المباشر في خريطة المؤشر لمتابعته على شاشة القفل وفي Dynamic Island. يحدّثه الخادم حتى عند إغلاق التطبيق.", "Touchez l'icône en direct sur la carte d'un indice pour le suivre sur l'écran verrouillé et dans la Dynamic Island. Le serveur le met à jour même app fermée.", "ইনডেক্স ম্যাপে লাইভ আইকনে ট্যাপ করে লক স্ক্রিন ও ডাইনামিক আইল্যান্ডে অনুসরণ করুন। অ্যাপ বন্ধ থাকলেও সার্ভার এটি আপডেট করে।", "किसी इंडेक्स मैप पर लाइव आइकन टैप करें और लॉक स्क्रीन व डायनामिक आइलैंड पर उसे फ़ॉलो करें। ऐप बंद होने पर भी सर्वर इसे अपडेट करता है।", "Нажмите значок «live» на карте индекса, чтобы следить за ним на экране блокировки и в Dynamic Island. Сервер обновляет его, даже когда приложение закрыто.", "Натисніть значок «live» на карті індексу, щоб стежити за ним на екрані блокування й у Dynamic Island. Сервер оновлює його, навіть коли застосунок закрито."],
"Tap the live icon on an index map to follow it on the Lock Screen and in the Dynamic Island. Without push it updates only while the app is open.": ["Toca el icono en directo en el mapa de un índice para seguirlo en la pantalla de bloqueo y en la Dynamic Island. Sin push, solo se actualiza mientras la app está abierta.", "在指数地图上点按实时图标，即可在锁定屏幕和灵动岛中关注该指数。没有推送时，仅在应用打开期间更新。", "اضغط على أيقونة البث المباشر في خريطة المؤشر لمتابعته على شاشة القفل وفي Dynamic Island. بدون الإشعارات الفورية يتحدّث فقط أثناء فتح التطبيق.", "Touchez l'icône en direct sur la carte d'un indice pour le suivre sur l'écran verrouillé et dans la Dynamic Island. Sans push, il ne se met à jour que lorsque l'app est ouverte.", "ইনডেক্স ম্যাপে লাইভ আইকনে ট্যাপ করে লক স্ক্রিন ও ডাইনামিক আইল্যান্ডে অনুসরণ করুন। পুশ ছাড়া এটি শুধু অ্যাপ খোলা থাকলে আপডেট হয়।", "किसी इंडेक्स मैप पर लाइव आइकन टैप करें और लॉक स्क्रीन व डायनामिक आइलैंड पर उसे फ़ॉलो करें। पुश के बिना यह केवल ऐप खुला होने पर अपडेट होता है।", "Нажмите значок «live» на карте индекса, чтобы следить за ним на экране блокировки и в Dynamic Island. Без push он обновляется, только пока приложение открыто.", "Натисніть значок «live» на карті індексу, щоб стежити за ним на екрані блокування й у Dynamic Island. Без push він оновлюється, лише поки застосунок відкрито."],
"Follow live": ["Seguir en directo", "实时关注", "متابعة مباشرة", "Suivre en direct", "লাইভ অনুসরণ করুন", "लाइव फ़ॉलो करें", "Следить в реальном времени", "Стежити наживо"],
"Stop following": ["Dejar de seguir", "停止关注", "إيقاف المتابعة", "Arrêter le suivi", "অনুসরণ বন্ধ করুন", "फ़ॉलो करना बंद करें", "Перестать следить", "Припинити стеження"],
"Live Activities are off": ["Las actividades en directo están desactivadas", "实时活动已关闭", "الأنشطة المباشرة متوقفة", "Les activités en direct sont désactivées", "লাইভ অ্যাক্টিভিটি বন্ধ আছে", "लाइव एक्टिविटी बंद हैं", "Live Activities выключены", "Live Activities вимкнено"],
"Allow Live Activities for this app in iOS Settings.": ["Permite las actividades en directo de esta app en Ajustes de iOS.", "请在 iOS 设置中允许此应用使用实时活动。", "اسمح بالأنشطة المباشرة لهذا التطبيق في إعدادات iOS.", "Autorisez les activités en direct pour cette app dans les Réglages iOS.", "iOS সেটিংসে এই অ্যাপের জন্য লাইভ অ্যাক্টিভিটি অনুমোদন করুন।", "iOS सेटिंग्स में इस ऐप के लिए लाइव एक्टिविटी की अनुमति दें।", "Разрешите Live Activities для этого приложения в настройках iOS.", "Дозвольте Live Activities для цього застосунку в налаштуваннях iOS."],
}
WIDGET_T = {
"Market session": ["Sesión de mercado", "市场交易时段", "جلسة السوق", "Séance de marché", "বাজার সেশন", "बाज़ार सत्र", "Торговая сессия", "Торгова сесія"],
}

def add(path, table):
    raw = open(path).read()
    strings = json.loads(raw)["strings"]
    chunks = []
    for key, tr in table.items():
        assert len(tr) == 8, key
        if key in strings:
            continue
        loc = {"en": {"stringUnit": {"state": "translated", "value": key}}}
        for lang, val in zip(LANGS[1:], tr):
            loc[lang] = {"stringUnit": {"state": "translated", "value": val}}
        entry = {"extractionState": "manual", "localizations": loc}
        body = json.dumps({key: entry}, ensure_ascii=False, indent=2)
        chunks.append("\n".join("  " + line for line in body.split("\n")[1:-1]))
    if chunks:
        marker = "\n  },\n  \"version\""
        at = raw.rindex(marker)
        raw = raw[:at] + ",\n" + ",\n".join(chunks) + raw[at:]
        json.loads(raw)
        open(path, "w").write(raw)
    print(os.path.basename(os.path.dirname(path)), "added", len(chunks))

def check(path, table):
    strings = json.load(open(path))["strings"]
    for key in table:
        loc = strings[key]["localizations"]
        missing = [l for l in LANGS if l not in loc or not loc[l]["stringUnit"]["value"]]
        assert not missing, (key, missing)
    print("check ok:", len(table), "keys x 9 languages in", os.path.basename(os.path.dirname(path)))

if __name__ == "__main__":
    add(APP, APP_T); add(WIDGET, WIDGET_T)
    check(APP, APP_T); check(WIDGET, WIDGET_T)
