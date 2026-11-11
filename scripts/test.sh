#!/bin/zsh
# Тесты под Command Line Tools: плагин макросов Swift Testing лежит в отдельной папке.
set -e
cd "$(dirname "$0")/.."
source scripts/sdk.sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
