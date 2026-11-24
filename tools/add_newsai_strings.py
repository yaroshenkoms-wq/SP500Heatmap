#!/usr/bin/env python3
"""Adds the News and AI-chat strings (9 languages) to Localizable.xcstrings. Safe to re-run: existing keys are kept.
Order of translations: es, zh-Hans, ar, fr, bn, hi, ru, uk."""
import json, os
PATH = os.path.join(os.path.dirname(__file__), "..", "SP500Heatmap", "SP500Heatmap", "Localizable.xcstrings")
LANGS = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]

T = {
"Market": ["Mercado","市场","السوق","Marché","বাজার","बाज़ार","Рынок","Ринок"],
"My lists": ["Mis listas","我的列表","قوائمي","Mes listes","আমার তালিকা","मेरी सूचियाँ","Мои списки","Мої списки"],
"All lists": ["Todas las listas","所有列表","كل القوائم","Toutes les listes","সব তালিকা","सभी सूचियाँ","Все списки","Усі списки"],
"All languages": ["Todos los idiomas","所有语言","كل اللغات","Toutes les langues","সব ভাষা","सभी भाषाएँ","Все языки","Усі мови"],
"Add stocks to a watchlist to see their news here.": ["Añade valores a una lista de seguimiento para ver aquí sus noticias.","将股票添加到自选列表，即可在此查看相关新闻。","أضف أسهماً إلى قائمة المتابعة لعرض أخبارها هنا.","Ajoutez des actions à une liste de suivi pour voir ici leurs actualités.","এখানে খবর দেখতে ওয়াচলিস্টে শেয়ার যোগ করুন।","यहाँ उनकी खबरें देखने के लिए वॉचलिस्ट में शेयर जोड़ें।","Добавьте акции в список наблюдения, чтобы видеть здесь их новости.","Додайте акції до списку спостереження, щоб бачити тут їхні новини."],
"No news in your language right now.": ["Ahora mismo no hay noticias en tu idioma.","目前没有您所用语言的新闻。","لا توجد أخبار بلغتك حالياً.","Aucune actualité dans votre langue pour le moment.","এই মুহূর্তে আপনার ভাষায় কোনো খবর নেই।","अभी आपकी भाषा में कोई खबर नहीं है।","Сейчас нет новостей на вашем языке.","Наразі немає новин вашою мовою."],
"Headlines come from public sources. AI-generated summaries may be inaccurate. Not investment advice.": ["Los titulares proceden de fuentes públicas. Los resúmenes de IA pueden contener errores. No es asesoramiento de inversión.","标题来自公开来源。AI 生成的摘要可能不准确。不构成投资建议。","العناوين من مصادر عامة. قد تكون الملخصات التي ينشئها الذكاء الاصطناعي غير دقيقة. ليست نصيحة استثمارية.","Les titres proviennent de sources publiques. Les résumés générés par l’IA peuvent être inexacts. Ce n’est pas un conseil en investissement.","শিরোনামগুলো পাবলিক উৎস থেকে নেওয়া। AI-তৈরি সারাংশ ভুল হতে পারে। এটি বিনিয়োগ পরামর্শ নয়।","हेडलाइन सार्वजनिक स्रोतों से ली गई हैं। AI द्वारा बनाए सारांश गलत हो सकते हैं। यह निवेश सलाह नहीं है।","Заголовки взяты из открытых источников. Сводки, созданные ИИ, могут быть неточными. Это не инвестиционная рекомендация.","Заголовки взято з відкритих джерел. Зведення, створені ШІ, можуть бути неточними. Це не інвестиційна порада."],
"AI digest": ["Resumen de IA","AI 摘要","ملخص الذكاء الاصطناعي","Résumé IA","AI ডাইজেস্ট","AI डाइजेस्ट","ИИ-дайджест","ШІ-дайджест"],
"No news to summarize.": ["No hay noticias que resumir.","没有可摘要的新闻。","لا توجد أخبار لتلخيصها.","Aucune actualité à résumer.","সারাংশ করার মতো খবর নেই।","सारांश के लिए कोई खबर नहीं है।","Нет новостей для сводки.","Немає новин для зведення."],
"General market": ["Mercado en general","整体市场","السوق عموماً","Marché en général","সাধারণ বাজার","सामान्य बाज़ार","Рынок в целом","Ринок загалом"],
"Top %lld headlines": ["Los %lld titulares principales","头条新闻 %lld 条","أبرز %lld عناوين","Les %lld principaux titres","শীর্ষ %lld শিরোনাম","शीर्ष %lld हेडलाइन","Главные заголовки: %lld","Головні заголовки: %lld"],
"%1$@: %2$@": ["%1$@: %2$@"]*8,
"All news": ["Todas las noticias","全部新闻","كل الأخبار","Toutes les actualités","সব খবর","सभी खबरें","Все новости","Усі новини"],
"Ask AI": ["Preguntar a la IA","询问 AI","اسأل الذكاء الاصطناعي","Demander à l’IA","AI-কে জিজ্ঞাসা করুন","AI से पूछें","Спросить ИИ","Запитати ШІ"],
"AI assistant": ["Asistente de IA","AI 助手","مساعد الذكاء الاصطناعي","Assistant IA","AI সহকারী","AI सहायक","ИИ-помощник","ШІ-помічник"],
"Brief": ["Resumen","简报","الملخص","Brief","সংক্ষেপ","संक्षेप","Сводка","Зведення"],
"Chat": ["Chat","聊天","الدردشة","Chat","চ্যাট","चैट","Чат","Чат"],
"Ask about markets, a stock, or your portfolio…": ["Pregunta sobre mercados, un valor o tu cartera…","询问市场、个股或您的投资组合…","اسأل عن الأسواق أو سهم أو محفظتك…","Posez une question sur les marchés, une action ou votre portefeuille…","বাজার, কোনো শেয়ার বা আপনার পোর্টফোলিও সম্পর্কে জিজ্ঞাসা করুন…","बाज़ार, किसी शेयर या अपने पोर्टफ़ोलियो के बारे में पूछें…","Спросите о рынках, акции или вашем портфеле…","Запитайте про ринки, акцію чи ваш портфель…"],
"Send": ["Enviar","发送","إرسال","Envoyer","পাঠান","भेजें","Отправить","Надіслати"],
"New chat": ["Nuevo chat","新对话","محادثة جديدة","Nouvelle discussion","নতুন চ্যাট","नई चैट","Новый чат","Новий чат"],
"Suggested questions": ["Preguntas sugeridas","推荐问题","أسئلة مقترحة","Questions suggérées","প্রস্তাবিত প্রশ্ন","सुझाए गए प्रश्न","Предложенные вопросы","Запропоновані запитання"],
"Quick answers": ["Respuestas rápidas","快速回答","إجابات سريعة","Réponses rapides","দ্রুত উত্তর","त्वरित उत्तर","Быстрые ответы","Швидкі відповіді"],
"Full chat needs Apple Intelligence on a supported device, turned on, in a supported language. Quick answers below are built from live app data.": ["El chat completo requiere Apple Intelligence en un dispositivo compatible, activado y en un idioma compatible. Las respuestas rápidas de abajo se generan con datos en vivo de la app.","完整聊天需要在受支持的设备上开启 Apple 智能，并使用受支持的语言。下面的快速回答由应用的实时数据生成。","تتطلب الدردشة الكاملة ميزة Apple Intelligence على جهاز مدعوم، وأن تكون مفعّلة وبلغة مدعومة. الإجابات السريعة أدناه مبنية على بيانات التطبيق المباشرة.","Le chat complet nécessite Apple Intelligence sur un appareil compatible, activé et dans une langue prise en charge. Les réponses rapides ci-dessous sont construites à partir des données en direct de l’app.","পূর্ণ চ্যাটের জন্য সমর্থিত ডিভাইসে, চালু করা এবং সমর্থিত ভাষায় Apple Intelligence দরকার। নিচের দ্রুত উত্তরগুলো অ্যাপের লাইভ ডেটা থেকে তৈরি।","पूरी चैट के लिए समर्थित डिवाइस पर, चालू और समर्थित भाषा में Apple Intelligence ज़रूरी है। नीचे के त्वरित उत्तर ऐप के लाइव डेटा से बने हैं।","Для полного чата нужен Apple Intelligence на поддерживаемом устройстве, включённый и на поддерживаемом языке. Быстрые ответы ниже собраны из живых данных приложения.","Для повного чату потрібен Apple Intelligence на підтримуваному пристрої, увімкнений і підтримуваною мовою. Швидкі відповіді нижче зібрано з живих даних застосунку."],
"Looking up data…": ["Buscando datos…","正在查询数据…","جارٍ البحث عن البيانات…","Recherche des données…","ডেটা খোঁজা হচ্ছে…","डेटा खोजा जा रहा है…","Ищу данные…","Шукаю дані…"],
"The on-device model couldn't answer. Try rephrasing, or use a quick answer.": ["El modelo del dispositivo no pudo responder. Reformula la pregunta o usa una respuesta rápida.","设备端模型无法回答。请换种说法，或使用快速回答。","تعذّر على النموذج الموجود على الجهاز الإجابة. أعد صياغة السؤال أو استخدم إجابة سريعة.","Le modèle sur l’appareil n’a pas pu répondre. Reformulez ou utilisez une réponse rapide.","ডিভাইসের মডেল উত্তর দিতে পারেনি। প্রশ্নটি অন্যভাবে লিখুন বা দ্রুত উত্তর ব্যবহার করুন।","डिवाइस का मॉडल उत्तर नहीं दे सका। प्रश्न दूसरे शब्दों में पूछें या त्वरित उत्तर इस्तेमाल करें।","Модель на устройстве не смогла ответить. Переформулируйте вопрос или используйте быстрый ответ.","Модель на пристрої не змогла відповісти. Переформулюйте запитання або скористайтеся швидкою відповіддю."],
"Why is the market down today?": ["¿Por qué baja hoy el mercado?","今天市场为什么下跌？","لماذا ينخفض السوق اليوم؟","Pourquoi le marché baisse-t-il aujourd’hui ?","আজ বাজার কেন পড়ছে?","आज बाज़ार क्यों गिर रहा है?","Почему сегодня падает рынок?","Чому сьогодні падає ринок?"],
"Compare %1$@ and %2$@": ["Compara %1$@ y %2$@","比较 %1$@ 和 %2$@","قارن بين %1$@ و%2$@","Compare %1$@ et %2$@","%1$@ ও %2$@ তুলনা করুন","%1$@ और %2$@ की तुलना करें","Сравни %1$@ и %2$@","Порівняй %1$@ і %2$@"],
"Best dividend stocks in %@": ["Mejores acciones con dividendo en %@","%@ 中股息最高的股票","أفضل أسهم التوزيعات في %@","Meilleures actions à dividende dans %@","%@-এ সেরা লভ্যাংশের শেয়ার","%@ में सबसे अच्छे लाभांश वाले शेयर","Лучшие дивидендные акции в %@","Найкращі дивідендні акції в %@"],
"How is my portfolio doing?": ["¿Cómo va mi cartera?","我的投资组合表现如何？","كيف أداء محفظتي؟","Comment va mon portefeuille ?","আমার পোর্টফোলিও কেমন চলছে?","मेरा पोर्टफ़ोलियो कैसा चल रहा है?","Как дела у моего портфеля?","Як справи в мого портфеля?"],
"Why is %@ moving today?": ["¿Por qué se mueve %@ hoy?","%@ 今天为什么波动？","لماذا يتحرك %@ اليوم؟","Pourquoi %@ bouge-t-il aujourd’hui ?","আজ %@ কেন নড়ছে?","आज %@ में हलचल क्यों है?","Почему сегодня движется %@?","Чому сьогодні рухається %@?"],
"No price data available for %@.": ["No hay datos de precio para %@.","%@ 暂无价格数据。","لا تتوفر بيانات سعر لـ %@.","Aucune donnée de prix pour %@.","%@-এর জন্য মূল্যের তথ্য নেই।","%@ के लिए मूल्य डेटा उपलब्ध नहीं है।","Нет данных о цене для %@.","Немає даних про ціну для %@."],
"%1$@: %2$@ today, %3$@ over 1 month, %4$@ year to date.": ["%1$@: %2$@ hoy, %3$@ en 1 mes, %4$@ en lo que va de año.","%1$@：今日 %2$@，1 个月 %3$@，年初至今 %4$@。","%1$@: %2$@ اليوم، %3$@ خلال شهر، %4$@ منذ بداية العام.","%1$@ : %2$@ aujourd’hui, %3$@ sur 1 mois, %4$@ depuis le début de l’année.","%1$@: আজ %2$@, ১ মাসে %3$@, বছরের শুরু থেকে %4$@।","%1$@: आज %2$@, 1 महीने में %3$@, वर्ष की शुरुआत से %4$@।","%1$@: сегодня %2$@, за месяц %3$@, с начала года %4$@.","%1$@: сьогодні %2$@, за місяць %3$@, з початку року %4$@."],
"%1$@ — P/E %2$@, dividend yield %3$@.": ["%1$@ — PER %2$@, rentabilidad por dividendo %3$@.","%1$@ — 市盈率 %2$@，股息率 %3$@。","%1$@ — مكرر الربحية %2$@، عائد التوزيعات %3$@.","%1$@ — PER %2$@, rendement du dividende %3$@.","%1$@ — P/E %2$@, লভ্যাংশ প্রতিদান %3$@।","%1$@ — P/E %2$@, लाभांश प्रतिफल %3$@।","%1$@ — P/E %2$@, дивидендная доходность %3$@.","%1$@ — P/E %2$@, дивідендна дохідність %3$@."],
"Stronger over 1 month: %1$@ (%2$@ vs %3$@).": ["Más fuerte en 1 mes: %1$@ (%2$@ frente a %3$@).","1 个月表现更强：%1$@（%2$@ 对 %3$@）。","الأقوى خلال شهر: %1$@ (%2$@ مقابل %3$@).","Plus forte sur 1 mois : %1$@ (%2$@ contre %3$@).","১ মাসে এগিয়ে: %1$@ (%2$@ বনাম %3$@)।","1 महीने में आगे: %1$@ (%2$@ बनाम %3$@)।","Сильнее за месяц: %1$@ (%2$@ против %3$@).","Сильніше за місяць: %1$@ (%2$@ проти %3$@)."],
"The screener returned no stocks right now.": ["El filtro no devolvió ninguna acción ahora mismo.","筛选器目前没有返回任何股票。","لم يُرجع الفلتر أي أسهم الآن.","Le filtre n’a renvoyé aucune action pour le moment.","স্ক্রিনার এখন কোনো শেয়ার দেখায়নি।","स्क्रीनर ने अभी कोई शेयर नहीं दिया।","Скринер сейчас не вернул ни одной акции.","Скринер зараз не повернув жодної акції."],
"Highest dividend yields in %@:": ["Mayores rentabilidades por dividendo en %@:","%@ 中股息率最高的股票：","أعلى عوائد التوزيعات في %@:","Rendements de dividende les plus élevés dans %@ :","%@-এ সর্বোচ্চ লভ্যাংশ প্রতিদান:","%@ में सबसे ऊँचा लाभांश प्रतिफल:","Самая высокая дивидендная доходность в %@:","Найвища дивідендна дохідність у %@:"],
"%1$@ (%2$@): dividend yield %3$@, P/E %4$@": ["%1$@ (%2$@): rentabilidad por dividendo %3$@, PER %4$@","%1$@（%2$@）：股息率 %3$@，市盈率 %4$@","%1$@ (%2$@): عائد التوزيعات %3$@، مكرر الربحية %4$@","%1$@ (%2$@) : rendement du dividende %3$@, PER %4$@","%1$@ (%2$@): লভ্যাংশ প্রতিদান %3$@, P/E %4$@","%1$@ (%2$@): लाभांश प्रतिफल %3$@, P/E %4$@","%1$@ (%2$@): дивидендная доходность %3$@, P/E %4$@","%1$@ (%2$@): дивідендна дохідність %3$@, P/E %4$@"],
"%1$@ (%2$@): dividend yield %3$@": ["%1$@ (%2$@): rentabilidad por dividendo %3$@","%1$@（%2$@）：股息率 %3$@","%1$@ (%2$@): عائد التوزيعات %3$@","%1$@ (%2$@) : rendement du dividende %3$@","%1$@ (%2$@): লভ্যাংশ প্রতিদান %3$@","%1$@ (%2$@): लाभांश प्रतिफल %3$@","%1$@ (%2$@): дивидендная доходность %3$@","%1$@ (%2$@): дивідендна дохідність %3$@"],
"Add transactions in the Portfolio tab first, then I can summarize it.": ["Primero añade operaciones en la pestaña Cartera y después podré resumirla.","请先在“投资组合”标签中添加交易，之后我才能为您总结。","أضف عمليات في تبويب المحفظة أولاً، ثم يمكنني تلخيصها.","Ajoutez d’abord des opérations dans l’onglet Portefeuille, puis je pourrai le résumer.","আগে পোর্টফোলিও ট্যাবে লেনদেন যোগ করুন, তারপর আমি সারাংশ দিতে পারব।","पहले पोर्टफ़ोलियो टैब में लेन-देन जोड़ें, फिर मैं सारांश दे सकूँगा।","Сначала добавьте сделки на вкладке «Портфель», тогда я смогу сделать сводку.","Спершу додайте угоди на вкладці «Портфель», тоді я зможу зробити зведення."],
}

def main():
    raw = open(PATH).read()
    strings = json.loads(raw)["strings"]
    chunks = []
    for key, tr in T.items():
        assert len(tr) == 8, key
        if key in strings:
            continue
        loc = {"en": {"stringUnit": {"state": "translated", "value": key}}}
        for lang, val in zip(LANGS[1:], tr):
            loc[lang] = {"stringUnit": {"state": "translated", "value": val}}
        entry = {"extractionState": "manual", "localizations": loc}
        body = json.dumps({key: entry}, ensure_ascii=False, indent=2)
        inner = body.split("\n")[1:-1]
        chunks.append("\n".join("  " + line for line in inner))
    if chunks:
        marker = "\n  },\n  \"version\""
        at = raw.rindex(marker)
        raw = raw[:at] + ",\n" + ",\n".join(chunks) + raw[at:]
        json.loads(raw)
        open(PATH, "w").write(raw)
    print("added", len(chunks))

if __name__ == "__main__":
    main()
