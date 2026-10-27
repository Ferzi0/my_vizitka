<?php
/**
 * Ferz — приём заявки с сайта и отправка письма: через SMTP (если в send.config.php заполнен блок 'smtp')
 * или через mail() хостинга.
 *
 * Для обычного хостинга с PHP 7.4+ (Apache или nginx + PHP-FPM). Без базы данных и библиотек.
 * Настройки — в send.config.php (пример: send.config.example.php). Лучше положить его
 * на уровень ВЫШЕ корня сайта: send.php сначала ищет ../send.config.php, затем рядом с собой.
 *
 * Принимает POST: application/json или обычную форму (application/x-www-form-urlencoded / multipart).
 * Поля: name, contact, type, message, consent, website (honeypot — должно быть пустым).
 * Отвечает JSON:
 *   200 {"ok":true}
 *   422 {"ok":false,"error":"validation","fields":{"name":"…"}}
 *   429 {"ok":false,"error":"rate_limited","retryAfter":секунды}
 *   400/403/405/413/415 {"ok":false,"error":"…"}            — неправильный запрос
 *   502/503 {"ok":false,"error":"unavailable"}              — сайт откроет почтовую программу (mailto)
 * В журнал ошибок PHP пишутся только коды событий — без имени, контакта, текста и IP.
 */
declare(strict_types=1);

// Предупреждения PHP не должны попасть в ответ (пути на сервере, сломанный JSON) — только в журнал
// (function_exists: на части хостингов функции отключены, а в PHP 8 вызов отключённой — фатальная ошибка)
if (function_exists('ini_set')) {
    @ini_set('display_errors', '0');
}

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header("Content-Security-Policy: default-src 'none'; frame-ancestors 'none'");

const FERZ_TYPES = ['Сайт-визитка', 'Лендинг', 'Telegram-бот', 'Веб-сервис', 'Интернет-магазин', 'Другое'];
const FERZ_MAX_BODY = 16384;

function ferz_respond(int $code, array $payload, array $headers = []): void
{
    http_response_code($code);
    foreach ($headers as $h) {
        header($h);
    }
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/** Только код события — никаких персональных данных. */
function ferz_log(string $event): void
{
    error_log('[ferz-send] ' . $event);
}

function ferz_len(string $s): int
{
    if (function_exists('mb_strlen')) {
        return mb_strlen($s, 'UTF-8');
    }
    return (int) preg_match_all('/./us', $s);
}

/** Удаляет управляющие и невидимые символы, схлопывает пробелы. null — если строка не UTF-8. */
function ferz_clean($value, bool $singleLine): ?string
{
    if (!is_string($value)) {
        return is_scalar($value) ? ferz_clean((string) $value, $singleLine) : '';
    }
    if (!preg_match('//u', $value)) {
        return null; // битая кодировка
    }
    $value = str_replace(["\r\n", "\r"], "\n", $value);
    if ($singleLine) {
        $value = preg_replace('/\n+/u', ' ', $value); // никаких переводов строк в однострочных полях
    }
    $value = preg_replace('/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{007F}\x{200B}-\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}]/u', '', $value);
    $value = preg_replace('/[ \t]+/u', ' ', $value);
    return trim((string) $value);
}

/** Заголовок письма в UTF-8 (RFC 2047): кириллица и защита от переводов строк.
 *  Одно encoded-word — не длиннее 75 символов (RFC 2047, п. 2), поэтому текст режется на куски
 *  по 45 байт по границам символов; куски разделяются пробелом (при чтении он не виден). */
function ferz_header_text(string $s): string
{
    $s = str_replace(["\r", "\n"], ' ', $s);
    preg_match_all('/./us', $s, $m);
    $words = [];
    $chunk = '';
    foreach ($m[0] as $ch) {
        if ($chunk !== '' && strlen($chunk) + strlen($ch) > 45) {
            $words[] = '=?UTF-8?B?' . base64_encode($chunk) . '?=';
            $chunk = '';
        }
        $chunk .= $ch;
    }
    if ($chunk !== '' || !$words) {
        $words[] = '=?UTF-8?B?' . base64_encode($chunk) . '?=';
    }
    return implode(' ', $words);
}

/** Блокировка файла лимита. Повтор, если файл успели удалить (уборка или пустой файл ошибочной
 *  заявки) между fopen и flock — иначе параллельные заявки писали бы в разные файлы и обходили лимит.
 *  null — файловая система не даёт работать (лимит пропускаем); false — файл всё время удаляют
 *  из-под нас (поток параллельных запросов): тогда заявку не принимаем, а не отправляем без лимита. */
function ferz_rate_open(string $file)
{
    for ($try = 0; $try < 10; $try++) {
        $h = @fopen($file, 'c+');
        if (!$h) {
            return null;
        }
        if (!flock($h, LOCK_EX)) {
            fclose($h);
            return null;
        }
        clearstatcache(true, $file);
        $onDisk = @stat($file);
        $opened = fstat($h);
        if ($onDisk && $opened && $onDisk['ino'] === $opened['ino'] && $onDisk['dev'] === $opened['dev']) {
            return $h;
        }
        flock($h, LOCK_UN);
        fclose($h);
    }
    return false;
}

/** Отпустить файл лимита; пустой (заявка не ушла) — удалить, пока он ещё заблокирован. */
function ferz_rate_close($h, ?string $file): void
{
    if (!$h) {
        return;
    }
    $st = fstat($h);
    if ($file !== null && $st && $st['size'] === 0) {
        @unlink($file);
    }
    flock($h, LOCK_UN);
    fclose($h);
}

function ferz_is_email(string $s): bool
{
    return strpbrk($s, "\r\n") === false && filter_var($s, FILTER_VALIDATE_EMAIL) !== false;
}

/** Ответ SMTP-сервера: код и текст (многострочные ответы «250-…» читаются до последней строки «250 …»
 *  или «250» без текста — по RFC 5321 текст необязателен). null — обрыв, таймаут, мусор.
 *  $deadline — общий срок на весь разговор (microtime): медленный сервер, который присылает по строчке
 *  раз в несколько секунд, не держит процесс PHP и блокировку лимита дольше него. */
function ferz_smtp_read($fp, float $deadline): ?array
{
    $text = '';
    $line = '';
    for ($i = 0; $i < 100; $i++) {
        $left = $deadline - microtime(true);
        if ($left <= 0) {
            return null;
        }
        stream_set_timeout($fp, (int) $left, (int) (($left - (int) $left) * 1000000));
        $part = fgets($fp, 1024);
        if ($part === false) {
            return null;
        }
        // Длинная строка приходит кусками: разбираем только целую, иначе хвост примем за следующий ответ
        $line .= $part;
        if (substr($line, -1) !== "\n") {
            if (strlen($line) > 4096) {
                return null;
            }
            continue;
        }
        $text .= $line;
        if (!preg_match('/^(\d{3})([ \-\r\n])/', $line, $m)) {
            return null; // не ответ SMTP — дальше ждать нечего
        }
        if ($m[2] !== '-') {
            return [(int) $m[1], $text];
        }
        $line = '';
    }
    return null;
}

/** Команда и ожидаемый код ответа. true — сервер ответил ожидаемым кодом. */
function ferz_smtp_cmd($fp, string $cmd, array $ok, float $deadline): bool
{
    if ($cmd !== '' && @fwrite($fp, $cmd . "\r\n") === false) {
        return false;
    }
    $r = ferz_smtp_read($fp, $deadline);
    return $r !== null && in_array($r[0], $ok, true);
}

/**
 * Отправка письма по SMTP с авторизацией (AUTH LOGIN) — без библиотек.
 * secure: 'ssl' (порт 465), 'tls' (STARTTLS, порт 587); 'none' — только для проверки на своём компьютере.
 * Сертификат сервера проверяется. Возвращает '' при успехе, иначе код этапа (без паролей и данных заявки).
 */
function ferz_smtp_send(array $smtp, string $from, string $to, array $headers, string $body): string
{
    // На части хостингов сетевые функции отключены (в PHP 8 вызов отключённой — фатальная ошибка)
    if (!function_exists('stream_socket_client') || !function_exists('stream_socket_enable_crypto')) {
        return 'smtp_functions_disabled';
    }
    $host = (string) ($smtp['host'] ?? '');
    $secure = (string) ($smtp['secure'] ?? 'ssl');
    $port = (int) ($smtp['port'] ?? ($secure === 'tls' ? 587 : ($secure === 'none' ? 25 : 465)));
    $user = (string) ($smtp['user'] ?? '');
    $pass = (string) ($smtp['pass'] ?? '');
    $helo = preg_replace('/[^a-z0-9.\-]/', '', strtolower((string) ($smtp['helo'] ?? 'localhost'))) ?: 'localhost';
    if (preg_match('/[\r\n\0]/', $host . $user . $pass . $from . $to) || !preg_match('/^[a-z0-9.\-]+$/i', $host)) {
        return 'smtp_bad_config';
    }
    if (!in_array($secure, ['ssl', 'tls', 'none'], true)
        || ($secure === 'none' && !in_array($host, ['127.0.0.1', 'localhost'], true))) {
        return 'smtp_bad_config'; // пароль по открытому каналу наружу не отправляем
    }
    // Весь разговор вместе с подключением — не дольше 20 секунд: меньше обычных max_execution_time (30 с)
    // и таймаута веб-сервера, иначе посетитель получит не JSON, а обрыв, хотя письмо, возможно, ушло
    $deadline = microtime(true) + 20;
    $ctx = stream_context_create(['ssl' => ['verify_peer' => true, 'verify_peer_name' => true, 'peer_name' => $host]]);
    $fp = @stream_socket_client(($secure === 'ssl' ? 'ssl://' : 'tcp://') . $host . ':' . $port, $errno, $errstr, 10, STREAM_CLIENT_CONNECT, $ctx);
    if (!$fp) {
        return 'smtp_connect';
    }
    $stage = 'smtp_greeting';
    $done = false;
    do {
        if (!ferz_smtp_cmd($fp, '', [220], $deadline)) {
            break;
        }
        $stage = 'smtp_ehlo';
        if (!ferz_smtp_cmd($fp, 'EHLO ' . $helo, [250], $deadline)) {
            break;
        }
        if ($secure === 'tls') {
            $stage = 'smtp_starttls';
            if (!ferz_smtp_cmd($fp, 'STARTTLS', [220], $deadline)) {
                break;
            }
            // Данные, пришедшие до рукопожатия открытым текстом, иначе читались бы как ответы из шифрованного канала
            $meta = stream_get_meta_data($fp);
            if (!empty($meta['unread_bytes']) || !@stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) {
                break;
            }
            if (!ferz_smtp_cmd($fp, 'EHLO ' . $helo, [250], $deadline)) {
                break;
            }
        }
        $stage = 'smtp_auth';
        if (!ferz_smtp_cmd($fp, 'AUTH LOGIN', [334], $deadline)
            || !ferz_smtp_cmd($fp, base64_encode($user), [334], $deadline)
            || !ferz_smtp_cmd($fp, base64_encode($pass), [235], $deadline)) {
            break;
        }
        $stage = 'smtp_mail_from';
        if (!ferz_smtp_cmd($fp, 'MAIL FROM:<' . $from . '>', [250], $deadline)) {
            break;
        }
        $stage = 'smtp_rcpt';
        if (!ferz_smtp_cmd($fp, 'RCPT TO:<' . $to . '>', [250, 251], $deadline)) {
            break;
        }
        $stage = 'smtp_data';
        if (!ferz_smtp_cmd($fp, 'DATA', [354], $deadline)) {
            break;
        }
        $stage = 'smtp_body';
        $msg = implode("\r\n", $headers) . "\r\n\r\n" . $body;
        $msg = preg_replace('/^\./m', '..', str_replace(["\r\n", "\r", "\n"], "\n", $msg));
        $msg = str_replace("\n", "\r\n", (string) $msg);
        if (@fwrite($fp, $msg . "\r\n.\r\n") === false || !ferz_smtp_cmd($fp, '', [250], $deadline)) {
            break;
        }
        $done = true;
    } while (false);
    @fwrite($fp, "QUIT\r\n");
    fclose($fp);
    return $done ? '' : $stage;
}

/* ---------- 1. Метод ---------- */
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    ferz_respond(405, ['ok' => false, 'error' => 'method_not_allowed'], ['Allow: POST']);
}

/* ---------- 2. Настройки ---------- */
$config = null;
foreach ([dirname(__DIR__) . '/send.config.php', __DIR__ . '/send.config.php'] as $file) {
    if (is_file($file) && is_readable($file)) {
        $config = require $file;
        break;
    }
}
// SMTP — только если заполнены сервер, логин и пароль; иначе письмо уходит через mail(), как раньше
$smtp = is_array($config) && is_array($config['smtp'] ?? null)
    && !empty($config['smtp']['host']) && !empty($config['smtp']['user']) && !empty($config['smtp']['pass'])
    ? $config['smtp'] : null;
if (!$smtp && !empty($config['smtp'])) {
    ferz_log('smtp_config_incomplete');
}
if (!function_exists('mail') && !$smtp) {
    ferz_log('mail_function_disabled'); // хостинг отключил mail() — сайт откроет mailto:
    ferz_respond(503, ['ok' => false, 'error' => 'unavailable']);
}
if (!is_array($config) || !isset($config['to']) || !is_string($config['to']) || !ferz_is_email($config['to'])) {
    ferz_log('config_missing_or_invalid'); // адрес не заполнен — сайт откроет mailto:
    ferz_respond(503, ['ok' => false, 'error' => 'unavailable']);
}
$cfg = $config + [
    'from' => '',
    'envelope_from' => '',
    'allowed_hosts' => [],
    'rate_max' => 3,
    'rate_window' => 600,
    'rate_dir' => '',
    'salt' => '',
    'trust_proxy' => false,
    'smtp' => null,
    'debug' => false,
];

/* ---------- 3. Откуда пришёл запрос (защита от отправки с чужих сайтов) ---------- */
$host = strtolower((string) ($_SERVER['HTTP_HOST'] ?? ''));
$allowed = array_map('strtolower', array_filter((array) $cfg['allowed_hosts'], 'is_string'));
if (!$allowed && $host !== '') {
    $allowed = [$host];
}
$source = (string) ($_SERVER['HTTP_ORIGIN'] ?? '');
if ($source === '' || $source === 'null') {
    $source = (string) ($_SERVER['HTTP_REFERER'] ?? '');
}
$sourceHost = '';
if ($source !== '') {
    $parts = parse_url($source);
    if (is_array($parts) && isset($parts['host'])) {
        $sourceHost = strtolower($parts['host']) . (isset($parts['port']) ? ':' . $parts['port'] : '');
    }
}
if ($sourceHost === '' || !in_array($sourceHost, $allowed, true)) {
    ferz_log('origin_rejected');
    ferz_respond(403, ['ok' => false, 'error' => 'forbidden']);
}

/* ---------- 4. Тело запроса ---------- */
$length = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
if ($length > FERZ_MAX_BODY) {
    ferz_respond(413, ['ok' => false, 'error' => 'too_large']);
}
$contentType = strtolower((string) ($_SERVER['CONTENT_TYPE'] ?? ''));
if (strpos($contentType, 'application/json') === 0) {
    $raw = (string) file_get_contents('php://input', false, null, 0, FERZ_MAX_BODY + 1);
    if (strlen($raw) > FERZ_MAX_BODY) {
        ferz_respond(413, ['ok' => false, 'error' => 'too_large']);
    }
    $input = json_decode($raw, true);
    if (!is_array($input)) {
        ferz_respond(400, ['ok' => false, 'error' => 'bad_request']);
    }
} elseif (strpos($contentType, 'application/x-www-form-urlencoded') === 0 || strpos($contentType, 'multipart/form-data') === 0) {
    $input = $_POST;
} else {
    ferz_respond(415, ['ok' => false, 'error' => 'unsupported_media_type']);
}

/* ---------- 5. Honeypot: бот заполнил скрытое поле — отвечаем «успех», письмо не отправляем ---------- */
if (isset($input['website']) && trim((string) (is_scalar($input['website']) ? $input['website'] : 'x')) !== '') {
    ferz_log('honeypot');
    ferz_respond(200, ['ok' => true]);
}

/* ---------- 6. Ограничение частоты: по IP, в файлах, без БД ----------
   Хранится только хеш IP с солью и время отправок; старые файлы удаляются при обращениях. */
$ip = (string) ($_SERVER['REMOTE_ADDR'] ?? '');
if ($cfg['trust_proxy'] && !empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
    // Берём ПОСЛЕДНИЙ адрес: его дописал наш прокси. Первые клиент может подставить сам.
    $chain = explode(',', (string) $_SERVER['HTTP_X_FORWARDED_FOR']);
    $last = trim((string) end($chain));
    if (filter_var($last, FILTER_VALIDATE_IP) !== false) {
        $ip = $last;
    }
}
// IPv6: один абонент обычно получает целую сеть /64 — считаем по ней, иначе лимит обходится сменой адреса
if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false) {
    $bin = @inet_pton($ip);
    if (is_string($bin) && strlen($bin) === 16) {
        $ip = substr($bin, 0, 12) === str_repeat("\0", 10) . "\xff\xff"
            ? (string) inet_ntop(substr($bin, 12))          // ::ffff:1.2.3.4 — это IPv4
            : bin2hex(substr($bin, 0, 8)) . '::/64';
    }
}
$rateDir = is_string($cfg['rate_dir']) && $cfg['rate_dir'] !== '' ? $cfg['rate_dir'] : rtrim(sys_get_temp_dir(), '/\\') . '/ferz-send-rate';
$rateMax = max(1, (int) $cfg['rate_max']);
$rateWindow = max(10, (int) $cfg['rate_window']);
$now = time();
$rateFile = null;
$rateHandle = null;
$stamps = [];
if (!is_dir($rateDir) && !@mkdir($rateDir, 0700, true) && !is_dir($rateDir)) {
    ferz_log('rate_dir_unavailable'); // не блокируем заявку из-за файловой системы
} else {
    // Соль не задана (или осталась из примера) — без секретной соли хеш IPv4 перебирается за минуты.
    // Тогда один раз создаём случайную соль рядом со счётчиками (.php: по HTTP отдаёт пустой ответ).
    $salt = is_string($cfg['salt']) ? $cfg['salt'] : '';
    if (strlen($salt) < 16 || strpos($salt, 'замените') !== false) {
        $saltFile = $rateDir . '/salt.php';
        $saved = is_file($saltFile) ? @include $saltFile : null;
        if (is_string($saved) && strlen($saved) >= 32) {
            $salt = $saved;
        } else {
            $salt = bin2hex(random_bytes(32));
            $tmp = $saltFile . '.' . bin2hex(random_bytes(8)) . '.tmp';
            if (@file_put_contents($tmp, "<?php return '" . $salt . "';\n") !== false) {
                if (function_exists('chmod')) {
                    @chmod($tmp, 0600);
                }
                // link() атомарен и не перезаписывает: при одновременных первых заявках соль у всех одна.
                // function_exists: на части хостингов link() отключён (в PHP 8 вызов отключённой функции — фатальная ошибка)
                if (!(function_exists('link') && @link($tmp, $saltFile))) {
                    clearstatcache(true, $saltFile);
                    $saved = is_file($saltFile) ? @include $saltFile : null;
                    if (is_string($saved) && strlen($saved) >= 32) {
                        $salt = $saved;
                    } else {
                        @rename($tmp, $saltFile); // файловая система без жёстких ссылок
                    }
                }
                @unlink($tmp);
            }
        }
    }
    $rateFile = $rateDir . '/' . hash('sha256', $salt . '|' . $ip) . '.json';
    $rateHandle = ferz_rate_open($rateFile);
    if ($rateHandle === false) {
        ferz_log('rate_file_contended');
        ferz_respond(503, ['ok' => false, 'error' => 'unavailable']);
    }
    if ($rateHandle) {
        if (function_exists('chmod')) {
            @chmod($rateFile, 0600);
        }
        $stamps = json_decode((string) stream_get_contents($rateHandle), true);
        $stamps = is_array($stamps) ? array_values(array_filter($stamps, function ($t) use ($now, $rateWindow) {
            return is_int($t) && $t > $now - $rateWindow;
        })) : [];
        if (count($stamps) >= $rateMax) {
            $retry = max(1, min($stamps) + $rateWindow - $now);
            ferz_rate_close($rateHandle, $rateFile);
            ferz_log('rate_limited');
            ferz_respond(429, ['ok' => false, 'error' => 'rate_limited', 'retryAfter' => $retry], ['Retry-After: ' . $retry]);
        }
    } else {
        ferz_log('rate_file_unavailable');
    }
    // Уборка при каждом обращении: удаляем файлы, у которых окно закончилось.
    // Только под блокировкой (LOCK_NB): файл, с которым сейчас работает другая заявка, не трогаем.
    foreach ((array) glob($rateDir . '/*.json') as $old) {
        if (!is_string($old) || $old === $rateFile || @filemtime($old) >= $now - $rateWindow) {
            continue;
        }
        $oh = @fopen($old, 'r');
        if ($oh && flock($oh, LOCK_EX | LOCK_NB)) {
            clearstatcache(true, $old);
            if (@filemtime($old) < $now - $rateWindow) {
                @unlink($old);
            }
            flock($oh, LOCK_UN);
        }
        if ($oh) {
            fclose($oh);
        }
    }
}

/* ---------- 7. Проверка полей (те же правила, что в js/main.js) ---------- */
$name = ferz_clean($input['name'] ?? '', true);
$contact = ferz_clean($input['contact'] ?? '', true);
$type = ferz_clean($input['type'] ?? '', true);
$message = ferz_clean($input['message'] ?? '', false);
$consentRaw = $input['consent'] ?? false;
$consent = $consentRaw === true || in_array(is_scalar($consentRaw) ? strtolower((string) $consentRaw) : '', ['1', 'on', 'true', 'yes'], true);

$errors = [];
if ($name === null || $contact === null || $type === null || $message === null) {
    ferz_rate_close($rateHandle, $rateFile);
    ferz_respond(400, ['ok' => false, 'error' => 'bad_encoding']);
}
if ($name === '') {
    $errors['name'] = 'Напишите, как к вам обращаться.';
} elseif (ferz_len($name) < 2) {
    $errors['name'] = 'Слишком коротко — хотя бы 2 буквы.';
} elseif (ferz_len($name) > 80) {
    $errors['name'] = 'Слишком длинно — не больше 80 символов.';
}

$isEmail = (bool) preg_match('/^[^\s@<>()[\]\\\\,;:"]+@[^\s@<>()[\]\\\\,;:"]+\.[^\s@<>()[\]\\\\,;:"]{2,}$/u', $contact);
$isTg = (bool) preg_match('/^@?[a-zA-Z][a-zA-Z0-9_]{4,31}$/', $contact)
    || (bool) preg_match('#^(https?://)?t\.me/[a-zA-Z0-9_]{5,32}$#', $contact);
if ($contact === '') {
    $errors['contact'] = 'Нужна почта или Telegram, иначе я не смогу ответить.';
} elseif (ferz_len($contact) > 120 || (!$isEmail && !$isTg)) {
    $errors['contact'] = 'Похоже на опечатку. Пример: name@mail.ru или @username.';
}

if ($message === '') {
    $errors['message'] = 'Опишите задачу хотя бы в одной фразе.';
} elseif (ferz_len($message) < 10) {
    $errors['message'] = 'Чуть подробнее, пожалуйста — от 10 символов.';
} elseif (ferz_len($message) > 1000) {
    $errors['message'] = 'Слишком длинно — не больше 1000 символов.';
}

if (!$consent) {
    $errors['consent'] = 'Без согласия я не смогу обработать заявку.';
}
if (!in_array($type, FERZ_TYPES, true)) {
    $type = 'Другое';
}

if ($errors) {
    ferz_rate_close($rateHandle, $rateFile);
    ferz_log('validation_failed');
    ferz_respond(422, ['ok' => false, 'error' => 'validation', 'fields' => $errors]);
}

/* ---------- 8. Письмо ---------- */
$siteHost = preg_replace('/[^a-z0-9.\-]/', '', explode(':', $host)[0]);
$subject = ferz_header_text('Заявка с сайта: ' . $type);
$body = implode("\r\n", [
    'Имя: ' . $name,
    'Контакт для ответа: ' . $contact,
    'Что нужно: ' . $type,
    '',
    'Задача:',
    str_replace("\n", "\r\n", $message),
    '',
    '— Отправлено через форму на сайте ' . ($siteHost !== '' ? $siteHost : '') . '. Согласие на обработку данных дано.',
]);

$from = is_string($cfg['from']) && ferz_is_email($cfg['from']) ? $cfg['from'] : '';
if ($from === '' && $smtp && ferz_is_email((string) $smtp['user'])) {
    $from = (string) $smtp['user']; // большинство SMTP-серверов принимают только адрес своего ящика
}
if ($from === '' && $siteHost !== '' && strpos($siteHost, '.') !== false) {
    $from = 'no-reply@' . $siteHost;
}
$headers = [
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    'X-Mailer: ferz-site',
];
if ($from !== '') {
    $headers[] = 'From: ' . ferz_header_text('Сайт Ferz') . ' <' . $from . '>';
}
if ($isEmail && ferz_is_email($contact)) {
    $headers[] = 'Reply-To: ' . $contact; // уже без переводов строк и проверен filter_var
}

// Адрес отправителя конверта (-f): только простые символы — mail() передаёт его в sendmail через оболочку
$params = '';
if (is_string($cfg['envelope_from']) && preg_match('/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/', $cfg['envelope_from'])) {
    $params = '-f' . $cfg['envelope_from'];
}

if ($smtp) {
    $smtpHeaders = array_merge([
        'Date: ' . date('r'),
        'Message-ID: <' . bin2hex(random_bytes(12)) . '@' . ($siteHost !== '' ? $siteHost : 'localhost') . '>',
        'To: ' . $cfg['to'],
        'Subject: ' . $subject,
    ], $headers);
    $smtpFail = ferz_smtp_send($smtp, $from, $cfg['to'], $smtpHeaders, chunk_split(base64_encode($body)));
    $sent = $smtpFail === '';
    if (!$sent) {
        ferz_log($smtpFail);
    }
} else {
    $sent = $params !== ''
        ? mail($cfg['to'], $subject, chunk_split(base64_encode($body)), implode("\r\n", $headers), $params)
        : mail($cfg['to'], $subject, chunk_split(base64_encode($body)), implode("\r\n", $headers));
}

if (!$sent) {
    ferz_rate_close($rateHandle, $rateFile);
    ferz_log($smtp ? 'smtp_failed' : 'mail_failed');
    $fail = ['ok' => false, 'error' => 'unavailable'];
    if (!empty($cfg['debug'])) {
        $fail['stage'] = $smtp ? $smtpFail : 'mail_failed'; // только код этапа; включать на время настройки
    }
    ferz_respond(502, $fail);
}

if ($rateHandle) {
    $stamps[] = $now;
    ftruncate($rateHandle, 0);
    rewind($rateHandle);
    fwrite($rateHandle, json_encode($stamps));
    fflush($rateHandle);
    flock($rateHandle, LOCK_UN);
    fclose($rateHandle);
}
ferz_log('sent');
ferz_respond(200, ['ok' => true]);
