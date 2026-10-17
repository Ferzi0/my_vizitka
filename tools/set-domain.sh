#!/bin/sh
# Подставляет настоящий домен вместо заглушки example.com во всех абсолютных адресах сайта:
#   index.html  — canonical, og:url, og:image, twitter:image, JSON-LD (@id, url, image), data-domain Plausible;
#   privacy.html — canonical, og:url, og:image;
#   sitemap.xml — <loc>;  robots.txt — строка Sitemap.
# Почта hello@example.com — ОТДЕЛЬНАЯ заглушка, скрипт её не трогает.
#
# Использование (из любой папки):
#   sh tools/set-domain.sh ferz.ru              — показать diff и применить
#   sh tools/set-domain.sh ferz.ru --dry-run    — только показать diff
#   sh tools/set-domain.sh new.ru --from ferz.ru — сменить уже подставленный домен
# Схема — https:// (ссылки в метатегах и sitemap должны вести на https-версию сайта).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FILES="index.html privacy.html sitemap.xml robots.txt"

NEW=""; FROM="example.com"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --from) shift; FROM="${1:-}" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) NEW="$1" ;;
  esac
  shift
done

check_domain() {
  # только имя хоста: буквы/цифры/дефис, точки, IDN в punycode (xn--...). Без схемы, пути и порта.
  printf '%s' "$1" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$'
}
NEW=$(printf '%s' "$NEW" | tr 'A-Z' 'a-z' | sed -e 's#^https\{0,1\}://##' -e 's#/*$##')
if [ -z "$NEW" ] || ! check_domain "$NEW"; then
  echo "Укажите домен, например: sh tools/set-domain.sh ferz.ru" >&2
  echo "Кириллический домен — в punycode (xn--...), его показывает регистратор." >&2
  exit 2
fi
if ! check_domain "$FROM"; then echo "Неверный --from: $FROM" >&2; exit 2; fi
if [ "$NEW" = "$FROM" ]; then echo "Домен уже $NEW — менять нечего."; exit 0; fi

# точки в старом домене экранируются для sed; заменяются только https://ДОМЕН и data-domain="ДОМЕН"
OLD_RE=$(printf '%s' "$FROM" | sed 's/\./\\./g')
TMP=$(mktemp -d "${TMPDIR:-/tmp}/set-domain.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

CHANGED=0
for f in $FILES; do
  src="$ROOT/$f"
  [ -f "$src" ] || { echo "нет файла $f — пропускаю" >&2; continue; }
  sed -e "s#https://$OLD_RE\([/\"<]\)#https://$NEW\1#g" \
      -e "s#https://$OLD_RE\$#https://$NEW#g" \
      -e "s#data-domain=\"$OLD_RE\"#data-domain=\"$NEW\"#g" \
      -e "s#\[ЗАПОЛНИТЬ: домен\] $OLD_RE — заглушка#Домен: $NEW#g" \
      -e "s#Домен: $OLD_RE\([ ;(]\)#Домен: $NEW\1#g" \
      "$src" > "$TMP/$(basename "$f")"
  if ! cmp -s "$src" "$TMP/$(basename "$f")"; then
    diff -u "$src" "$TMP/$(basename "$f")" | sed "1,2s#$ROOT/##; 1,2s#$TMP/#новый #" || true
    CHANGED=$((CHANGED + 1))
  fi
done

if [ "$CHANGED" -eq 0 ]; then
  echo "Адресов с $FROM не найдено — ничего не изменено."
  exit 0
fi
if [ "$DRY" -eq 1 ]; then
  echo "--dry-run: файлов к изменению: $CHANGED. Ничего не записано."
  exit 0
fi
for f in $FILES; do
  t="$TMP/$(basename "$f")"
  [ -f "$t" ] && ! cmp -s "$ROOT/$f" "$t" && cat "$t" > "$ROOT/$f"
done
LEFT=$(grep -l "https://$OLD_RE" $(for f in $FILES; do printf '%s ' "$ROOT/$f"; done) 2>/dev/null || true)
echo "Готово: изменено файлов — $CHANGED, домен $FROM → $NEW."
[ -n "$LEFT" ] && echo "ВНИМАНИЕ: адреса с $FROM ещё остались в: $LEFT" >&2
[ -d "$ROOT/release" ] || [ -d "$ROOT/dist" ] && echo "Пакеты в release/ и dist/ собраны со старым доменом — пересоберите: sh tools/package.sh"
echo "Не забудьте: allowed_hosts в send.config.php на сервере (['$NEW', 'www.$NEW']) и data-domain аналитики, если она подключена."
