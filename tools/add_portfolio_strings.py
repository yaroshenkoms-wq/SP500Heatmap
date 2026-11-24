#!/usr/bin/env python3
"""Adds the personal-portfolio strings (9 languages) to Localizable.xcstrings. Safe to re-run: existing keys are kept."""
import json, os
PATH = os.path.join(os.path.dirname(__file__), "..", "SP500Heatmap", "SP500Heatmap", "Localizable.xcstrings")
LANGS = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]

T = {
"Add buys, sells and dividends to see value, profit, allocation and performance against an index.": [
 "Añade compras, ventas y dividendos para ver valor, beneficio, distribución y rentabilidad frente a un índice.",
 "添加买入、卖出和股息，即可查看市值、收益、配置以及相对指数的表现。",
 "أضف عمليات الشراء والبيع والأرباح لعرض القيمة والربح والتوزيع والأداء مقابل مؤشر.",
 "Ajoutez achats, ventes et dividendes pour voir la valeur, le gain, la répartition et la performance face à un indice.",
 "মূল্য, লাভ, বণ্টন এবং সূচকের তুলনায় পারফরম্যান্স দেখতে ক্রয়, বিক্রয় ও লভ্যাংশ যোগ করুন।",
 "मूल्य, लाभ, आवंटन और इंडेक्स के मुकाबले प्रदर्शन देखने के लिए खरीद, बिक्री और लाभांश जोड़ें।",
 "Добавьте покупки, продажи и дивиденды, чтобы увидеть стоимость, прибыль, структуру и доходность в сравнении с индексом.",
 "Додайте купівлі, продажі та дивіденди, щоб побачити вартість, прибуток, структуру й дохідність порівняно з індексом."],
"Add transaction": ["Añadir operación","添加交易","إضافة عملية","Ajouter une opération","লেনদেন যোগ করুন","लेन-देन जोड़ें","Добавить сделку","Додати угоду"],
"Edit transaction": ["Editar operación","编辑交易","تعديل العملية","Modifier l’opération","লেনদেন সম্পাদনা","लेन-देन संपादित करें","Изменить сделку","Змінити угоду"],
"Add your first buy, or import a CSV file (date,type,ticker,quantity,price,currency,fee).": [
 "Añade tu primera compra o importa un archivo CSV (date,type,ticker,quantity,price,currency,fee).",
 "添加第一笔买入，或导入 CSV 文件（date,type,ticker,quantity,price,currency,fee）。",
 "أضف أول عملية شراء أو استورد ملف CSV (date,type,ticker,quantity,price,currency,fee).",
 "Ajoutez votre premier achat ou importez un fichier CSV (date,type,ticker,quantity,price,currency,fee).",
 "প্রথম ক্রয় যোগ করুন বা CSV ফাইল আমদানি করুন (date,type,ticker,quantity,price,currency,fee)।",
 "अपनी पहली खरीद जोड़ें या CSV फ़ाइल आयात करें (date,type,ticker,quantity,price,currency,fee)।",
 "Добавьте первую покупку или импортируйте файл CSV (date,type,ticker,quantity,price,currency,fee).",
 "Додайте першу купівлю або імпортуйте файл CSV (date,type,ticker,quantity,price,currency,fee)."],
"All": ["Todo","全部","الكل","Tout","সব","सभी","Всё","Усе"],
"Avg cost": ["Coste medio","平均成本","متوسط التكلفة","Coût moyen","গড় খরচ","औसत लागत","Ср. цена","Сер. ціна"],
"Base currency": ["Moneda base","基础货币","العملة الأساسية","Devise de base","মূল মুদ্রা","आधार मुद्रा","Базовая валюта","Базова валюта"],
"Base currency can be changed later in the portfolio menu.": [
 "La moneda base se puede cambiar después en el menú de la cartera.","基础货币稍后可在投资组合菜单中更改。","يمكن تغيير العملة الأساسية لاحقًا من قائمة المحفظة.",
 "La devise de base peut être modifiée plus tard dans le menu du portefeuille.","মূল মুদ্রা পরে পোর্টফোলিও মেনু থেকে বদলানো যাবে।","आधार मुद्रा बाद में पोर्टफ़ोलियो मेनू में बदली जा सकती है।",
 "Базовую валюту можно изменить позже в меню портфеля.","Базову валюту можна змінити пізніше в меню портфеля."],
"Buy": ["Compra","买入","شراء","Achat","ক্রয়","खरीद","Покупка","Купівля"],
"Choose a ticker": ["Elige un valor","选择股票代码","اختر رمزًا","Choisir un titre","টিকার বেছে নিন","टिकर चुनें","Выберите тикер","Оберіть тікер"],
"Choose a ticker.": ["Elige un valor.","请选择股票代码。","اختر رمزًا.","Choisissez un titre.","একটি টিকার বেছে নিন।","एक टिकर चुनें।","Выберите тикер.","Оберіть тікер."],
"Could not read the file.": ["No se pudo leer el archivo.","无法读取该文件。","تعذّرت قراءة الملف.","Impossible de lire le fichier.","ফাইলটি পড়া যায়নি।","फ़ाइल पढ़ी नहीं जा सकी।","Не удалось прочитать файл.","Не вдалося прочитати файл."],
"Country": ["País","国家","الدولة","Pays","দেশ","देश","Страна","Країна"],
"Create portfolio": ["Crear cartera","创建投资组合","إنشاء محفظة","Créer un portefeuille","পোর্টফোলিও তৈরি করুন","पोर्टफ़ोलियो बनाएँ","Создать портфель","Створити портфель"],
"Currency": ["Moneda","货币","العملة","Devise","মুদ্রা","मुद्रा","Валюта","Валюта"],
"Delete portfolio": ["Eliminar cartera","删除投资组合","حذف المحفظة","Supprimer le portefeuille","পোর্টফোলিও মুছুন","पोर्टफ़ोलियो हटाएँ","Удалить портфель","Видалити портфель"],
"Delete this portfolio?": ["¿Eliminar esta cartera?","删除此投资组合？","حذف هذه المحفظة؟","Supprimer ce portefeuille ?","এই পোর্টফোলিও মুছবেন?","यह पोर्टफ़ोलियो हटाएँ?","Удалить этот портфель?","Видалити цей портфель?"],
"Delete this transaction?": ["¿Eliminar esta operación?","删除此交易？","حذف هذه العملية؟","Supprimer cette opération ?","এই লেনদেন মুছবেন?","यह लेन-देन हटाएँ?","Удалить эту сделку?","Видалити цю угоду?"],
"Delete transaction": ["Eliminar operación","删除交易","حذف العملية","Supprimer l’opération","লেনদেন মুছুন","लेन-देन हटाएँ","Удалить сделку","Видалити угоду"],
"Dividend": ["Dividendo","股息","أرباح","Dividende","লভ্যাংশ","लाभांश","Дивиденд","Дивіденд"],
"Dividends received": ["Dividendos cobrados","已收股息","الأرباح المستلمة","Dividendes perçus","প্রাপ্ত লভ্যাংশ","प्राप्त लाभांश","Получено дивидендов","Отримано дивідендів"],
"Enter a price.": ["Introduce un precio.","请输入价格。","أدخل السعر.","Saisissez un prix.","একটি দাম লিখুন।","मूल्य दर्ज करें।","Введите цену.","Введіть ціну."],
"Enter a quantity above zero.": ["Introduce una cantidad mayor que cero.","请输入大于零的数量。","أدخل كمية أكبر من صفر.","Saisissez une quantité supérieure à zéro.","শূন্যের বেশি একটি পরিমাণ লিখুন।","शून्य से अधिक मात्रा दर्ज करें।","Введите количество больше нуля.","Введіть кількість більше нуля."],
"Expected dividends per year": ["Dividendos previstos al año","预计年股息","الأرباح المتوقعة سنويًا","Dividendes attendus par an","বার্ষিক প্রত্যাশিত লভ্যাংশ","अपेक्षित वार्षिक लाभांश","Ожидаемые дивиденды в год","Очікувані дивіденди на рік"],
"Export CSV": ["Exportar CSV","导出 CSV","تصدير CSV","Exporter en CSV","CSV রপ্তানি","CSV निर्यात करें","Экспорт CSV","Експорт CSV"],
"Fee": ["Comisión","手续费","العمولة","Frais","ফি","शुल्क","Комиссия","Комісія"],
"Fee must be a number.": ["La comisión debe ser un número.","手续费必须是数字。","يجب أن تكون العمولة رقمًا.","Les frais doivent être un nombre.","ফি একটি সংখ্যা হতে হবে।","शुल्क एक संख्या होनी चाहिए।","Комиссия должна быть числом.","Комісія має бути числом."],
"Holdings": ["Posiciones","持仓","المراكز","Positions","পজিশন","होल्डिंग्स","Позиции","Позиції"],
"Holdings map": ["Mapa de posiciones","持仓地图","خريطة المراكز","Carte des positions","পজিশন মানচিত্র","होल्डिंग्स मैप","Карта позиций","Карта позицій"],
"Import CSV": ["Importar CSV","导入 CSV","استيراد CSV","Importer un CSV","CSV আমদানি","CSV आयात करें","Импорт CSV","Імпорт CSV"],
"Imported %lld transactions, skipped %lld lines.": [
 "Importadas %lld operaciones, omitidas %lld líneas.","已导入 %lld 笔交易，跳过 %lld 行。","تم استيراد %lld عملية وتخطي %lld سطرًا.","%lld opérations importées, %lld lignes ignorées.",
 "%lld লেনদেন আমদানি হয়েছে, %lld লাইন বাদ গেছে।","%lld लेन-देन आयात हुए, %lld पंक्तियाँ छोड़ी गईं।","Импортировано сделок: %lld, пропущено строк: %lld.","Імпортовано угод: %lld, пропущено рядків: %lld."],
"Index history is not available from the server yet; showing the portfolio only.": [
 "El historial del índice aún no está disponible en el servidor; se muestra solo la cartera.","服务器暂无指数历史数据，仅显示投资组合。","سجل المؤشر غير متاح من الخادم بعد؛ يُعرض أداء المحفظة فقط.",
 "L’historique de l’indice n’est pas encore disponible sur le serveur ; seul le portefeuille est affiché.","সূচকের ইতিহাস এখনও সার্ভারে নেই; শুধু পোর্টফোলিও দেখানো হচ্ছে।","इंडेक्स का इतिहास अभी सर्वर पर उपलब्ध नहीं है; केवल पोर्टफ़ोलियो दिखाया गया है।",
 "История индекса пока недоступна на сервере; показан только портфель.","Історія індексу поки недоступна на сервері; показано лише портфель."],
"Invested": ["Invertido","已投入","المبلغ المستثمر","Investi","বিনিয়োগ","निवेशित","Вложено","Вкладено"],
"Last": ["Último","最新价","الأخير","Dernier","সর্বশেষ","अंतिम","Цена","Ціна"],
"Loading companies…": ["Cargando empresas…","正在加载公司…","جارٍ تحميل الشركات…","Chargement des sociétés…","কোম্পানি লোড হচ্ছে…","कंपनियाँ लोड हो रही हैं…","Загрузка компаний…","Завантаження компаній…"],
"Looking up the price for that date…": ["Buscando el precio de esa fecha…","正在查询该日期的价格…","جارٍ البحث عن سعر ذلك اليوم…","Recherche du cours à cette date…","ওই তারিখের দাম খোঁজা হচ্ছে…","उस तारीख का मूल्य खोजा जा रहा है…","Ищем цену на эту дату…","Шукаємо ціну на цю дату…"],
"Market value": ["Valor de mercado","市值","القيمة السوقية","Valeur de marché","বাজারমূল্য","बाज़ार मूल्य","Рыночная стоимость","Ринкова вартість"],
"More": ["Más","更多","المزيد","Plus","আরও","अधिक","Ещё","Ще"],
"My portfolio": ["Mi cartera","我的投资组合","محفظتي","Mon portefeuille","আমার পোর্টফোলিও","मेरा पोर्टफ़ोलियो","Мой портфель","Мій портфель"],
"New portfolio": ["Nueva cartera","新建投资组合","محفظة جديدة","Nouveau portefeuille","নতুন পোর্টফোলিও","नया पोर्टफ़ोलियो","Новый портфель","Новий портфель"],
"No data yet.": ["Aún no hay datos.","暂无数据。","لا توجد بيانات بعد.","Pas encore de données.","এখনও কোনো তথ্য নেই।","अभी कोई डेटा नहीं।","Данных пока нет.","Даних поки немає."],
"No open positions.": ["No hay posiciones abiertas.","没有未平仓持仓。","لا توجد مراكز مفتوحة.","Aucune position ouverte.","কোনো খোলা পজিশন নেই।","कोई खुली होल्डिंग नहीं।","Открытых позиций нет.","Відкритих позицій немає."],
"No price for %lld holdings yet.": ["Aún no hay precio para %lld posiciones.","%lld 个持仓暂无价格。","لا يوجد سعر لـ %lld مراكز بعد.","Pas encore de cours pour %lld positions.","%lld টি পজিশনের দাম এখনও নেই।","%lld होल्डिंग्स का मूल्य अभी उपलब्ध नहीं।","Пока нет цены для позиций: %lld.","Поки немає ціни для позицій: %lld."],
"No transactions yet": ["Aún no hay operaciones","暂无交易","لا توجد عمليات بعد","Aucune opération pour l’instant","এখনও কোনো লেনদেন নেই","अभी कोई लेन-देन नहीं","Сделок пока нет","Угод поки немає"],
"Not enough price history yet.": ["Aún no hay suficiente historial de precios.","价格历史数据尚不足。","لا يوجد سجل أسعار كافٍ بعد.","Historique de cours encore insuffisant.","দামের ইতিহাস এখনও যথেষ্ট নয়।","अभी पर्याप्त मूल्य इतिहास नहीं है।","Истории цен пока недостаточно.","Історії цін поки недостатньо."],
"OK": ["Aceptar","好","موافق","OK","ঠিক আছে","ठीक है","ОК","ОК"],
"Portfolio name": ["Nombre de la cartera","投资组合名称","اسم المحفظة","Nom du portefeuille","পোর্টফোলিওর নাম","पोर्टफ़ोलियो का नाम","Название портфеля","Назва портфеля"],
"Prices are daily closes and may be delayed. Currency conversion uses daily exchange rates. Not investment advice.": [
 "Los precios son cierres diarios y pueden tener retraso. La conversión de divisas usa tipos de cambio diarios. No es asesoramiento de inversión.",
 "价格为每日收盘价，可能有延迟。货币换算使用每日汇率。不构成投资建议。",
 "الأسعار هي إغلاقات يومية وقد تتأخر. يستخدم تحويل العملات أسعار صرف يومية. ليست نصيحة استثمارية.",
 "Les cours sont des clôtures quotidiennes et peuvent être différés. La conversion utilise les taux de change quotidiens. Ne constitue pas un conseil en investissement.",
 "দাম প্রতিদিনের সমাপনী মূল্য এবং দেরিতে আসতে পারে। মুদ্রা রূপান্তরে দৈনিক বিনিময় হার ব্যবহৃত হয়। এটি বিনিয়োগ পরামর্শ নয়।",
 "मूल्य दैनिक समापन भाव हैं और देरी से आ सकते हैं। मुद्रा रूपांतरण दैनिक विनिमय दरों पर आधारित है। यह निवेश सलाह नहीं है।",
 "Цены — дневные закрытия, возможна задержка. Пересчёт валют идёт по дневным курсам. Не является инвестиционной рекомендацией.",
 "Ціни — денні закриття, можлива затримка. Перерахунок валют ідеться за денними курсами. Не є інвестиційною порадою."],
"Qty": ["Cant.","数量","الكمية","Qté","পরিমাণ","मात्रा","Кол-во","К-сть"],
"Quantity": ["Cantidad","数量","الكمية","Quantité","পরিমাণ","मात्रा","Количество","Кількість"],
"Realized": ["Realizado","已实现","المحقق","Réalisé","বাস্তবায়িত","प्राप्त","Зафиксировано","Зафіксовано"],
"Rename": ["Renombrar","重命名","إعادة تسمية","Renommer","নাম বদলান","नाम बदलें","Переименовать","Перейменувати"],
"Rename portfolio": ["Renombrar cartera","重命名投资组合","إعادة تسمية المحفظة","Renommer le portefeuille","পোর্টফোলিওর নাম বদলান","पोर्टफ़ोलियो का नाम बदलें","Переименовать портфель","Перейменувати портфель"],
"Sector": ["Sector","行业","القطاع","Secteur","খাত","सेक्टर","Сектор","Сектор"],
"Sell": ["Venta","卖出","بيع","Vente","বিক্রয়","बिक्री","Продажа","Продаж"],
"Some exchange rates are missing; amounts in other currencies are shown unconverted.": [
 "Faltan algunos tipos de cambio; los importes en otras divisas se muestran sin convertir.","缺少部分汇率；其他货币的金额按原值显示。","بعض أسعار الصرف مفقودة؛ تُعرض المبالغ بالعملات الأخرى دون تحويل.",
 "Certains taux de change manquent ; les montants en autres devises sont affichés sans conversion.","কিছু বিনিময় হার নেই; অন্য মুদ্রার অঙ্ক রূপান্তর ছাড়াই দেখানো হচ্ছে।","कुछ विनिमय दरें उपलब्ध नहीं; अन्य मुद्राओं की राशियाँ बिना रूपांतरण दिखाई गई हैं।",
 "Не хватает некоторых курсов валют; суммы в других валютах показаны без пересчёта.","Бракує деяких курсів валют; суми в інших валютах показано без перерахунку."],
"The price is filled from the daily close of that date; you can change it.": [
 "El precio se rellena con el cierre diario de esa fecha; puedes cambiarlo.","价格取自该日期的收盘价，可以修改。","يُملأ السعر من إغلاق ذلك اليوم؛ يمكنك تغييره.",
 "Le cours est prérempli avec la clôture de cette date ; vous pouvez le modifier.","দাম ওই তারিখের সমাপনী মূল্য থেকে ভরা হয়; আপনি বদলাতে পারেন।","मूल्य उस तारीख के समापन भाव से भरा जाता है; आप इसे बदल सकते हैं।",
 "Цена подставляется по закрытию этого дня; её можно изменить.","Ціна підставляється за закриттям цього дня; її можна змінити."],
"This portfolio is too large for iCloud sync and is kept on this device only.": [
 "Esta cartera es demasiado grande para iCloud y se guarda solo en este dispositivo.","此投资组合过大，无法通过 iCloud 同步，仅保存在本设备。","هذه المحفظة أكبر من أن تُزامن عبر iCloud وتبقى على هذا الجهاز فقط.",
 "Ce portefeuille est trop volumineux pour iCloud et reste uniquement sur cet appareil.","এই পোর্টফোলিও iCloud সিঙ্কের জন্য খুব বড়; এটি শুধু এই ডিভাইসে থাকবে।","यह पोर्टफ़ोलियो iCloud सिंक के लिए बहुत बड़ा है और केवल इसी डिवाइस पर रहेगा।",
 "Портфель слишком большой для iCloud и хранится только на этом устройстве.","Портфель завеликий для iCloud і зберігається лише на цьому пристрої."],
"Ticker": ["Valor","股票代码","الرمز","Titre","টিকার","टिकर","Тикер","Тікер"],
"Today": ["Hoy","今日","اليوم","Aujourd’hui","আজ","आज","Сегодня","Сьогодні"],
"today": ["hoy","今日","اليوم","aujourd’hui","আজ","आज","сегодня","сьогодні"],
"Total P/L": ["Total G/P","总盈亏","إجمالي الربح/الخسارة","Total G/P","মোট লাভ/ক্ষতি","कुल लाभ/हानि","Итого П/У","Разом П/З"],
"Total profit / loss": ["Beneficio / pérdida total","总盈亏","إجمالي الربح / الخسارة","Gain / perte total","মোট লাভ / ক্ষতি","कुल लाभ / हानि","Итоговая прибыль / убыток","Загальний прибуток / збиток"],
"Track your own portfolio": ["Sigue tu propia cartera","跟踪你自己的投资组合","تابع محفظتك الخاصة","Suivez votre propre portefeuille","নিজের পোর্টফোলিও ট্র্যাক করুন","अपना पोर्टफ़ोलियो ट्रैक करें","Следите за своим портфелем","Стежте за власним портфелем"],
"Transactions": ["Operaciones","交易","العمليات","Opérations","লেনদেন","लेन-देन","Сделки","Угоди"],
"Type": ["Tipo","类型","النوع","Type","ধরন","प्रकार","Тип","Тип"],
"Unknown": ["Desconocido","未知","غير معروف","Inconnu","অজানা","अज्ञात","Неизвестно","Невідомо"],
"Unrealized": ["No realizado","未实现","غير المحقق","Non réalisé","অবাস্তবায়িত","अप्राप्त","Не зафиксировано","Не зафіксовано"],
"Use \"%@\" as typed": ["Usar «%@» tal como está","按输入使用“%@”","استخدم «%@» كما كُتب","Utiliser « %@ » tel quel","“%@” যেমন লেখা তেমনই ব্যবহার করুন","“%@” को जैसा लिखा है वैसा उपयोग करें","Использовать «%@» как введено","Використати «%@» як введено"],
"Weight": ["Peso","权重","الوزن","Poids","ওজন","भार","Доля","Частка"],
"You only held %@ on that date.": ["Ese día solo tenías %@.","当天你只持有 %@。","كنت تملك %@ فقط في ذلك اليوم.","Vous déteniez seulement %@ à cette date.","ওই তারিখে আপনার কাছে শুধু %@ ছিল।","उस तारीख को आपके पास केवल %@ थे।","На эту дату у вас было только %@.","На цю дату у вас було лише %@."],
"vs": ["vs","对比","مقابل","vs","বনাম","बनाम","vs","vs"],
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
        inner = body.split("\n")[1:-1]          # drop the outer braces
        chunks.append("\n".join("  " + line for line in inner))
    if chunks:
        # Text insertion keeps the file diff small: new entries go right before the end of "strings".
        marker = "\n  },\n  \"version\""
        at = raw.rindex(marker)
        raw = raw[:at] + ",\n" + ",\n".join(chunks) + raw[at:]
        json.loads(raw)
        open(PATH, "w").write(raw)
    print("added", len(chunks))

if __name__ == "__main__":
    main()
