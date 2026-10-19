<?php
// Роутер для `php -S` (локальная разработка): отдаёт ТОЛЬКО файлы сайта и выполняет send.php.
// Всё служебное (send.config.php, .git, *.md, tools, src-images, .dev-mail) получает 404, потому что
// сервер слушает локальную сеть. Запуск: npm start.
$root = dirname(__DIR__, 2);
$path = rawurldecode(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/');
if (strpos($path, "\0") !== false) {
    http_response_code(400);
    exit;
}
$rel = ltrim($path, '/');
if ($rel === '') {
    $rel = 'index.html';
}
$segments = explode('/', $rel);
$publicRoot = ['index.html', 'privacy.html', 'robots.txt', 'sitemap.xml', 'send.php'];
$publicDirs = ['css', 'js', 'assets'];
$ok = count($segments) === 1
    ? in_array($segments[0], $publicRoot, true)
    : in_array($segments[0], $publicDirs, true)
        && !preg_grep('/^\./', $segments)
        && !in_array('..', $segments, true)
        && !preg_match('/\.(php|md|sh|log|mjs)$/i', $rel);
$file = realpath("$root/$rel");
if (!$ok || $file === false || strpos($file, $root . DIRECTORY_SEPARATOR) !== 0 || !is_file($file)) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Not Found';
    return true;
}
if ($rel === 'send.php') {
    require $file; // выполняем PHP
    return true;
}
$types = [
    'html' => 'text/html; charset=utf-8', 'css' => 'text/css; charset=utf-8', 'js' => 'text/javascript; charset=utf-8',
    'svg' => 'image/svg+xml', 'png' => 'image/png', 'jpg' => 'image/jpeg', 'webp' => 'image/webp', 'avif' => 'image/avif',
    'ico' => 'image/x-icon', 'woff2' => 'font/woff2', 'txt' => 'text/plain; charset=utf-8', 'xml' => 'application/xml; charset=utf-8',
];
$ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));
header('Content-Type: ' . ($types[$ext] ?? 'application/octet-stream'));
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
readfile($file);
return true;
