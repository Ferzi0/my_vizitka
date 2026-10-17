#!/bin/sh
# Пересобирает картинки работ для сайта из исходников в src-images/ (папка вне сайта, в пакет не попадает).
#
#   sh tools/images.sh              → все работы: src-images/<работа>/*.png|jpg → assets/works/<работа>/
#   sh tools/images.sh ai-travel    → только одна работа
#
# Для каждого исходника 01.png получается 6 файлов: 01-800 и 01-1600 (ширина в px)
# в форматах AVIF, WebP и JPG (запасной). Пропорции сохраняются, метаданные (EXIF и т. п.) удаляются.
# В конце печатаются размеры (ширина×высота) — их нужно вписать в width/height тега <img> в index.html.
#
# Нужен Node.js (npx). Конвертер — sharp-cli фиксированной версии, скачивается npx во временный кэш,
# в проект и в систему ничего не ставится. Первый запуск — около минуты (загрузка).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SHARP="sharp-cli@6.1.0"
WIDTHS="800 1600"
Q_AVIF=50; Q_WEBP=78; Q_JPG=76

command -v npx >/dev/null 2>&1 || { echo "Нужен Node.js (npx): https://nodejs.org" >&2; exit 2; }
[ -d "$ROOT/src-images" ] || { echo "Нет папки src-images/ — положите исходники в src-images/<работа>/" >&2; exit 2; }

if [ $# -gt 0 ]; then WORKS="$*"; else WORKS=$(cd "$ROOT/src-images" && for d in */; do [ -d "$d" ] && printf '%s ' "${d%/}"; done); fi

sharp() { npx --yes "$SHARP" "$@" >/dev/null; }

for work in $WORKS; do
  case "$work" in *[!a-z0-9-]*|"") echo "Имя работы — латиница, цифры и дефис: «${work}»" >&2; exit 2 ;; esac
  src="$ROOT/src-images/$work"; out="$ROOT/assets/works/$work"
  [ -d "$src" ] || { echo "Нет папки $src" >&2; exit 2; }
  mkdir -p "$out"
  found=0
  for f in "$src"/*.png "$src"/*.jpg "$src"/*.jpeg; do
    [ -f "$f" ] || continue
    found=1
    name=$(basename "$f"); name=${name%.*}
    for w in $WIDTHS; do
      sharp -i "$f" -o "$out/$name-$w.avif" -f avif -q "$Q_AVIF" --effort 6 resize "$w"
      sharp -i "$f" -o "$out/$name-$w.webp" -f webp -q "$Q_WEBP" --effort 6 --smartSubsample resize "$w"
      sharp -i "$f" -o "$out/$name-$w.jpg" -f jpeg -q "$Q_JPG" --mozjpeg resize "$w"
      size=$(file "$out/$name-$w.jpg" | grep -Eo '[0-9]+x[0-9]+' | tail -1)
      echo "$work/$name-$w: $size px · avif $(du -k "$out/$name-$w.avif" | cut -f1) КБ · webp $(du -k "$out/$name-$w.webp" | cut -f1) КБ · jpg $(du -k "$out/$name-$w.jpg" | cut -f1) КБ"
    done
  done
  [ "$found" -eq 1 ] || echo "В $src нет .png/.jpg — пропускаю" >&2
done
echo "Готово. Если размеры кадра изменились — поправьте width/height у <img> в index.html, затем пересоберите пакет: sh tools/package.sh"
