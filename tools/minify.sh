#!/bin/sh
# Необязательная минификация CSS и JS для выкладки. Исходники НЕ меняются.
#
#   sh tools/minify.sh                  → dist/ — полная копия сайта для выкладки (как tools/package.sh),
#                                          css/*.css и js/*.js минифицированы
#   sh tools/minify.sh --in-place DIR   → минифицировать css/js в уже собранной папке DIR
#
# Нужен Node.js (npx); esbuild скачивается npx один раз, версия зафиксирована.
# Что даёт (gzip): main.css 18,0 → 10,9 КБ, main.js 9,2 → 5,7 КБ — около 10 КБ на первом экране.
# HTML не сжимается: в нём комментарии-инструкции (фото, аналитика), а выигрыш ≈ 1 КБ.
# Без сборки сайт работает так же — это только экономия трафика.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ESBUILD="npx --yes esbuild@0.25.10"

command -v npx >/dev/null 2>&1 || { echo "Нужен Node.js (npx). Без него выкладывайте обычный пакет: sh tools/package.sh" >&2; exit 1; }

if [ "${1:-}" = "--in-place" ]; then
  DIR="${2:?Укажите папку}"
  # настоящий путь (без «..», ссылок и относительности): исходники проекта минифицировать нельзя,
  # внутри проекта — только dist/ и release/
  DIR=$(cd "$DIR" 2>/dev/null && pwd -P) || { echo "Нет папки $2" >&2; exit 2; }
  case "$DIR" in
    "$ROOT"/dist|"$ROOT"/dist/*|"$ROOT"/release/*) ;;
    "$ROOT"|"$ROOT"/*) echo "Отказ: $DIR — исходники проекта, их минифицировать нельзя" >&2; exit 2 ;;
  esac
  [ -f "$DIR/index.html" ] || { echo "В $DIR нет index.html — это не сборка сайта" >&2; exit 2; }
else
  DIR="$ROOT/dist"
  sh "$ROOT/tools/package.sh" --out "$DIR" --no-zip >/dev/null
fi

for f in "$DIR"/css/*.css "$DIR"/js/*.js; do
  [ -f "$f" ] || continue
  before=$(wc -c < "$f")
  # без --target: современный синтаксис (oklch, color-mix, cqi, :has) остаётся как есть
  $ESBUILD "$f" --minify --legal-comments=none --log-level=warning --outfile="$f.min"
  mv "$f.min" "$f"
  echo "  $(basename "$f"): $before → $(wc -c < "$f") байт"
done
echo "Готово: $DIR"
