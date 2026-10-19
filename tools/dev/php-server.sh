#!/bin/sh
# Локальный сервер с PHP для проверки отправки формы: `npm start`.
# mail() здесь не шлёт настоящих писем: они складываются в .dev-mail/ (смотреть: npm run mail).
# Только для разработки; на хостинге не используется.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PHP=$(command -v php) || { echo "PHP не найден. Установите: brew install php" >&2; exit 1; }
PORT=${PORT:-8080}
cd "$ROOT"
echo "Сайт с PHP: http://localhost:$PORT"
for ip in $(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2}'); do echo "С телефона (та же Wi-Fi сеть): http://$ip:$PORT"; done
echo "Письма заявок: $ROOT/.dev-mail/  (последнее: npm run mail). Остановка: Ctrl+C."
exec "$PHP" \
  -d display_errors=Off -d log_errors=On -d error_reporting=E_ALL \
  -d "sendmail_path=$PHP $ROOT/tools/dev/sendmail-catcher.php" \
  -S "0.0.0.0:$PORT" tools/dev/router.php
