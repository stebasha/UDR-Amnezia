  // ===================================================================== перезагрузка роутера
  function rebootDialog() {
    const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
    const go = el('button', { class: 'btn danger' }, icon('power', 'sm'), T('Перезагрузить'));
    const run = () => busy(go, async () => {
      if (!pw.value) { err(T('Введите текущий пароль')); pw.focus(); return; }
      try {
        const x = await api('/api/system/reboot', { current: pw.value });
        pw.value = ''; m.close(); rebootWait(x.delay || 5);
      } catch (e) { err(e); }
    });
    go.addEventListener('click', run);
    pw.addEventListener('keydown', (e) => { if (e.key === 'Enter') run(); });
    const m = modal(T('Перезагрузить роутер?'), el('div', { class: 'stack' },
      el('div', { class: 'alert crit' }, icon('alert'), el('div', null,
        T('Перезагрузится весь роутер: интернет, Wi-Fi, UniFi и туннели пропадут на 2–4 минуты. Звонки и загрузки оборвутся.'))),
      el('p', { class: 'small muted' }, T('Для подтверждения введите пароль. После загрузки сторож сам поднимет туннели и маршруты PBR.')),
      el('div', { class: 'field' }, el('label', null, T('Пароль от этой веб-панели (тот же, что при входе)')), pw)), [
      el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), go]);
  }
  function rebootWait(delay) {
    stopTimers();
    const t0 = Date.now();
    const st = el('div', { class: 'small muted' }, T('прошло ') + '0' + T(' с'));
    const msg = el('div', null, T('Роутер перезагружается. Страница откроется сама, когда панель вернётся.'));
    modal(T('Перезагрузка'), el('div', { class: 'stack' }, el('div', { class: 'alert info' }, el('span', { class: 'spinner sm' }), msg), st), [], { sticky: true });
    let down = false;
    const tick = async () => {
      const sec = Math.round((Date.now() - t0) / 1000);
      st.textContent = T('прошло ') + sec + T(' с');
      if (sec > 900) { replace(msg, T('Панель не вернулась за 15 минут. Проверьте роутер в UniFi и откройте страницу заново.')); return; }
      let alive = false;
      try { const r = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' }); alive = r.status > 0; } catch (e) { alive = false; }
      if (!alive) down = true;
      if (alive && down) { replace(msg, T('Роутер снова на связи — открываю панель…')); setTimeout(() => location.reload(), 1500); return; }
      if (alive && !down && sec > delay + 120) { replace(msg, T('Роутер так и не ушёл в перезагрузку. Посмотрите «Журналы → Действия в панели» и журнал systemd.')); return; }
      setTimeout(tick, down ? 5000 : 2000);
    };
    setTimeout(tick, (delay + 2) * 1000);
  }
  const rebootBtn = () => el('button', { class: 'btn', title: T('Перезагрузить роутер целиком'), onclick: rebootDialog }, icon('power', 'sm'), T('Перезагрузить'));
  async function busy(btn, fn) {
    const old = Array.from(btn.childNodes);
    btn.disabled = true;
    replace(btn, el('span', { class: 'spinner sm' }), old.filter((n) => n.nodeType === 3));
    try { return await fn(); } finally { btn.disabled = false; replace(btn, old); }
  }

  // ===================================================================== вход
  function showLogin(setup) {
    stopTimers();
    const app = $('#app');
    app.className = '';
    const u = el('input', { class: 'input', id: 'lu', autocomplete: 'username', value: 'admin', autocapitalize: 'off', spellcheck: 'false' });
    const p = el('input', { class: 'input', id: 'lp', type: 'password', autocomplete: 'current-password' });
    const t = el('input', { class: 'input', id: 'lt', inputmode: 'numeric', autocomplete: 'one-time-code', maxlength: 6, placeholder: '000000' });
    const tf = el('div', { class: 'field hidden' }, el('label', { for: 'lt' }, T('Код из приложения (2FA)')), t);
    const msg = el('div', { class: 'alert crit hidden' });
    const btn = el('button', { class: 'btn primary', type: 'submit' }, T('Войти'));
    const form = el('form', { class: 'login', autocomplete: 'on' },
      el('div', { class: 'brand row' }, logo(), el('span', null, 'UDR-Amnezia')),
      el('div', { class: 'sub' }, T('Панель управления AmneziaWG')),
      setup ? el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Пользователей ещё нет. На роутере выполните: '), el('code', null, 'python3 /data/awg/web/panel.py passwd admin'))) : null,
      msg,
      el('div', { class: 'field' }, el('label', { for: 'lu' }, T('Имя')), u),
      el('div', { class: 'field' }, el('label', { for: 'lp' }, T('Пароль')), p),
      tf, btn,
      el('div', { class: 'note' }, T('Доступ только из локальной сети'), ' · ',
        el('a', { href: '#', onclick: (e) => { e.preventDefault(); setLang(LANG === 'en' ? 'ru' : 'en'); } }, LANG === 'en' ? 'Русский' : 'English')));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      msg.classList.add('hidden');
      await busy(btn, async () => {
        try {
          const r = await api('/api/login', { user: u.value.trim(), password: p.value, totp: t.value.trim() });
          if (r.need_totp) { tf.classList.remove('hidden'); t.focus(); return; }
          S.csrf = r.csrf; S.user = r.user; if (r.version) S.version = r.version;
          checkVersion(r.version);
          start();
        } catch (ex) {
          replace(msg, icon('alert'), el('div', null, ex.message));
          msg.classList.remove('hidden');
          p.select();
        }
      });
    });
    replace(app, el('div', { class: 'login-wrap' }, form));
    setTimeout(() => (u.value ? p : u).focus(), 50);
  }

  // ===================================================================== каркас
  function shell() {
    const app = $('#app');
    app.className = '';
    const side = el('nav', { class: 'side', 'aria-label': T('Разделы') },
      NAV.map(([id, name, ic]) => el('a', { class: 'nav', href: '#/' + id, 'data-page': id, title: name }, icon(ic), el('span', null, name))),
      el('div', { class: 'foot', id: 'side-foot' }));
    const thIcon = { auto: 'auto', light: 'sun', dark: 'moon' };
    const thBtn = el('button', { class: 'btn ghost icon', title: T('Тема'), 'aria-label': T('Тема') });
    const setThIcon = () => replace(thBtn, icon(thIcon[themeGet()]));
    setThIcon();
    thBtn.addEventListener('click', () => {
      const order = ['auto', 'light', 'dark'];
      themeSet(order[(order.indexOf(themeGet()) + 1) % 3]);
      setThIcon();
      toast(T('Тема: ') + { auto: T('как в системе'), light: T('светлая'), dark: T('тёмная') }[themeGet()]);
      if (S.redraw) S.redraw();
    });
    const av = el('button', { class: 'avatar', 'aria-label': T('Меню пользователя') }, (S.user || '?').slice(0, 1));
    av.addEventListener('click', (e) => { e.stopPropagation(); userMenu(); });
    const top = el('header', { class: 'top' },
      el('div', { class: 'brand' }, logo(), el('span', { class: 'nm2' }, 'UDR-Amnezia'), el('span', { class: 'ver', id: 'ver' }, S.version)),
      el('div', { class: 'host', id: 'host' }),
      el('div', { class: 'actions' }, el('span', { id: 'gstat' }),
        el('button', { class: 'btn ghost langsw', title: LANG === 'en' ? 'Русский' : 'English', onclick: () => setLang(LANG === 'en' ? 'ru' : 'en') }, LANG === 'en' ? 'RU' : 'EN'), thBtn, av));
    replace(app, el('div', { class: 'shell' }, top, side, el('main', { class: 'main', id: 'main' })));
  }
  function userMenu() {
    const old = $('.menu');
    if (old) { old.remove(); return; }
    const m = el('div', { class: 'menu' },
      el('div', { class: 'who' }, el('b', null, S.user), T('администратор')),
      el('button', { onclick: () => { m.remove(); location.hash = '#/settings/users'; } }, icon('key'), T('Пароль и 2FA')),
      el('button', { onclick: () => { m.remove(); logout(); } }, icon('logout'), T('Выйти')));
    document.body.appendChild(m);
    setTimeout(() => document.addEventListener('click', function f(e) { if (!m.contains(e.target)) { m.remove(); document.removeEventListener('click', f); } }), 0);
  }
  async function logout() {
    try { await api('/api/logout', {}); } catch (e) { /* всё равно на экран входа */ }
    S.csrf = '';
    showLogin(false);
  }
  // Версия страницы подставляется панелью при отдаче app.js. Вкладка, открытая до обновления, после входа
  // (или при опросе обзора) видит другую версию панели и перезагружается — иначе новых кнопок не видно до Ctrl+F5.
  const PAGE_VERSION = '__AWG_PAGE_VERSION__';
  function checkVersion(v) {
    if (!v || PAGE_VERSION.indexOf('__') === 0 || v === PAGE_VERSION) return;
    let last = '';
    try { last = sessionStorage.getItem('awg-reloaded-for') || ''; } catch (e) { /* без хранилища — просто перезагрузка */ }
    if (last === v) return;   // уже перезагружались ради этой версии: не зацикливаться (например, прокси отдаёт старый файл)
    try { sessionStorage.setItem('awg-reloaded-for', v); } catch (e) { /* ничего */ }
    location.reload();
  }
  function updateChrome(ov) {
    checkVersion(ov.panel);
    const host = $('#host');
    if (!host) return;
    replace(host, icon('router', 'sm'), el('span', { class: 'hn' }, ov.host));
    const lv = { ok: ['ok', T('Работает')], warn: ['warn', T('Внимание')], crit: ['crit', T('Проблема')] }[ov.level] || ['', '?'];
    replace($('#gstat'), el('a', { class: 'pill ' + lv[0], href: '#/overview' }, el('span', { class: 'dot ' + lv[0] }), lv[1]));
    replace($('#ver'), 'v' + ov.version);
    replace($('#side-foot'), el('div', null, T('Активен: '), el('b', null, ov.active || T('нет'))), el('div', null, T('Аптайм ') + fmtDur(ov.uptime)));
  }

  // ===================================================================== маршрутизатор страниц
  const PAGES = {};
  function route() {
    const h = (location.hash || '#/overview').replace(/^#\/?/, '').split('/');
    const page = PAGES[h[0]] ? h[0] : 'overview';
    stopTimers();
    S.redraw = null;
    S.page = page;
    document.querySelectorAll('.nav').forEach((n) => n.classList.toggle('on', n.dataset.page === page));
    const main = $('#main');
    clear(main);
    window.scrollTo(0, 0);
    PAGES[page](main, h[1] || '');
    every(15000, async () => { if (page !== 'overview' && page !== 'tunnels') updateChrome(await api('/api/overview')); }, page !== 'overview' && page !== 'tunnels');
  }
  window.addEventListener('hashchange', () => { if (S.csrf) route(); });

  function head(title, ...right) { return el('div', { class: 'page-head' }, el('h1', null, title), right); }
  function card(title, body, opts) {
    opts = opts || {};
    return el('section', { class: 'card' + (opts.cls ? ' ' + opts.cls : ''), id: opts.id || null },
      title != null ? el('div', { class: 'hd' }, opts.icon ? icon(opts.icon) : null, el('h2', null, title), opts.right || null) : null,
      el('div', { class: 'bd' + (opts.flush ? ' flush' : '') }, body), opts.foot ? el('div', { class: 'ft' }, opts.foot) : null);
  }
  function tabs(items, cur, onpick) {
    const bar = el('div', { class: 'tabs', role: 'tablist' });
    for (const [id, name] of items) {
      bar.appendChild(el('button', { class: 'tab' + (id === cur ? ' on' : ''), role: 'tab', onclick: () => onpick(id) }, name));
    }
    return bar;
  }

  // ===================================================================== общие куски
  const STATUS = {
    active: ['ok', T('Активен')], standby: ['accent', T('Резерв')], nohs: ['warn', T('Нет handshake')], down: ['crit', T('Выключен')],
  };
  const ROLE = { main: T('Основной'), backup: T('Запасной'), extra: T('Дополнительный') };
  const EVT = {
    start: ['accent', 'power', T('Запуск')], stop: ['warn', 'power', T('Остановка')], switch: ['warn', 'switch', T('Переключение')],
    degrade: ['warn', 'activity', T('Качество')], return: ['ok', 'okc', T('Возврат')], force: ['accent', 'switch', T('Вручную')],
    auto: ['accent', 'refresh', T('Авто')], both: ['crit', 'alert', T('Нет каналов')], refused: ['warn', 'x', T('Отклонено')],
    drift: ['crit', 'alert', T('PBR изменён')], reboot: ['warn', 'power', T('Перезагрузка')], firmware: ['accent', 'download', T('Прошивка')], backup: ['ok', 'archive', T('Копия')], vps: ['accent', 'server', 'VPS'],
    tune: ['accent', 'shield', T('Автоподбор')], lists: ['accent', 'layers', T('Списки')],
  };
  function dotFor(st) { return { active: 'ok pulse', standby: 'ok', nohs: 'warn', down: 'crit' }[st] || ''; }
  function evRow(e) {
    const m = EVT[e.type] || ['', 'info', e.type];
    return el('div', { class: 'ev' },
      el('div', { class: 'when', title: fmtTime(e.t, true) }, fmtTime(e.t)),
      el('div', { class: 'ico ' + m[0] }, icon(m[1], 'sm')),
      el('div', { class: 'txt' }, el('b', null, m[2]), ' · ', e.text));
  }
  function alertsBox(ov) {
    const real = ov.alerts.filter((a) => a[0] !== 'info');
    return el('div', { class: 'stack' },
      real.length ? null : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Всё работает: трафик PBR идёт через '), el('b', null, ov.active || '—'), T(', kill switch на месте.'))),
      ov.alerts.map(([lv, t]) => el('div', { class: 'alert ' + lv }, icon(lv === 'info' ? 'info' : 'alert'), el('div', null, TM(t)))));
  }
  function secret(id, text, mask) {
    const shown = !!S.reveal[id];
    const s = el('span', { class: 'secret', title: shown ? T('Скрыть') : T('Показать'), role: 'button', tabindex: 0 },
      el('span', { class: 'mono' }, shown ? text : (mask || '•••.•••.•••.•••')), icon(shown ? 'eyeoff' : 'eye', 'sm'));
    const flip = () => { S.reveal[id] = !S.reveal[id]; s.replaceWith(secret(id, text, mask)); };
    s.addEventListener('click', flip);
    s.addEventListener('keydown', (e) => { if (e.key === 'Enter') flip(); });
    return s;
  }

