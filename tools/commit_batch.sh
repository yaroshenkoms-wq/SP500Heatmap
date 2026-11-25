#!/bin/zsh
# Коммит готовых папок локалей (где есть 08_calendar.png) и push. tools/commit_batch.sh <iphone|ipad> "<сообщение>"
cd ${0:A:h:h}
dirs=(); for d in appstore/1.1/$1/*(/); do [ -f $d/08_calendar.png ] && dirs+=($d); done
git add tools $dirs && git commit -q -m "$2

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push -q origin feat/store-shots 2>&1 | tail -1
