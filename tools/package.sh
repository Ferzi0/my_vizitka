#!/bin/sh
# Собирает пакет для выкладки на хостинг: ТОЛЬКО файлы сайта, без заметок, git и инструментов.
#
#   sh tools/package.sh             → release/ferz-site/ + release/ferz-site.zip (Apache + PHP: обычный хостинг)
#   sh tools/package.sh --min       → то же, CSS и JS минифицированы (нужен Node.js: tools/minify.sh)
#   sh tools/package.sh --static    → release/ferz-site-static/ + .zip — для Netlify / Cloudflare Pages / хостинга БЕЗ PHP:
#                                     с _headers, без send.php и .htaccess, у формы убран data-endpoint
#                                     (заявка сразу уходит через почтовую программу, без лишнего запроса)
#   sh tools/package.sh --out DIR --no-zip   → только папка DIR (так её собирает tools/minify.sh)
#
# В пакет входят:  index.html, privacy.html, robots.txt, sitemap.xml, css/*.css, js/*.js,
#                  assets/ (иконки, og-image, шрифты + лицензии OFL, скриншоты работ assets/works/*.avif|webp|jpg),
#                  send.php и .htaccess (не для --static).
# НЕ входят:       STATUS.md, ANALYTICS.md и другие *.md, .git, .gitignore, tools/, dist/, release/,
#                  src-images/ (исходные PNG скриншотов — пересборка: sh tools/images.sh),
#                  _headers (кроме --static), send.config.example.php, send.config.php (секреты!), .DS_Store.
# После выкладки на сервере создайте send.config.php (образец — send.config.example.php в исходниках),
# лучше уровнем ВЫШЕ корня сайта: send.php ищет его там первым.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OUT=""; ZIP=1; MIN=0; STATIC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --min) MIN=1 ;;
    --static) STATIC=1 ;;
    --no-zip) ZIP=0 ;;
    --out) shift; OUT="${1:?после --out укажите папку}"; [ -n "$OUT" ] || { echo "Пустой --out" >&2; exit 2; } ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Неизвестный параметр: $1" >&2; exit 2 ;;
  esac
  shift
done
# по умолчанию: release/ferz-site, для --static — release/ferz-site-static (чтобы не затирать пакет для Apache)
[ -n "$OUT" ] || { [ "$STATIC" -eq 1 ] && OUT="$ROOT/release/ferz-site-static" || OUT="$ROOT/release/ferz-site"; }
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac

# Папка OUT удаляется целиком (rm -rf), поэтому сначала проверяем, что это действительно папка сборки:
# путь без «.»/«..», не корень проекта, не его родитель и не папка исходников (внутри проекта — только
# dist/ и release/), а если она уже есть — в ней только то, что кладёт сюда этот скрипт.
die() { echo "$*" >&2; exit 2; }
OUT=${OUT%/}; while [ "${OUT%/}" != "$OUT" ]; do OUT=${OUT%/}; done
OUT_NAME=$(basename "$OUT")
case "$OUT_NAME" in ""|.|..) die "Укажите имя папки сборки, а не «${OUT}»" ;; esac
[ "$(dirname "$OUT")" = "$ROOT/release" ] && mkdir -p "$ROOT/release"
OUT_PARENT=$(cd "$(dirname "$OUT")" 2>/dev/null && pwd -P) || die "Нет родительской папки для $OUT"
OUT="$OUT_PARENT/$OUT_NAME"
case "$ROOT/" in "$OUT"/*) die "Нельзя собирать в $OUT: это проект или папка выше него" ;; esac
case "$OUT" in
  "$ROOT"/dist|"$ROOT"/dist/*|"$ROOT"/release|"$ROOT"/release/*) ;;
  "$ROOT"/*) die "Внутри проекта собирать можно только в dist/ или release/, не в $OUT" ;;
esac
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  [ -d "$OUT" ] && [ ! -L "$OUT" ] || die "$OUT — не папка; удалите или выберите другое имя"
  for e in "$OUT"/* "$OUT"/.[!.]* "$OUT"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    case "$(basename "$e")" in
      index.html|privacy.html|robots.txt|sitemap.xml|_headers|send.php|.htaccess|css|js|assets|index.html.tmp) ;;
      *) die "В $OUT есть посторонний файл «$(basename "$e")» — это не прежняя сборка, удалять не стану. Укажите пустую или новую папку." ;;
    esac
  done
fi

FILES="index.html privacy.html robots.txt sitemap.xml"
[ "$STATIC" -eq 1 ] && FILES="$FILES _headers" || FILES="$FILES send.php .htaccess"

rm -rf "$OUT"
mkdir -p "$OUT/css" "$OUT/js" "$OUT/assets/fonts"
for f in $FILES; do cp "$ROOT/$f" "$OUT/$f"; done
cp "$ROOT"/css/*.css "$OUT/css/"
cp "$ROOT"/js/*.js "$OUT/js/"
for f in "$ROOT"/assets/*; do [ -f "$f" ] && cp "$f" "$OUT/assets/"; done
cp "$ROOT"/assets/fonts/*.woff2 "$ROOT"/assets/fonts/*.txt "$OUT/assets/fonts/"
# Скриншоты работ: только сжатые копии (tools/images.sh), без исходников и мусора вроде .DS_Store
if [ -d "$ROOT/assets/works" ]; then
  (cd "$ROOT/assets" && find works -type f \( -name '*.avif' -o -name '*.webp' -o -name '*.jpg' \)) | while IFS= read -r f; do
    mkdir -p "$OUT/assets/$(dirname "$f")"
    cp "$ROOT/assets/$f" "$OUT/assets/$f"
  done
fi

if [ "$STATIC" -eq 1 ]; then
  # без PHP send.php отдался бы как текст; форма сразу открывает письмо (mailto:)
  sed 's# data-endpoint="send.php"##' "$OUT/index.html" > "$OUT/index.html.tmp" && mv "$OUT/index.html.tmp" "$OUT/index.html"
  grep -q 'data-endpoint=' "$OUT/index.html" && { echo "Не удалось убрать data-endpoint" >&2; exit 1; }
fi

[ "$MIN" -eq 1 ] && sh "$ROOT/tools/minify.sh" --in-place "$OUT"

# Проверка: в пакете нет служебного
BAD=$(cd "$OUT" && find . \( -name '*.md' -o -name '.git*' -o -name 'send.config*.php' -o -name '.DS_Store' -o -name 'tools' -o -name '*.sh' -o -name 'src-images' -o -size +1024k \) -print)
[ -n "$BAD" ] && { echo "В пакет попало лишнее: $BAD" >&2; exit 1; }

echo "Пакет: $OUT"
(cd "$OUT" && find . -type f | sed 's#^\./#  #' | sort)
echo "Размер: $(du -sk "$OUT" | cut -f1) КБ"

if [ "$ZIP" -eq 1 ]; then
  Z="$(dirname "$OUT")/$(basename "$OUT").zip"
  rm -f "$Z"
  (cd "$OUT" && zip -q -r -X "$Z" .)
  echo "Архив: $Z ($(du -k "$Z" | cut -f1) КБ) — распакуйте в корень сайта (public_html / www)."
fi

if grep -q 'example\.com' "$OUT/index.html"; then
  echo "Напоминание: в пакете ещё заглушки example.com — домен: sh tools/set-domain.sh ВАШ-ДОМЕН, почта/Telegram — вручную (STATUS.md, «Заглушки»)."
fi
if [ "$STATIC" -eq 0 ]; then
  echo "Напоминание: создайте на сервере send.config.php (адрес для заявок 'to', случайная 'salt' ≥ 16 символов,"
  echo "  'allowed_hosts' с вашим доменом) — образец send.config.example.php. В пакет он НЕ входит."
fi
