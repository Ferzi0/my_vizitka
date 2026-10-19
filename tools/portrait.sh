#!/bin/sh
# Портрет для первого экрана: вырезка фона, ч/б тонирование, два кадра в двух размерах и трёх форматах.
#
#   sh tools/portrait.sh                 → берёт фото из src-images/portrait/ (первый файл по имени)
#   sh tools/portrait.sh путь/к/фото.jpg → любое фото (HEIC, JPG, PNG — всё, что открывает «Просмотр»)
#
# Получается в assets/portrait/ (старые файлы портрета там заменяются):
#   portrait-waist-480|960.avif|webp|png  — «по пояс», для экранов шире 600 px;
#   portrait-chest-360|720.avif|webp|png  — «по грудь», для телефона.
# PNG — запасной (с альфа-каналом), AVIF и WebP — основные. Метаданные фото (EXIF, GPS) в файлы не попадают.
#
# Всё делается на этом Mac, фото никуда не отправляется:
#   · фон вырезает Apple Vision (маска человека ∩ маска переднего плана), край доводится:
#     мусор маски и мелкие дыры, сужение и перо по краю, удаление ореола старого фона;
#   · tools/portrait/cutout.m собирается clang во временную папку (нужны Xcode Command Line Tools:
#     xcode-select --install; macOS 14 и новее);
#   · кодирование — cwebp и avifenc (brew install webp libavif).
#
# Кадры подобраны под исходное фото (человек в полный рост). Для другого фото поправьте доли ниже
# (или задайте переменными окружения): *_BOTTOM — линия обреза снизу, доля высоты фото
# (0,85 — пояс/карманы, 0,53 — грудь); *_ASPECT — ширина/высота кадра; *_HEAD — запас над макушкой
# (доля высоты кадра); CX — центр кадра по горизонтали (доля ширины фото; по умолчанию — центр фигуры).
# Если пропорции кадров изменились — поправьте width/height у <source>/<img> портрета в index.html
# (скрипт печатает размеры), затем пересоберите пакет: sh tools/package.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OUT="$ROOT/assets/portrait"
WAIST_BOTTOM=${WAIST_BOTTOM:-0.85}; WAIST_ASPECT=${WAIST_ASPECT:-0.75}; WAIST_HEAD=${WAIST_HEAD:-0.05}
CHEST_BOTTOM=${CHEST_BOTTOM:-0.53}; CHEST_ASPECT=${CHEST_ASPECT:-1.08}; CHEST_HEAD=${CHEST_HEAD:-0.06}
CX=${CX:-}
Q_AVIF=56; Q_AVIF_ALPHA=80; Q_WEBP=66; Q_WEBP_ALPHA=85
PNG_LEVELS=32   # запасной PNG: серый до 32 уровней — меньше файл (на вид почти без разницы)

die() { echo "$*" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || die "Нужен macOS 14 или новее: вырезка фона — Apple Vision."
MACOS=$(sw_vers -productVersion 2>/dev/null || echo 0)
[ "${MACOS%%.*}" -ge 14 ] 2>/dev/null || die "Нужен macOS 14 или новее (здесь $MACOS): маски Vision для человека и переднего плана появились в macOS 14."
command -v clang >/dev/null 2>&1 || die "Нет clang. Установите Xcode Command Line Tools: xcode-select --install"
for t in cwebp avifenc; do command -v "$t" >/dev/null 2>&1 || die "Нет $t. Установите: brew install webp libavif"; done

if [ $# -gt 0 ]; then SRC=$1; else
  SRC=""
  for f in "$ROOT"/src-images/portrait/*; do [ -f "$f" ] && { SRC=$f; break; }; done
  [ -n "$SRC" ] || die "Положите фото в src-images/portrait/ (эта папка не публикуется и не попадает в git) или укажите путь."
fi
[ -f "$SRC" ] || die "Нет файла $SRC"
case "$(cd "$(dirname "$SRC")" && pwd -P)/" in "$ROOT"/assets/*) die "Оригинал не кладите в assets/ — он попадёт на сайт. Место ему — src-images/portrait/." ;; esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ferz-portrait.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM
clang -fobjc-arc -O2 -framework Foundation -framework ImageIO -framework Vision -framework CoreVideo \
  -framework CoreGraphics -framework UniformTypeIdentifiers "$ROOT/tools/portrait/cutout.m" -o "$TMP/cutout" \
  || die "Не собрался tools/portrait/cutout.m (нужны Xcode Command Line Tools для macOS 14+)."

echo "Фото: $SRC"
"$TMP/cutout" master "$SRC" "$TMP/master.png"

# Все кадры сначала собираются во временной папке; файлы сайта заменяются только после успеха —
# при сбое (нет памяти, ошибка кодировщика, Ctrl+C) прежний портрет остаётся на месте целиком.
NEW="$TMP/out"
mkdir -p "$NEW"

# кадр: имя, ширина, доля низа, пропорция, запас над головой
frame() {
  name=$1; w=$2; bottom=$3; aspect=$4; head=$5
  set -- --width "$w" --aspect "$aspect" --bottom "$bottom" --head "$head"
  [ -n "$CX" ] && set -- "$@" --cx "$CX"
  base="$NEW/portrait-$name-$w"
  "$TMP/cutout" crop "$TMP/master.png" "$TMP/$name-$w.png" "$@" >/dev/null
  "$TMP/cutout" crop "$TMP/master.png" "$base.png" "$@" --sharpen 0.2 --levels "$PNG_LEVELS" >/dev/null
  cwebp -quiet -q "$Q_WEBP" -alpha_q "$Q_WEBP_ALPHA" -m 6 -sharp_yuv -metadata none "$TMP/$name-$w.png" -o "$base.webp" \
    || die "cwebp не смог закодировать portrait-$name-$w — файлы в $OUT не тронуты."
  avifenc -q "$Q_AVIF" --qalpha "$Q_AVIF_ALPHA" -s 3 -y 400 --ignore-exif --ignore-xmp --ignore-icc \
    "$TMP/$name-$w.png" "$base.avif" >/dev/null \
    || die "avifenc не смог закодировать portrait-$name-$w — файлы в $OUT не тронуты."
  size=$(sips -g pixelWidth -g pixelHeight "$base.png" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "×" h}')
  echo "portrait-$name-$w: $size px · avif $(du -k "$base.avif" | cut -f1) КБ · webp $(du -k "$base.webp" | cut -f1) КБ · png $(du -k "$base.png" | cut -f1) КБ"
}
for w in 480 960; do frame waist "$w" "$WAIST_BOTTOM" "$WAIST_ASPECT" "$WAIST_HEAD"; done
for w in 360 720; do frame chest "$w" "$CHEST_BOTTOM" "$CHEST_ASPECT" "$CHEST_HEAD"; done

[ "$(ls "$NEW" | wc -l)" -eq 12 ] || die "Собраны не все 12 файлов портрета — файлы в $OUT не тронуты."
mkdir -p "$OUT"
rm -f "$OUT"/portrait-*.avif "$OUT"/portrait-*.webp "$OUT"/portrait-*.png
cp "$NEW"/portrait-* "$OUT"/
echo "Готово: $OUT"
echo "Если размеры кадров изменились — поправьте width/height портрета в index.html; затем: sh tools/package.sh"
