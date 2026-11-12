#!/bin/zsh
# Упаковывает собранное приложение в zip для релиза на GitHub.
# В архиве: SEOpars.app, seopars-cli и LICENSE.md (лицензия требует передавать её вместе с копией).
# Запускать после ./scripts/build-app.sh. Результат — build/release/SEOpars-<версия>-macos-<арх>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
[[ -n "$VERSION" ]] || { echo "Не нашёл VERSION в scripts/build-app.sh" >&2; exit 1; }

APP="build/SEOpars.app"
CLI="build/seopars-cli"
[[ -d "$APP" && -x "$CLI" ]] || { echo "Нет $APP или $CLI: сначала ./scripts/build-app.sh" >&2; exit 1; }

BUILT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT" == "$VERSION" ]] || { echo "$APP собран как $BUILT, а VERSION=$VERSION: пересоберите ./scripts/build-app.sh" >&2; exit 1; }

codesign --verify --deep --strict "$APP"
ARCH="$(lipo -archs "$APP/Contents/MacOS/SEOpars" | tr ' ' '-')"

NAME="SEOpars-$VERSION-macos-$ARCH"
OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT/$NAME"
ditto "$APP" "$OUT/$NAME/SEOpars.app"
cp "$CLI" LICENSE.md "$OUT/$NAME/"
ditto -c -k --keepParent "$OUT/$NAME" "$OUT/$NAME.zip"

echo "Готово: $PWD/$OUT/$NAME.zip"
shasum -a 256 "$OUT/$NAME.zip"
