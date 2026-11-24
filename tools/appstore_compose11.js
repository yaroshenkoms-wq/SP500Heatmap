#!/usr/bin/env node
// Накладывает подпись на скриншот симулятора: чёрный фон с золотым свечением, serif-заголовок, снимок в рамке.
// node tools/appstore_compose11.js <iphone|ipad> <locale> <name> <raw.png> <out.png>
// playwright-core берётся из NODE_PATH. Шрифт Instrument Serif — из PlanEditor (data-URI в plan_editor.html).
const fs = require('fs'), path = require('path'), cp = require('child_process');
const { chromium } = require('playwright-core');
const { CAP, LOCALES } = require('./appstore_caps11.js');
const [dev, loc, name, raw, out] = process.argv.slice(2);
const [W, H] = { iphone: [1206, 2622], ipad: [2064, 2752] }[dev];
const cap = (CAP[loc] || {})[name];
if (!cap) { console.error('нет подписи', loc, name); process.exit(1); }
const peHtml = process.env.PE_HTML || path.join(process.env.HOME, 'Desktop/App/PlanEditor/PlanEditor/plan_editor.html');
const fonts = (fs.readFileSync(peHtml, 'utf8').match(/@font-face\s*\{[^}]*Instrument Serif[^}]*\}/g) || []).join('\n');
const rtl = loc.startsWith('ar'), phone = dev === 'iphone';
const shotW = Math.round(W * (phone ? 0.80 : 0.78)), top = Math.round(H * (phone ? 0.205 : 0.17));
const page = `<!doctype html><meta charset="utf-8"><style>${fonts}
*{margin:0;box-sizing:border-box}html,body{width:${W}px;height:${H}px;overflow:hidden;background:#0B0A0D}
body{position:relative;font-family:'Instrument Serif','Georgia','Times New Roman','Songti SC','Hiragino Mincho ProN','AppleMyungjo','Geeza Pro',serif;color:#F4EFE6;
 background:radial-gradient(ellipse 80% 40% at 50% 0%,rgba(201,169,110,.20),rgba(201,169,110,0) 70%),#0B0A0D}
.cap{direction:${rtl ? 'rtl' : 'ltr'};position:absolute;left:0;right:0;top:${Math.round(H * (phone ? 0.04 : 0.032))}px;text-align:center;font-size:${phone ? 104 : 116}px;line-height:1.1;font-weight:400;letter-spacing:-.01em}
.cap b{font-weight:400;color:#C9A96E}
.rule{position:absolute;left:50%;width:120px;height:3px;margin-left:-60px;top:${top - (phone ? 40 : 34)}px;background:#C9A96E}
.shot{position:absolute;left:${Math.round((W - shotW) / 2)}px;top:${top}px;width:${shotW}px;border-radius:${phone ? '70px 70px 0 0' : '48px'};border:3px solid rgba(201,169,110,.55);${phone ? 'border-bottom:0;' : ''}box-shadow:0 0 90px rgba(201,169,110,.18);display:block}
</style><div class="cap">${cap[0]}<br><b>${cap[1]}</b></div><div class="rule"></div>
<img class="shot" src="data:image/png;base64,${fs.readFileSync(raw).toString('base64')}">`;
(async () => {
  const b = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  const p = await b.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  await p.setContent(page, { waitUntil: 'load' }); await p.evaluate(() => document.fonts.ready);
  await p.evaluate(() => { const c = document.querySelector('.cap'); c.style.whiteSpace = 'nowrap'; c.style.padding = '0 60px'; let f = parseFloat(getComputedStyle(c).fontSize); while (c.scrollWidth > c.clientWidth && f > 50) { f -= 2; c.style.fontSize = f + 'px'; } });
  await p.waitForTimeout(300);
  const tmp = out + '.tmp.png';
  await p.screenshot({ path: tmp, type: 'png' }); await b.close();
  // без альфа-канала: png -> bmp (24 бита) -> png
  cp.execFileSync('sips', ['-s', 'format', 'bmp', tmp, '--out', tmp + '.bmp'], { stdio: 'ignore' });
  cp.execFileSync('sips', ['-s', 'format', 'png', tmp + '.bmp', '--out', out], { stdio: 'ignore' });
  fs.unlinkSync(tmp); fs.unlinkSync(tmp + '.bmp');
})();
