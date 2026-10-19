<?php
// «Почтовая ловушка» для локальной разработки: PHP mail() вызывает её вместо настоящего sendmail
// (см. sendmail_path в tools/dev/php.ini). Письмо НИКУДА не уходит: оно сохраняется в .dev-mail/
// (папка в .gitignore) как .eml и как читаемый .txt с расшифрованной темой и телом.
$raw = stream_get_contents(STDIN);
$dir = dirname(__DIR__, 2) . '/.dev-mail';
if (!is_dir($dir)) {
    mkdir($dir, 0700, true);
}
$name = date('Ymd-His') . '-' . bin2hex(random_bytes(2));
file_put_contents("$dir/$name.eml", $raw);

// Читаемый вид: разбираем заголовки и декодируем base64-тело (так send.php его и кодирует).
$parts = preg_split("/\r?\n\r?\n/", $raw, 2);
$head = $parts[0] ?? '';
$body = $parts[1] ?? '';
$headers = [];
foreach (preg_split("/\r?\n(?! |\t)/", $head) as $line) {
    $line = preg_replace("/\r?\n[ \t]+/", ' ', $line);
    if (strpos($line, ':') !== false) {
        [$k, $v] = explode(':', $line, 2);
        $headers[trim($k)] = trim($v);
    }
}
$subject = isset($headers['Subject']) ? mb_decode_mimeheader($headers['Subject']) : '';
$isB64 = isset($headers['Content-Transfer-Encoding']) && stripos($headers['Content-Transfer-Encoding'], 'base64') !== false;
$text = $isB64 ? base64_decode(preg_replace('/\s+/', '', $body)) : $body;

$out = "Кому:    " . ($headers['To'] ?? '(в заголовках нет, адрес передан в -t)') . "\n"
    . "От:      " . ($headers['From'] ?? '') . "\n"
    . "Ответ на: " . ($headers['Reply-To'] ?? '-') . "\n"
    . "Тема:    $subject\n\n$text\n";
file_put_contents("$dir/$name.txt", $out);
exit(0);
