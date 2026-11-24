#!/bin/zsh
# Снимки App Store 1.1: настоящие экраны Debug-сборки в общем симуляторе (очередь sim-queue) + подписи.
#   tools/appstore_shots_11.sh <iphone|ipad> [локаль ...]      ONLY="sector news" — только эти сцены; NOCOMPOSE=1 — только сырые снимки
# Нужен локальный сервер на :8000 (см. docs/appstore_shots_11.txt: копии баз с продакшена, MOCK_MODE=true).
# Результат: appstore/1.1/<iphone|ipad>/<локаль>/NN_<сцена>.png (1206x2622 / 2064x2752, без альфы).
set -e
ROOT=${0:A:h:h}; dev=${1:-iphone}; shift 2>/dev/null || true
export NODE_PATH=${NODE_PATH:-$HOME/Desktop/Web/Clipalio/node_modules}
BUNDLE=com.maximyaroshenko.SP500Heatmap2
DD=${DD:-/private/tmp/claude-501/dd-shots}; APP=$DD/Build/Products/Debug-iphonesimulator/SP500Heatmap.app
[ -d $APP ] || xcodebuild -project $ROOT/SP500Heatmap/SP500Heatmap.xcodeproj -scheme SP500Heatmap -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD build > $DD.log 2>&1
locs=($(node -e "console.log(Object.keys(require('$ROOT/tools/appstore_caps11.js').LOCALES).join(' '))")); [ $# -gt 0 ] && locs=($@)
scenes=(world sector company screener portfolio models news calendar)
typeset -A ARGS; ARGS=(world "" sector "-openIndex ibex35" company "-openIndex sp500 -openScreen company:AAPL" screener "-openScreen screener" portfolio "-openTab portfolio -demoPortfolio YES" models "-openScreen portfolio:m_dalio" news "-openScreen news" calendar "-openScreen calendar")
RAW=$ROOT/build/shots11/$dev; mkdir -p $RAW
for _t in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do id=$(~/.claude/bin/sim-queue take $dev | tail -1); [ ${#id} -eq 36 ] && break; done
[ ${#id} -eq 36 ] || { echo "симулятор не получен"; exit 1; }
xcrun simctl boot $id 2>/dev/null || true
xcrun simctl bootstatus $id -b > /dev/null
xcrun simctl status_bar $id override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3
xcrun simctl install $id $APP
for loc in $locs; do
  lang=$(node -e "console.log(require('$ROOT/tools/appstore_caps11.js').LOCALES['$loc'])")
  xcrun simctl spawn $id defaults write $BUNDLE appLanguage $lang
  o=$ROOT/appstore/1.1/$dev/$loc; mkdir -p $o
  i=0
  for sc in $scenes; do
    i=$((i+1))
    [ -n "$ONLY" ] && [[ " $ONLY " != *" $sc "* ]] && continue
    raw=$RAW/${lang}_$sc.png
    if [ ! -f $raw ] || [ -n "$FORCE" ]; then
      xcrun simctl terminate $id $BUNDLE 2>/dev/null || true
      xcrun simctl launch $id $BUNDLE ${=ARGS[$sc]} > /dev/null
      sleep ${WAIT:-12}
      xcrun simctl io $id screenshot --type=png $raw > /dev/null
    fi
    [ -n "$NOCOMPOSE" ] || node $ROOT/tools/appstore_compose11.js $dev $loc $sc $raw $o/$(printf %02d $i)_$sc.png
  done
  ~/.claude/bin/sim-queue touch >/dev/null 2>&1 || true
done
xcrun simctl terminate $id $BUNDLE 2>/dev/null || true
xcrun simctl status_bar $id clear 2>/dev/null || true
[ -n "$KEEP" ] || ~/.claude/bin/sim-queue free --app $BUNDLE
