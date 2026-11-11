#!/bin/bash
# Пересобирает картинки для README (docs/images) из настоящего приложения.
# Поднимает демо-сайт scripts/screenshots/demo_site.py, запускает копию SEOpars
# с отдельным bundle id и временной папкой данных (ваши обходы не видны и не
# меняются), обходит сайт и снимает окно в светлой и тёмной теме.
#
# Нужны разрешения «Запись экрана» и «Универсальный доступ» для терминала,
# из которого запущен скрипт. Во время съёмки (1–2 минуты) окно SEOpars
# выходит на передний план: мышь и клавиатуру не трогать, в другие
# приложения не переключаться, иначе macOS не отдаст окну фокус.
#
# Запуск: ./scripts/render-screenshots.sh
#   OUT=папка — снять в другое место, MODES=dark — снять только одну тему.
# bash, а не zsh: в zsh ловушка EXIT не срабатывает при ошибке внутри функции,
# и копия приложения с демо-сайтом остались бы запущенными.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
PORT=18991
OUT=${OUT:-$ROOT/docs/images}
BUNDLE=local.seopars.screenshots
WIN_W=1280
WIN_H=800
WORK=$(mktemp -d -t seopars-shots)
APP=""
SITE=""

cleanup() {
  pkill -f "$WORK/SEOpars.app/Contents/MacOS/SEOpars" 2>/dev/null || true
  [[ -n $SITE ]] && kill "$SITE" 2>/dev/null || true
  defaults delete $BUNDLE >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$BUNDLE.plist"  # defaults delete оставляет пустой файл
  rm -rf "$WORK"
}
trap cleanup EXIT

[[ -d build/SEOpars.app ]] || ./scripts/build-app.sh
source scripts/sdk.sh
swiftc -O -sdk "${SDKROOT:-$(xcrun --show-sdk-path)}" scripts/screenshots/winid.swift -o "$WORK/winid"
clang -dynamiclib -fobjc-arc -framework AppKit scripts/screenshots/appearance.m -o "$WORK/appearance.dylib"

cp -R build/SEOpars.app "$WORK/SEOpars.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$WORK/SEOpars.app/Contents/Info.plist"
codesign --force --deep -s - "$WORK/SEOpars.app" 2>/dev/null

python3 -I scripts/screenshots/demo_site.py --check
python3 -I scripts/screenshots/demo_site.py $PORT >/dev/null 2>&1 &
SITE=$!
for _ in {1..20}; do curl -fs -o /dev/null "http://demo.localhost:$PORT/" && break; sleep 0.25; done

# Черновик настроек через аргументы: один поток, чтобы порядок строк был одинаковым в обеих темах.
DRAFT="<$(printf '{"concurrency":1}' | xxd -p | tr -d '\n')>"

# Выводит копию на передний план, ждёт её окно и выполняет AppleScript внутри `tell process`.
ax() {
  osascript - "$APP" "$BUNDLE" <<EOF
on run argv
  tell application id (item 2 of argv) to activate
  tell application "System Events" to tell (first process whose unix id is (item 1 of argv as integer))
    repeat 50 times
      if frontmost and (exists window 1) then exit repeat
      set frontmost to true
      delay 0.1
    end repeat
    if not (exists window 1) then error "окно SEOpars не на экране: не переключайтесь в другие приложения во время съёмки"
    $1
  end tell
end run
EOF
}

MAIN='group 2 of splitter group 1 of group 1 of window 1'

tab() { ax "click radio button $1 of radio group 1 of $MAIN" >/dev/null; sleep 1; }
inspector() { ax "click checkbox 1 of $MAIN" >/dev/null; sleep 1; }

# Выделяет строку таблицы или списка, в которой есть текст $1.
# entire contents идёт в глубину, поэтому текст стоит после своей строки.
# Таблица после переключения вкладки дорисовывается не сразу, поэтому три попытки.
select_row() {
  local try
  for try in 1 2 3; do
    select_row_once "$1" 2>/dev/null && { sleep 1; return 0; }
    sleep 1
  done
  select_row_once "$1"
}

select_row_once() {
  ax "
    set els to entire contents of $MAIN
    set lastRow to missing value
    set done to false
    repeat with i from 1 to count of els
      try
        set e to item i of els
        set c to class of e
        if c is row then
          set lastRow to e
        else if c is static text and lastRow is not missing value then
          set s to \"\"
          try
            set s to (value of e) as text
          end try
          try
            set s to s & \" \" & ((name of e) as text)
          end try
          if s contains \"$1\" then
            set selected of lastRow to true
            set done to true
          end if
        end if
      end try
      if done then exit repeat
    end repeat
    if not done then error \"строка не найдена: $1\"" >/dev/null
}

shot() {
  ax "set position of window 1 to {80, 40}
      set size of window 1 to {$WIN_W, $WIN_H}
      delay 0.5" >/dev/null
  local wid
  wid=$("$WORK/winid" "$APP")
  [[ -n $wid ]] || { echo "окно SEOpars не найдено" >&2; exit 1; }
  screencapture -x -l"$wid" "$OUT/$1"
  echo "  $1 ($(sips -g pixelWidth -g pixelHeight "$OUT/$1" | awk '/pixel/{printf "%s ", $2}'))"
}

mkdir -p "$OUT"
for MODE in ${MODES:-light dark}; do
  echo "Тема: $MODE"
  HOME_DIR="$WORK/home-$MODE"
  mkdir -p "$HOME_DIR"
  # Через open (LaunchServices): только так macOS даёт новому окну фокус, пока активно другое приложение.
  # Тему задаёт appearance.dylib: системная тема не меняется.
  open -n -F --env HOME="$HOME_DIR" --env CFFIXED_USER_HOME="$HOME_DIR" \
    --env DYLD_INSERT_LIBRARIES="$WORK/appearance.dylib" --env SEOPARS_APPEARANCE=$MODE \
    -a "$WORK/SEOpars.app" --args \
    --start "http://demo.localhost:$PORT/" --delay 20 \
    -draftConfig "$DRAFT" -ApplePersistenceIgnoreState YES
  APP=""
  for _ in {1..40}; do APP=$(pgrep -n -f "$WORK/SEOpars.app/Contents/MacOS/SEOpars" || true); [[ -n $APP ]] && break; sleep 0.25; done
  [[ -n $APP ]] || { echo "SEOpars не запустился" >&2; exit 1; }

  for _ in {1..120}; do
    [[ $(ax "exists static text \"Завершён\" of $MAIN" 2>/dev/null) == true ]] && break
    sleep 0.5
  done
  [[ $(ax "exists static text \"Завершён\" of $MAIN") == true ]] || { echo "обход не завершился" >&2; exit 1; }

  tab 2
  select_row "shu-puer-guntin-2018"
  shot "pages-$MODE.png"

  inspector
  tab 1
  shot "overview-$MODE.png"

  tab 7
  select_row "Title повторяется"
  shot "issues-$MODE.png"

  tab 5
  shot "links-$MODE.png"

  kill "$APP" 2>/dev/null || true
  for _ in {1..20}; do kill -0 "$APP" 2>/dev/null || break; sleep 0.25; done
done
# Сжатие без потерь, если установлен oxipng (brew install oxipng).
if command -v oxipng >/dev/null; then
  for MODE in ${MODES:-light dark}; do
    for NAME in pages overview issues links; do oxipng -o 4 --strip safe -q "$OUT/$NAME-$MODE.png"; done
  done
fi
echo "Готово: $OUT"
