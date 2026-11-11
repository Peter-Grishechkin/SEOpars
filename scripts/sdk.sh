# Выбор SDK. В SDK macOS 27 @State в SwiftUI — макрос, а в Command Line Tools нет плагина
# SwiftUIMacros. Если Xcode не установлен, собираем с последним SDK 26.x, где @State — обёртка свойства.
if [[ -z "${SDKROOT:-}" ]] && ! xcode-select -p 2>/dev/null | grep -q Xcode.app; then
  CLT_SDKS=/Library/Developer/CommandLineTools/SDKs
  SDK26=$(ls -d "$CLT_SDKS"/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  if [[ -n "$SDK26" ]]; then export SDKROOT="$SDK26"; fi
fi
