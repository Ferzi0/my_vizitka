/* Ferz — взаимодействия страницы. Без зависимостей; ошибка в одном модуле не ломает остальные.
   Тема, меню, прогрессия «ход ферзя», кнопка «Наверх», слайдер скриншотов, появление блоков,
   копирование, форма (send.php → mailto:), аналитика track(). */
(function () {
  'use strict';

  var root = document.documentElement;
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  var MAIL = 'eduardtor1@yandex.ru'; // [ЗАПОЛНИТЬ: почта] — та же, что в разметке

  function safe(name, fn) {
    try { fn(); } catch (err) {
      if (window.console && console.debug) console.debug('[' + name + ']', err);
    }
  }
  function onChange(mq, fn) {
    if (mq.addEventListener) mq.addEventListener('change', fn);
    else if (mq.addListener) mq.addListener(fn);
  }

  /* ---------- Аналитика: по умолчанию ничего не делает и не грузит ----------
     Подключите в index.html один сервис без cookie (ANALYTICS.md) — события уйдут в него.
     Передаётся только имя события, без данных формы. */
  function track(name) {
    try {
      var w = window;
      if (typeof w.plausible === 'function') w.plausible(name);
      else if (w.umami && typeof w.umami.track === 'function') w.umami.track(name);
      else if (w.goatcounter && typeof w.goatcounter.count === 'function') w.goatcounter.count({ path: name, title: name, event: true });
    } catch (e) { /* аналитика не ломает страницу */ }
  }
  function initTrackLinks() {
    document.addEventListener('click', function (e) {
      var a = e.target.closest ? e.target.closest('a[href]') : null;
      if (!a) return;
      var href = a.getAttribute('href') || '';
      if (href === '#contact') track('cta_discuss');
      else if (href.indexOf('mailto:') === 0) track('contact_email');
      else if (/^https:\/\/t\.me\/\w+bot\b/i.test(href)) track('contact_bot');
      else if (href.indexOf('https://t.me/') === 0) track('contact_telegram');
    });
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
    // Цвет панели браузера = --bg темы. Берётся из токенов палитры (--n-50 / --n-950 в main.css),
    // поэтому при смене сезона следует за ним сам. Значения в <meta> HTML — только для первой
    // отрисовки до JS (и для privacy.html): при смене сезона их нужно поправить руками.
    var BG = { light: tokenHex('--n-50', '#f9f3ea'), dark: tokenHex('--n-950', '#150809') };
    function sync() {
      var isDark = current() === 'dark';
      btn.setAttribute('aria-label', isDark ? 'Включить светлую тему' : 'Включить тёмную тему');
      btn.title = isDark ? 'Светлая тема' : 'Тёмная тема';
      var color = isDark ? BG.dark : BG.light;
      if (metaLight) metaLight.setAttribute('content', root.hasAttribute('data-theme') ? color : BG.light);
      if (metaDark) metaDark.setAttribute('content', root.hasAttribute('data-theme') ? color : BG.dark);
    }
    btn.hidden = false;
    btn.addEventListener('click', function () {
      var next = current() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { window.localStorage.setItem('theme', next); } catch (e) { /* нет хранилища */ }
      sync();
    });
    onChange(media, sync);
    sync();
  }

  // CSS-цвет токена (oklch и т. п.) → #rrggbb: рисуем точку на canvas и читаем пиксель.
  // Если браузер цвет не понял — запасное значение (осень).
  function tokenHex(name, fallback) {
    try {
      var value = getComputedStyle(root).getPropertyValue(name).trim();
      if (!value) return fallback;
      var c = document.createElement('canvas');
      c.width = c.height = 1;
      var ctx = c.getContext('2d');
      ctx.fillStyle = '#010203';
      ctx.fillStyle = value;
      if (ctx.fillStyle === '#010203') return fallback;
      ctx.fillRect(0, 0, 1, 1);
      var d = ctx.getImageData(0, 0, 1, 1).data;
      return '#' + [d[0], d[1], d[2]].map(function (v) { return (v < 16 ? '0' : '') + v.toString(16); }).join('');
    } catch (e) {
      return fallback;
    }
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
    // Tab ушёл за пределы меню — закрываем
    nav.addEventListener('focusout', function (e) {
      if (isOpen() && e.relatedTarget && !nav.contains(e.relatedTarget) && e.relatedTarget !== toggle) close(false);
    });
    onChange(desktop, onViewport);
    onViewport();
  }

  /* ---------- Общий цикл прокрутки ----------
     Один rAF на кадр и один passive-обработчик scroll на всю страницу. Модули регистрируют
     { measure, frame }: measure читает раскладку (только после resize / ResizeObserver — один раз
     в начале ближайшего кадра, сколько бы событий ни пришло), frame(y) только пишет (CSS-переменные,
     классы) и раскладку не читает — без layout thrash. */
  var loop = (function () {
    var parts = [], queued = false, dirty = true, bound = false;
    function frame() {
      queued = false;
      var i;
      if (dirty) { dirty = false; for (i = 0; i < parts.length; i++) if (parts[i].measure) run(parts[i], 'measure'); }
      var y = window.scrollY;
      for (i = 0; i < parts.length; i++) run(parts[i], 'frame', y);
    }
    // ошибка одного модуля не останавливает остальные
    function run(part, fn, y) {
      try { part[fn](y); } catch (err) { if (window.console && console.debug) console.debug('[loop]', err); }
    }
    function queue() { if (!queued) { queued = true; window.requestAnimationFrame(frame); } }
    function invalidate() { dirty = true; queue(); }
    function bind() {
      if (bound) return;
      bound = true;
      window.addEventListener('scroll', queue, { passive: true });
      window.addEventListener('resize', invalidate, { passive: true });
      if ('ResizeObserver' in window) new ResizeObserver(invalidate).observe(document.body); // шрифты, FAQ, зум
    }
    return {
      // run: сразу посчитать кадр (до первой отрисовки — разделы на первом экране не «мигают»)
      add: function (part, run) { parts.push(part); bind(); dirty = true; if (run) frame(); else queue(); },
      invalidate: invalidate
    };
  })();

  /* ---------- Прогрессия «ход ферзя» ----------
     Разделы .section-move = ходы 1…7 с клетками data-square. В кадре читается только scrollY
     (координаты — из кеша measure), пишутся только CSS-переменные и только при изменении.
     Полоска в шапке и полоса ходов (< 1440 px) — непрерывные: доля реальной прокрутки
     scrollY / (scrollHeight − innerHeight), отметки разделов стоят там, где разделы приходят.
     Мини-доска (≥ 1440 px) — ход ферзя по клеткам, как раньше. reduced-motion: ферзь на доске
     меняет клетку ступенькой, полоски по-прежнему следуют за прокруткой (без анимаций). */
  function initProgress() {
    var secs = Array.prototype.slice.call(document.querySelectorAll('.section-move[data-move]'));
    if (secs.length < 2) return;
    var header = document.querySelector('.site-header');
    // Переменные — на малые поддеревья, не на <html>: не пересчитывать стили всей страницы
    var bar = document.querySelector('.site-header__progress') || root;
    var layer = document.querySelector('.queen-layer') || root;
    var rail = document.querySelector('.move-rail') || root;
    // Наводящие надписи раздела (data-hint): у мини-доски и в шапке вместо имени (< 1440 px)
    var hints = Array.prototype.slice.call(document.querySelectorAll('.move-hint'));
    var hintText = secs.map(function (s) { return s.getAttribute('data-hint') || ''; });
    var ticks = Array.prototype.slice.call(document.querySelectorAll('.move-rail__ticks i'));
    var links = {};
    Array.prototype.forEach.call(document.querySelectorAll('.site-nav__list a[href^="#"]'), function (a) {
      links[a.getAttribute('href').slice(1)] = a;
    });

    // Клетки и длина пути (для «следа» на мини-доске)
    var squares = secs.map(function (s) {
      var sq = (s.getAttribute('data-square') || 'd1').toLowerCase();
      return { f: sq.charCodeAt(0) - 96, r: Number(sq.charAt(1)) || 1 };
    });
    var cum = [0];
    for (var k = 1; k < squares.length; k++) {
      cum[k] = cum[k - 1] + Math.hypot(squares[k].f - squares[k - 1].f, squares[k].r - squares[k - 1].r);
    }
    var total = cum[cum.length - 1] || 1;
    var last = secs.length - 1;

    var tops = [], marks = [], vh = 1, maxY = 1, heroH = 1;
    var written = new Map();
    var active = -1, lit = -1, scrolled = null, still = reduceMotion.matches;

    function put(el, prop, value) {
      var map = written.get(el);
      if (!map) { map = {}; written.set(el, map); }
      var v = Math.round(value * 10000) / 10000;
      if (map[prop] === v) return;
      map[prop] = v;
      el.style.setProperty(prop, String(v));
    }
    function clear(el, prop) {
      var map = written.get(el);
      if (map && prop in map) { delete map[prop]; el.style.removeProperty(prop); }
    }
    function clamp(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
    function ease(t) { return t * t * (3 - 2 * t); }

    var HYST = 0.65;
    // Смена надписи: короткий подъём с проявлением (Web Animations — без перечитывания раскладки);
    // при reduced-motion и в первый раз — сразу. Только textContent.
    function setHint(text, animate) {
      hints.forEach(function (el) {
        el.textContent = text;
        if (animate && !reduceMotion.matches && el.animate) {
          el.animate([{ opacity: 0, transform: 'translateY(0.35em)' }, { opacity: 1, transform: 'none' }],
            { duration: 320, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' });
        }
      });
    }

    function measure() {
      var y = window.scrollY;
      tops = secs.map(function (s) { return s.getBoundingClientRect().top + y; });
      vh = window.innerHeight || 1;
      maxY = Math.max(1, document.documentElement.scrollHeight - vh);
      heroH = secs[0].offsetHeight || vh;
      // Отметка раздела на полосе — доля прокрутки, при которой верх раздела доходит до середины экрана
      // (там же переключается ход); монотонно, последняя не дальше конца полосы
      marks = tops.map(function (t, n) { return n === 0 ? 0 : clamp((t - vh * 0.5) / maxY); });
      for (var n = 1; n < marks.length; n++) if (marks[n] < marks[n - 1]) marks[n] = marks[n - 1];
    }

    function frame(y) {
      var anchor = y + vh * 0.5;

      // Номер хода 0…6 (мини-доска): граница разделов «переводит» ферзя, проходя ±30 % экрана от середины
      var m = 0;
      for (var b = 1; b <= last; b++) m += ease(clamp((anchor - tops[b] + vh * 0.3) / (vh * 0.6)));
      if (y >= maxY - 2) m = last;
      if (still) m = Math.round(m);
      var i = Math.min(Math.floor(m), last - 1), t = m - i;
      var from = squares[i], to = squares[i + 1];

      // Полоски: непрерывно, пропорционально прокрутке
      var p = y >= maxY - 1 ? 1 : clamp(y / maxY);
      put(bar, '--progress', p);
      put(rail, '--rail-p', p);
      ticks.forEach(function (tick, n) { if (n < marks.length) put(tick, '--at', marks[n]); });
      var on = 0;
      for (var n = 1; n < marks.length; n++) if (p >= marks[n] - 0.0005) on = n;
      if (on !== lit) {
        lit = on;
        ticks.forEach(function (tick, n) { tick.classList.toggle('is-on', n <= on); });
      }

      put(layer, '--q-file', from.f + (to.f - from.f) * t);
      put(layer, '--q-rank', from.r + (to.r - from.r) * t);
      put(layer, '--trail', (cum[i] + (cum[i + 1] - cum[i]) * t) / total);

      // Считаются все разделы: у ушедших значение упирается в 0 или 1 и put() его не переписывает.
      if (!still) {
        put(secs[0], '--hero-p', clamp(y / (heroH * 0.85)));
        for (var s = 1; s <= last; s++) {
          put(secs[s], '--section-progress', ease(clamp((y + vh - tops[s]) / (vh * 0.55))));
        }
      }

      var isScrolled = y > 8;
      if (header && isScrolled !== scrolled) { scrolled = isScrolled; header.classList.toggle('is-scrolled', isScrolled); }

      // Текущий раздел с гистерезисом: меняется, только когда ход ушёл от прежнего дальше чем на 0,65
      // (середина перехода — 0,5), — на границе при прокрутке туда-обратно надпись не дребезжит
      var now = Math.min(last, Math.floor(m + 0.5));
      if (now !== active && (active < 0 || Math.abs(m - active) >= HYST || y >= maxY - 2 || y <= 0)) {
        var first = active < 0;
        active = now;
        setHint(hintText[now], !first);
        Object.keys(links).forEach(function (id) {
          if (id === secs[now].id) links[id].setAttribute('aria-current', 'true');
          else links[id].removeAttribute('aria-current');
        });
      }
    }

    onChange(reduceMotion, function () {
      still = reduceMotion.matches;
      if (still) {
        clear(secs[0], '--hero-p');
        secs.forEach(function (s) { clear(s, '--section-progress'); });
      }
      loop.invalidate();
    });
    loop.add({ measure: measure, frame: frame }, true);
  }

  /* ---------- Кнопка «Наверх» ----------
     Без JS её нет (hidden), наверх ведёт ссылка в подвале. Видна, когда первый экран прокручен;
     прячется, если под ней оказались бы ссылки, кнопки, вопросы, форма или подвал (прямоугольники — из кеша measure).
     Нажатие: плавно наверх (reduced-motion — сразу), фокус — в начало документа: следующий Tab
     попадает на «Перейти к содержанию». */
  // Наверх: плавно до scrollY = 0 (reduced-motion — сразу), фокус в начало документа — следующий Tab
  // попадает на «Перейти к содержанию». Общая для круглой кнопки, логотипа и ссылки «Наверх ↑» в подвале.
  function goTop() {
    window.scrollTo({ top: 0, left: 0, behavior: reduceMotion.matches ? 'auto' : 'smooth' });
    var body = document.body;
    body.setAttribute('tabindex', '-1');
    body.addEventListener('blur', function off() {
      body.removeAttribute('tabindex');
      body.removeEventListener('blur', off);
    });
    body.focus({ preventScroll: true });
  }
  function initToTop() {
    // Ссылки href="#top" (логотип, подвал): без JS — переход к фрагменту «top», которого нет на странице, —
    // по стандарту HTML это верх документа. С JS — то же, что кнопка, без «#top» в адресе.
    document.addEventListener('click', function (e) {
      var a = e.target.closest ? e.target.closest('a[href="#top"]') : null;
      if (!a || e.defaultPrevented || e.button > 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      e.preventDefault();
      track('to_top');
      goTop();
    });
    var btn = document.querySelector('.to-top');
    if (!btn) return;
    var hero = document.querySelector('.hero');
    // Зоны, над которыми кнопки быть не должно: всё кликабельное ниже первого экрана (ссылки, кнопки,
    // вопросы FAQ, контакты и форма, подвал). Проверка по горизонтали тоже — на широких экранах кнопка
    // стоит в поле страницы и рядом с ними не прячется.
    var avoid = Array.prototype.slice.call(document.querySelectorAll('.cta-band .btn, .work__more a, .faq__list, .contact__grid, .site-footer'));
    var GAP = 12;
    var heroEnd = 0, zones = [], bx = { top: 0, bottom: 0, left: 0, right: 0 }, shown = null;
    btn.hidden = false;

    function measure() {
      var y = window.scrollY;
      var headerH = 0, header = document.querySelector('.site-header');
      if (header) headerH = header.offsetHeight;
      heroEnd = (hero ? hero.getBoundingClientRect().bottom + y : window.innerHeight) - headerH;
      // offsetTop/Left у position: fixed — от окна и без учёта translate (анимации появления)
      bx = { top: btn.offsetTop, left: btn.offsetLeft, bottom: btn.offsetTop + btn.offsetHeight, right: btn.offsetLeft + btn.offsetWidth };
      zones = avoid.map(function (el) {
        var r = el.getBoundingClientRect();
        return { top: r.top + y, bottom: r.bottom + y, left: r.left, right: r.right };
      });
    }
    function frame(y) {
      var show = y > heroEnd;
      for (var i = 0; show && i < zones.length; i++) {
        var z = zones[i];
        if (z.top - y < bx.bottom + GAP && z.bottom - y > bx.top - GAP && z.left < bx.right + GAP && z.right > bx.left - GAP) show = false;
      }
      if (show !== shown) { shown = show; btn.classList.toggle('is-shown', show); }
    }

    btn.addEventListener('click', function () {
      track('to_top');
      goTop();
    });
    loop.add({ measure: measure, frame: frame }, true);
  }

  /* ---------- Слайдер скриншотов ([data-slides]) ----------
     Без элементов управления — так решил заказчик (STATUS.md, этап 6: осознанное отступление от WCAG 2.2.2).
     Кадр меняется каждые 5 с, только пока карточка на экране и вкладка активна; без JS и при
     reduced-motion — первый кадр. Неактивные кадры — aria-hidden, aria-live нет (смена не объявляется).
     Кадры 2…n без класса .is-live не отображаются (display: none) и не загружаются. */
  function initSlides() {
    if (!('IntersectionObserver' in window)) return;
    Array.prototype.forEach.call(document.querySelectorAll('[data-slides]'), function (box) {
      var slides = Array.prototype.slice.call(box.querySelectorAll('.slide'));
      if (slides.length < 2) return;
      var INTERVAL = 5000, RETRY = 400;
      var cur = 0, timer = 0, visible = false;

      function img(n) { return slides[n].querySelector('img'); }
      function ready(n) { var im = img(n); return !!im && im.complete && im.naturalWidth > 0; }
      function broken(n) { var im = img(n); return !im || (im.complete && !im.naturalWidth && !!im.currentSrc); }
      function running() { return visible && !reduceMotion.matches && document.visibilityState === 'visible'; }
      function stop() { if (timer) { clearTimeout(timer); timer = 0; } }
      function schedule(delay) { stop(); if (running()) timer = setTimeout(tick, delay || INTERVAL); }

      function show(next, animate) {
        var prev = cur;
        cur = next;
        slides.forEach(function (s, n) {
          s.classList.toggle('is-active', n === cur);
          s.classList.toggle('is-prev', n === prev && n !== cur);
          s.classList.toggle('is-entering', n === cur && !!animate);
          if (n === cur) s.removeAttribute('aria-hidden');
          else s.setAttribute('aria-hidden', 'true');
        });
      }
      function tick() {
        timer = 0;
        if (!running()) return;
        var next = (cur + 1) % slides.length;
        // битый кадр (ошибка загрузки) пропускаем, иначе слайдер навсегда встал бы на текущем
        for (var k = 0; k < slides.length - 1 && broken(next); k++) next = (next + 1) % slides.length;
        if (next === cur || broken(next)) return;
        if (!ready(next)) {
          // кадр ещё грузится — подождать его, а не показывать пустую рамку
          var im = img(next);
          if (im && im.loading === 'lazy') im.loading = 'eager';
          schedule(RETRY);
          return;
        }
        show(next, true);
        schedule();
      }
      function setMode() {
        if (reduceMotion.matches) {
          stop();
          show(0, false);
          box.classList.remove('is-live');
        } else {
          box.classList.add('is-live');
          schedule();
        }
      }

      new IntersectionObserver(function (entries) {
        var e = entries[entries.length - 1];
        var now = e.isIntersecting && e.intersectionRatio >= 0.35;
        if (now === visible) return;
        visible = now;
        if (visible) schedule(); else stop();
      }, { threshold: [0, 0.35, 0.6] }).observe(box);
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') schedule(); else stop();
      });
      onChange(reduceMotion, setMode);
      setMode();
    });
  }

  /* ---------- Появление блоков при прокрутке ----------
     Скрываются (класс .rv) только блоки, которые целиком ниже экрана в момент «взвода» — после load,
     когда браузер уже прокрутил к якорю или восстановил позицию. Поэтому видимое при загрузке
     не мигает, а при сбое main.js или reduced-motion скрытых блоков нет вообще. Появляются один раз:
     IntersectionObserver → .rv-in (анимация opacity + translate, своя задержка у блоков одной «пачки»),
     после анимации классы снимаются. Свойство translate не спорит с transform у :hover карточек. */
  var REVEAL = '.move-head__body, .card, .extras, .cta-band, .step, .case, .work__more, .principle, .stack__tile, .qa, .contact__title, .contact__lead, .direct, .bot-cta, .next, .form';
  function initReveal() {
    if (!('IntersectionObserver' in window)) return;
    var els = Array.prototype.slice.call(document.querySelectorAll(REVEAL));
    if (!els.length) return;
    var io = null, STEP = 90, MAX_STEPS = 5;

    function done(e) {
      var el = e.target;
      if (e.animationName !== 'rv-up') return;
      el.classList.remove('rv-in');
      el.style.removeProperty('--rv-d');
      el.removeEventListener('animationend', done);
    }
    function reveal(el, n) {
      if (n) el.style.setProperty('--rv-d', Math.min(n, MAX_STEPS) * STEP + 'ms');
      el.addEventListener('animationend', done);
      el.classList.add('rv-in');
      el.classList.remove('rv');
    }
    function arm() {
      if (io || reduceMotion.matches) return;
      var vh = window.innerHeight;
      // сначала все чтения, потом записи
      var below = els.filter(function (el) { return el.getBoundingClientRect().top > vh; });
      if (!below.length) return;
      io = new IntersectionObserver(function (entries) {
        var n = 0;
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          io.unobserve(e.target);
          reveal(e.target, n++);
        });
      }, { rootMargin: '0px 0px -8% 0px' });
      below.forEach(function (el) { el.classList.add('rv'); io.observe(el); });
    }
    function disarm() {
      if (!io) return;
      io.disconnect();
      io = null;
      els.forEach(function (el) { el.classList.remove('rv', 'rv-in'); el.style.removeProperty('--rv-d'); });
    }
    onChange(reduceMotion, function () { if (reduceMotion.matches) disarm(); });
    window.addEventListener('beforeprint', disarm);
    // Фокус с клавиатуры (Tab, переход к полю) внутри ещё не проявившегося блока — проявить сразу:
    // при прокрутке к фокусу блок может встать в нижние 8 % экрана, куда наблюдатель не смотрит
    document.addEventListener('focusin', function (e) {
      if (!io) return;
      var el = e.target.closest ? e.target.closest('.rv') : null;
      if (el) { io.unobserve(el); reveal(el, 0); }
    });
    // Переход по ссылке-якорю: блоки целевого раздела начинают появляться сразу, пока идёт плавная
    // прокрутка, — к её концу они уже на месте, а не проявляются на глазах после «приземления».
    document.addEventListener('click', function (e) {
      if (!io) return;
      var a = e.target.closest ? e.target.closest('a[href^="#"]') : null;
      var target = a && a.getAttribute('href').length > 1 ? document.getElementById(a.getAttribute('href').slice(1)) : null;
      if (!target) return;
      var n = 0;
      Array.prototype.forEach.call(target.querySelectorAll('.rv'), function (el) { io.unobserve(el); reveal(el, n++); });
    });
    function later() { window.requestAnimationFrame(function () { window.requestAnimationFrame(arm); }); }
    // Открыли адрес с #якорем: браузер плавно едет к разделу уже после load — «взводим» после
    // остановки прокрутки, иначе раздел, к которому приехали, проявлялся бы на глазах
    function afterScroll(fn) {
      var t = 0;
      function finish() { window.removeEventListener('scroll', on); fn(); }
      function on() { clearTimeout(t); t = setTimeout(finish, 200); }
      window.addEventListener('scroll', on, { passive: true });
      t = setTimeout(finish, 450);
    }
    function start() {
      var id = window.location.hash.slice(1), target = null;
      try { target = id && document.getElementById(decodeURIComponent(id)); } catch (err) { target = null; }
      if (target) afterScroll(later); else later();
    }
    if (document.readyState === 'complete') start();
    else window.addEventListener('load', start);
  }

  /* ---------- Кнопки заявки в карточках услуг: выбирают тип проекта в форме ---------- */
  function initOrderButtons() {
    var form = document.getElementById('brief-form');
    if (!form) return;
    Array.prototype.forEach.call(document.querySelectorAll('[data-order]'), function (btn) {
      btn.addEventListener('click', function () {
        var want = btn.getAttribute('data-order');
        Array.prototype.forEach.call(form.querySelectorAll('input[name="type"]'), function (r) {
          if (r.value === want) r.checked = true;
        });
        track('order-' + want);
      });
    });
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
          track('contact_email_copy');
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
      if (prevFocus && prevFocus.focus) prevFocus.focus();
      ok ? resolve() : reject(new Error('copy failed'));
    });
  }

  /* ---------- Форма ----------
     Без JS — action="mailto:…". С JS — fetch на send.php; если сервера нет или ответ не тот
     (статический хостинг, 404/405, 5xx, сеть, таймаут, file://) — письмо через mailto:. */
  function initForm() {
    var form = document.getElementById('brief-form');
    if (!form) return;
    var TIMEOUT_MS = 10000;
    var COOLDOWN_MS = 30000;
    var KEY = 'brief-last-sent';
    var status = form.querySelector('.form__status');
    if (!status) { // разметку поменяли — без строки статуса форма не должна молча ломаться
      status = document.createElement('p');
      status.className = 'form__status';
      status.setAttribute('role', 'status');
      form.appendChild(status);
    }
    var startedAt = Date.now();
    var busy = false;
    // Без JS работают required; с JS — своя валидация с понятными текстами
    form.noValidate = true;

    var fields = {
      name: form.elements.namedItem('name'),
      contact: form.elements.namedItem('contact'),
      message: form.elements.namedItem('message'),
      consent: form.elements.namedItem('consent'),
      website: form.elements.namedItem('website')
    };
    var ORDER = ['name', 'contact', 'message', 'consent'];

    // Без управляющих и невидимых символов
    var CONTROL_CHARS = new RegExp('[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F\\u200B-\\u200F\\u2028\\u2029\\u202A-\\u202E]', 'g');
    function clean(value, max) {
      return String(value || '')
        .replace(CONTROL_CHARS, '')
        .replace(/[ \t]+/g, ' ')
        .trim()
        .slice(0, max);
    }
    // Однострочные: перевод строки → пробел (не подделать строки письма)
    function cleanLine(value, max) {
      return clean(String(value || '').replace(/[\r\n]+/g, ' '), max);
    }
    // Те же правила проверяет send.php
    var EMAIL = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:"]{2,}$/;
    var TG = /^@?[a-zA-Z][a-zA-Z0-9_]{4,31}$/;
    var TG_LINK = /^(https?:\/\/)?t\.me\/[a-zA-Z0-9_]{5,32}$/;

    var validators = {
      name: function (v) {
        if (!v) return 'Напишите, как к вам обращаться.';
        if (v.length < 2) return 'Слишком коротко — хотя бы 2 буквы.';
        return '';
      },
      contact: function (v) {
        if (!v) return 'Нужна почта или Telegram, иначе я не смогу ответить.';
        if (!EMAIL.test(v) && !TG.test(v) && !TG_LINK.test(v)) return 'Похоже на опечатку. Пример: name@mail.ru или @username.';
        return '';
      },
      message: function (v) {
        if (!v) return 'Опишите задачу хотя бы в одной фразе.';
        if (v.length < 10) return 'Чуть подробнее, пожалуйста — от 10 символов.';
        return '';
      }
    };

    function setError(input, msg) {
      var err = document.getElementById(input.id + '-err');
      if (err) err.textContent = msg; // только textContent — никакого HTML
      if (msg) input.setAttribute('aria-invalid', 'true');
      else input.removeAttribute('aria-invalid');
    }
    function validateField(key) {
      var input = fields[key];
      var msg = validators[key](clean(input.value, Number(input.getAttribute('maxlength')) || 2000));
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
      try { stored = Number(window.sessionStorage.getItem(KEY)) || 0; } catch (e) { /* нет хранилища */ }
      return Math.max(stored, lastSentMem);
    }
    function markSent() {
      lastSentMem = Date.now();
      try { window.sessionStorage.setItem(KEY, String(lastSentMem)); } catch (e) { /* ignore */ }
    }

    // { ok: true } | { ok: false, error, fields?, retryAfter? }; не JSON (404, HTML, исходник PHP) — «сервера нет»
    function post(data) {
      var endpoint = form.getAttribute('data-endpoint'); // нет (хостинг без PHP) — сразу mailto:
      if (!endpoint || !/^https?:$/.test(window.location.protocol) || !window.fetch) return Promise.reject(new Error('no-server'));
      var ctrl = window.AbortController ? new AbortController() : null;
      var timer = setTimeout(function () { if (ctrl) ctrl.abort(); }, TIMEOUT_MS);
      return fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify(data),
        credentials: 'same-origin',
        cache: 'no-store',
        redirect: 'error',
        signal: ctrl ? ctrl.signal : undefined
      }).then(function (res) {
        if ((res.headers.get('Content-Type') || '').indexOf('application/json') === -1) throw new Error('not-json');
        return res.json().then(function (body) {
          clearTimeout(timer);
          if (!body || typeof body !== 'object') throw new Error('bad-json');
          return { status: res.status, body: body };
        });
      }).then(null, function (err) { clearTimeout(timer); throw err; });
    }

    function mailtoFallback(data, reason) {
      // Причина запасного пути видна в консоли браузера (без данных заявки): помогает понять, что не так с сервером.
      if (window.console && console.info) console.info('[form] отправка через сервер не удалась, открываю письмо:', reason || 'unknown');
      var subject = 'Заявка с сайта: ' + data.type;
      var body = [
        'Имя: ' + data.name,
        'Контакт для ответа: ' + data.contact,
        'Что нужно: ' + data.type,
        '',
        'Задача:',
        data.message.replace(/\r?\n/g, '\r\n'),
        '',
        '— Отправлено через форму на сайте. Согласие на обработку данных дано.'
      ].join('\r\n');
      var href = 'mailto:' + MAIL + '?subject=' + encodeURIComponent(subject) + '&body=' + encodeURIComponent(body);
      // markSent() здесь не вызывается: заявка не ушла, и повторное нажатие должно снова открыть
      // письмо, а не отвечать «Заявка уже отправлена»
      track('form_fallback');
      // mailto: открывается только сразу после нажатия; если сервер отвечал долго — ссылка
      var auto = !navigator.userActivation || navigator.userActivation.isActive;
      say(auto ? 'Отправить заявку с сайта сейчас не получилось, поэтому открываю почтовую программу с готовым письмом — останется нажать «Отправить». '
        : 'Отправить заявку с сайта сейчас не получилось. Письмо с заявкой уже подготовлено: ', 'is-ok');
      var link = document.createElement('a');
      link.href = href;
      link.textContent = auto ? 'Открыть письмо ещё раз' : 'открыть его в почтовой программе';
      status.appendChild(link);
      status.appendChild(document.createTextNode('. Или напишите на ' + MAIL + ' или в Telegram.'));
      if (auto) window.location.href = href;
    }

    function done() {
      busy = false;
      form.removeAttribute('aria-busy');
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      if (busy) return;

      // Honeypot: бот заполнил скрытое поле — делаем вид, что всё прошло
      if (fields.website && fields.website.value) {
        say('Спасибо, заявка отправлена.', 'is-ok');
        form.reset();
        return;
      }
      // Слишком быстро — автоматика
      if (Date.now() - startedAt < 2500) {
        say('Секунду — проверьте, пожалуйста, поля и отправьте ещё раз.', 'is-err');
        return;
      }
      // Частота (сервер ограничивает отдельно, по IP)
      var since = Date.now() - lastSent();
      if (since < COOLDOWN_MS) {
        say('Заявка уже отправлена. Повторно можно через ' + Math.ceil((COOLDOWN_MS - since) / 1000) + ' с.', 'is-err');
        return;
      }

      var errors = ['name', 'contact', 'message'].map(validateField);
      errors.push(validateConsent());
      var firstBad = ORDER.filter(function (k, i) { return errors[i]; })[0];
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

      busy = true;
      form.setAttribute('aria-busy', 'true');
      say('Отправляю заявку…', '');
      post({ name: data.name, contact: data.contact, type: data.type, message: data.message, consent: true, website: '' })
        .then(function (r) {
          done();
          if (r.status === 200 && r.body.ok === true) {
            markSent();
            track('form_success');
            form.reset();
            say('Спасибо, заявка отправлена. Отвечу в течение двух часов на указанный контакт.', 'is-ok');
            return;
          }
          if (r.status === 422 && r.body.fields && typeof r.body.fields === 'object') {
            var bad = ORDER.filter(function (k) { return typeof r.body.fields[k] === 'string'; });
            if (bad.length) {
              bad.forEach(function (k) { setError(fields[k], String(r.body.fields[k]).slice(0, 200)); });
              say('Проверьте отмеченные поля.', 'is-err');
              fields[bad[0]].focus();
              return;
            }
          }
          if (r.status === 429) {
            var min = Math.max(1, Math.ceil((Number(r.body.retryAfter) || 600) / 60));
            say('С этого адреса уже было несколько заявок подряд. Попробуйте ещё раз через ' + min + ' мин. или напишите напрямую на ' + MAIL + '.', 'is-err');
            return;
          }
          mailtoFallback(data, 'HTTP ' + r.status + (r.body && r.body.error ? ' ' + String(r.body.error).slice(0, 40) : ''));
        }, function (err) {
          done();
          mailtoFallback(data, err && err.name === 'AbortError' ? 'timeout' : (err && err.message) || 'network');
        });
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
    safe('progress', initProgress);
    safe('to-top', initToTop);
    safe('slides', initSlides);
    safe('reveal', initReveal);
    safe('copy', initCopy);
    safe('form', initForm);
    safe('order', initOrderButtons);
    safe('track', initTrackLinks);
    safe('year', initYear);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
