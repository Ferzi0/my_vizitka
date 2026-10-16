/* Выполняется синхронно в <head>: ставит тему до первой отрисовки (без мигания)
   и помечает документ классом .js для прогрессивного улучшения. */
(function () {
  var root = document.documentElement;
  root.classList.add('js');
  var saved = null;
  try {
    saved = window.localStorage.getItem('theme');
  } catch (e) { /* хранилище недоступно — используем системную тему */ }
  if (saved === 'light' || saved === 'dark') {
    root.setAttribute('data-theme', saved);
  }
  // Страховка: если main.js не загрузился или не запустился (сбой сети, блокировщик),
  // снимаем .js — иначе мобильное меню осталось бы без кнопки.
  window.addEventListener('load', function () {
    if (!root.classList.contains('js-ready')) root.classList.remove('js');
  });
})();
