/* Ferz — Эдуард Торгашов: взаимодействия страницы.
   Без зависимостей. Каждый модуль изолирован: ошибка в одном не ломает остальные.
   Этап 1–2: тема, меню, шапка, копирование, базовая форма (mailto).
   Этап 3 добавит прогрессию: --progress на <html>, --section-progress на .section-move,
   --q-file/--q-rank и .queen-layer__move для «идущего ферзя» (см. комментарий в начале main.css). */
(function () {
  'use strict';

  var root = document.documentElement;
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  function safe(name, fn) {
    try { fn(); } catch (err) {
      // Не шумим в консоли в продакшене, но оставляем след для отладки.
      if (window.console && console.debug) console.debug('[' + name + ']', err);
    }
  }

  /* ---------- Тема ---------- */
  function initTheme() {
    var btn = document.querySelector('.theme-toggle');
    if (!btn) return;
    var media = window.matchMedia('(prefers-color-scheme: dark)');
    var metaLight = document.querySelector('meta[name="theme-color"][media*="light"]');
    var metaDark = document.querySelector('meta[name="theme-color"][media*="dark"]');

    function current() {
      var t = root.getAttribute('data-theme');
      if (t === 'light' || t === 'dark') return t;
      return media.matches ? 'dark' : 'light';
    }
    function sync() {
      var isDark = current() === 'dark';
      btn.setAttribute('aria-label', isDark ? 'Включить светлую тему' : 'Включить тёмную тему');
      btn.title = isDark ? 'Светлая тема' : 'Тёмная тема';
      // Цвет панели браузера следует за выбранной темой
      var color = isDark ? '#150809' : '#f9f3ea'; // = --bg тем (см. main.css)
      if (metaLight) metaLight.setAttribute('content', root.hasAttribute('data-theme') ? color : '#f9f3ea');
      if (metaDark) metaDark.setAttribute('content', root.hasAttribute('data-theme') ? color : '#150809');
    }
    btn.hidden = false;
    btn.addEventListener('click', function () {
      var next = current() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { window.localStorage.setItem('theme', next); } catch (e) { /* приватный режим — тема не запомнится */ }
      sync();
    });
    if (media.addEventListener) media.addEventListener('change', sync);
    sync();
  }

  /* ---------- Мобильное меню ---------- */
  function initNav() {
    var toggle = document.querySelector('.nav-toggle');
    var nav = document.getElementById('site-nav');
    if (!toggle || !nav) return;
    var desktop = window.matchMedia('(min-width: 64em)');
    toggle.hidden = false;

    function isOpen() { return toggle.getAttribute('aria-expanded') === 'true'; }
    function open() {
      toggle.setAttribute('aria-expanded', 'true');
      nav.classList.add('is-open');
      var first = nav.querySelector('a');
      if (first) first.focus();
    }
    function close(returnFocus) {
      toggle.setAttribute('aria-expanded', 'false');
      nav.classList.remove('is-open');
      if (returnFocus) toggle.focus();
    }
    function onViewport() {
      // Закрытое мобильное меню скрыто через visibility: hidden — оно вне порядка
      // фокуса и дерева доступности, inert не нужен (и мешал бы переходу по якорю).
      if (desktop.matches && isOpen()) close(false);
    }

    toggle.addEventListener('click', function () { isOpen() ? close(false) : open(); });
    nav.addEventListener('click', function (e) {
      if (e.target.closest('a') && !desktop.matches) close(false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && isOpen()) close(true);
    });
    document.addEventListener('click', function (e) {
      if (isOpen() && !nav.contains(e.target) && !toggle.contains(e.target)) close(false);
    });
    // Фокус ушёл за пределы меню (Tab с последнего пункта) — закрываем
    nav.addEventListener('focusout', function (e) {
      if (isOpen() && e.relatedTarget && !nav.contains(e.relatedTarget) && e.relatedTarget !== toggle) close(false);
    });
    if (desktop.addEventListener) desktop.addEventListener('change', onViewport);
    onViewport();
  }

  /* ---------- Шапка: тень при прокрутке + активный пункт меню ---------- */
  function initHeader() {
    var header = document.querySelector('.site-header');
    if (header) {
      var ticking = false;
      var update = function () {
        header.classList.toggle('is-scrolled', window.scrollY > 8);
        ticking = false;
      };
      window.addEventListener('scroll', function () {
        if (!ticking) { ticking = true; window.requestAnimationFrame(update); }
      }, { passive: true });
      window.requestAnimationFrame(update); // не читаем scrollY синхронно при старте (лишний reflow)
    }

    if (!('IntersectionObserver' in window)) return;
    var links = Array.prototype.slice.call(document.querySelectorAll('.site-nav__list a[href^="#"]'));
    var map = {};
    links.forEach(function (a) {
      var id = a.getAttribute('href').slice(1);
      var sec = document.getElementById(id);
      if (sec) map[id] = a;
    });
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var link = map[entry.target.id];
        if (!link) return;
        if (entry.isIntersecting) {
          links.forEach(function (l) { l.removeAttribute('aria-current'); });
          link.setAttribute('aria-current', 'true');
        } else if (link.getAttribute('aria-current')) {
          link.removeAttribute('aria-current');
        }
      });
    }, { rootMargin: '-45% 0px -50% 0px' });
    Object.keys(map).forEach(function (id) { spy.observe(document.getElementById(id)); });
  }

  /* ---------- Появление блоков ---------- */
  function initReveal() {
    var items = document.querySelectorAll('.reveal');
    if (!items.length) return;
    if (reduceMotion.matches || !('IntersectionObserver' in window)) {
      Array.prototype.forEach.call(items, function (el) { el.classList.add('is-visible'); });
      return;
    }
    // Небольшая лесенка для соседних элементов в одной группе
    var groups = new Map();
    Array.prototype.forEach.call(items, function (el) {
      var parent = el.parentElement;
      var i = groups.get(parent) || 0;
      groups.set(parent, i + 1);
      if (i > 0) el.style.setProperty('--reveal-delay', Math.min(i, 5) * 70 + 'ms');
    });
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    Array.prototype.forEach.call(items, function (el) { io.observe(el); });
  }

  /* ---------- Копирование адреса ---------- */
  function initCopy() {
    var status = document.querySelector('.copy-status');
    var buttons = document.querySelectorAll('[data-copy]');
    Array.prototype.forEach.call(buttons, function (btn) {
      btn.hidden = false;
      var label = btn.textContent;
      var timer;
      btn.addEventListener('click', function () {
        var text = btn.getAttribute('data-copy') || '';
        copyText(text).then(function () {
          btn.textContent = 'Скопировано';
          btn.classList.add('is-done');
          if (status) status.textContent = 'Адрес ' + text + ' скопирован в буфер обмена.';
        }, function () {
          if (status) status.textContent = 'Не получилось скопировать. Адрес: ' + text;
        });
        clearTimeout(timer);
        timer = setTimeout(function () {
          btn.textContent = label;
          btn.classList.remove('is-done');
          if (status) status.textContent = '';
        }, 2400);
      });
    });
  }
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var prevFocus = document.activeElement;
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.className = 'visually-hidden';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      if (prevFocus && prevFocus.focus) prevFocus.focus(); // не теряем фокус клавиатуры
      ok ? resolve() : reject(new Error('copy failed'));
    });
  }

  /* ---------- Форма: валидация и сборка письма ---------- */
  function initForm() {
    var form = document.getElementById('brief-form');
    if (!form) return;
    var TO = 'hello@example.com'; // [ЗАПОЛНИТЬ: почта]
    var COOLDOWN_MS = 30000;
    var KEY = 'brief-last-sent';
    var status = form.querySelector('.form__status');
    var startedAt = Date.now();
    // Встроенную проверку браузера отключаем только с JS: без JS работают required
    // (в том числе обязательное согласие), с JS — своя валидация с понятными текстами.
    form.noValidate = true;

    var fields = {
      name: form.elements.namedItem('name'),
      contact: form.elements.namedItem('contact'),
      message: form.elements.namedItem('message'),
      consent: form.elements.namedItem('consent'),
      website: form.elements.namedItem('website')
    };

    // Убираем управляющие и невидимые символы, схлопываем пробелы, режем длину
    var CONTROL_CHARS = new RegExp('[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F\\u200B-\\u200F\\u2028\\u2029\\u202A-\\u202E]', 'g');
    function clean(value, max) {
      return String(value || '')
        .replace(CONTROL_CHARS, '')
        .replace(/[ \t]+/g, ' ')
        .trim()
        .slice(0, max);
    }
    // Однострочные поля: переводы строк превращаем в пробел, чтобы нельзя было
    // подделать строки письма («Контакт для ответа: …») через вставку текста
    function cleanLine(value, max) {
      return clean(String(value || '').replace(/[\r\n]+/g, ' '), max);
    }
    var EMAIL = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:"]{2,}$/;
    var TG = /^@?[a-zA-Z][a-zA-Z0-9_]{4,31}$/;

    function validators() {
      return {
        name: function (v) {
          if (!v) return 'Напишите, как к вам обращаться.';
          if (v.length < 2) return 'Слишком коротко — хотя бы 2 буквы.';
          return '';
        },
        contact: function (v) {
          if (!v) return 'Нужна почта или Telegram, иначе я не смогу ответить.';
          if (!EMAIL.test(v) && !TG.test(v) && !/^(https?:\/\/)?t\.me\/[a-zA-Z0-9_]{5,32}$/.test(v)) {
            return 'Похоже на опечатку. Пример: name@mail.ru или @username.';
          }
          return '';
        },
        message: function (v) {
          if (!v) return 'Опишите задачу хотя бы в одной фразе.';
          if (v.length < 10) return 'Чуть подробнее, пожалуйста — от 10 символов.';
          return '';
        }
      };
    }

    function setError(input, msg) {
      var err = document.getElementById(input.id + '-err');
      if (err) err.textContent = msg; // textContent — никакого HTML из пользовательских данных
      if (msg) input.setAttribute('aria-invalid', 'true');
      else input.removeAttribute('aria-invalid');
    }

    function validateField(key) {
      var input = fields[key];
      var v = clean(input.value, Number(input.getAttribute('maxlength')) || 2000);
      var msg = validators()[key](v);
      setError(input, msg);
      return msg;
    }
    function validateConsent() {
      var msg = fields.consent.checked ? '' : 'Без согласия я не смогу обработать заявку.';
      setError(fields.consent, msg);
      return msg;
    }

    ['name', 'contact', 'message'].forEach(function (key) {
      var input = fields[key];
      input.addEventListener('blur', function () { if (input.value) validateField(key); });
      input.addEventListener('input', function () {
        if (input.getAttribute('aria-invalid') === 'true') validateField(key);
      });
    });
    fields.consent.addEventListener('change', function () {
      if (fields.consent.getAttribute('aria-invalid') === 'true') validateConsent();
    });

    function say(text, kind) {
      status.textContent = text;
      status.classList.remove('is-ok', 'is-err');
      if (kind) status.classList.add(kind);
    }

    var lastSentMem = 0;
    function lastSent() {
      var stored = 0;
      try { stored = Number(window.sessionStorage.getItem(KEY)) || 0; } catch (e) { /* хранилище недоступно */ }
      return Math.max(stored, lastSentMem);
    }
    function markSent() {
      lastSentMem = Date.now();
      try { window.sessionStorage.setItem(KEY, String(lastSentMem)); } catch (e) { /* ignore */ }
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();

      // Honeypot: боты заполняют скрытое поле. Делаем вид, что всё прошло.
      if (fields.website && fields.website.value) {
        say('Спасибо! Письмо подготовлено.', 'is-ok');
        form.reset();
        return;
      }
      // Слишком быстрое заполнение — признак автоматики
      if (Date.now() - startedAt < 2500) {
        say('Секунду — проверьте, пожалуйста, поля и отправьте ещё раз.', 'is-err');
        return;
      }
      // Ограничение частоты
      var since = Date.now() - lastSent();
      if (since < COOLDOWN_MS) {
        say('Письмо уже подготовлено. Повторно можно через ' + Math.ceil((COOLDOWN_MS - since) / 1000) + ' с.', 'is-err');
        return;
      }

      var errors = ['name', 'contact', 'message'].map(validateField);
      errors.push(validateConsent());
      var firstBad = ['name', 'contact', 'message', 'consent'].filter(function (k, i) { return errors[i]; })[0];
      if (firstBad) {
        say('Проверьте отмеченные поля.', 'is-err');
        fields[firstBad].focus();
        return;
      }

      var typeInput = form.querySelector('input[name="type"]:checked');
      var data = {
        name: cleanLine(fields.name.value, 80),
        contact: cleanLine(fields.contact.value, 120),
        type: typeInput ? cleanLine(typeInput.value, 60) : '',
        message: clean(fields.message.value, 1000)
      };
      var subject = 'Заявка с сайта: ' + data.type;
      var body = [
        'Имя: ' + data.name,
        'Контакт для ответа: ' + data.contact,
        'Что нужно: ' + data.type,
        '',
        'Задача:',
        data.message,
        '',
        '— Отправлено через форму на сайте. Согласие на обработку данных дано.'
      ].join('\r\n');

      var href = 'mailto:' + TO +
        '?subject=' + encodeURIComponent(subject) +
        '&body=' + encodeURIComponent(body);

      markSent();
      say('Открываю почтовую программу… Если ничего не произошло, напишите напрямую на ' + TO + ' или в Telegram.', 'is-ok');
      window.location.href = href;
    });
  }

  /* ---------- Мелочи ---------- */
  function initYear() {
    var el = document.querySelector('.js-year');
    if (el) el.textContent = String(new Date().getFullYear());
  }

  function boot() {
    root.classList.add('js-ready'); // см. страховку в theme-init.js
    safe('theme', initTheme);
    safe('nav', initNav);
    safe('header', initHeader);
    safe('reveal', initReveal);
    safe('copy', initCopy);
    safe('form', initForm);
    safe('year', initYear);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
