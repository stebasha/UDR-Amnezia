/* UDR-Amnezia — веб-панель. Без внешних библиотек; совместимо с CSP (без inline-скриптов и стилей). */
'use strict';
(function () {
  // ===================================================================== DOM-помощники
  const $ = (s, r) => (r || document).querySelector(s);
  const SVGNS = 'http://www.w3.org/2000/svg';
  function add(node, kids) {
    if (!Array.isArray(kids)) kids = [kids];
    for (const k of kids) {
      if (k == null || k === false || k === true) continue;
      if (Array.isArray(k)) add(node, k);
      else node.appendChild(k instanceof Node ? k : document.createTextNode(String(k)));
    }
    return node;
  }
  function el(tag, attrs, ...kids) {
    const n = document.createElement(tag);
    setAttrs(n, attrs);
    return add(n, kids);
  }
  function sv(tag, attrs, ...kids) {
    const n = document.createElementNS(SVGNS, tag);
    setAttrs(n, attrs);
    return add(n, kids);
  }
  function setAttrs(n, attrs) {
    if (!attrs) return;
    for (const k in attrs) {
      const v = attrs[k];
      if (v == null || v === false) continue;
      if (k.startsWith('on') && typeof v === 'function') n.addEventListener(k.slice(2), v);
      else if (k === 'class') n.setAttribute('class', v);
      else if (k === 'value' && 'value' in n && n.namespaceURI !== SVGNS) n.value = v;
      else if (k === 'checked' || k === 'disabled' || k === 'selected') n[k] = !!v;
      else if (k === 'text') n.textContent = v;
      else n.setAttribute(k, v === true ? '' : v);
    }
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); return n; }
  function replace(n, ...kids) { clear(n); return add(n, kids); }

  // ===================================================================== иконки (простые линии 24×24)
  const IC = {
    home: 'M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z',
    tunnel: 'M12 3 4 6v6c0 4.4 3.4 8.2 8 9 4.6-.8 8-4.6 8-9V6z|M9 12l2 2 4-4',
    route: 'M6 3v12|M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6z|M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6z|M18 9a9 9 0 0 1-9 9',
    tools: 'M14.7 6.3a4 4 0 0 0 5 5L21 13l-8 8-3-3 1.3-1.3a4 4 0 0 0-5-5L3 10l8-8 3 3z',
    logs: 'M8 6h13|M8 12h13|M8 18h13|M3 6h.01|M3 12h.01|M3 18h.01',
    settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z|M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
    sun: 'M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10z|M12 1v2|M12 21v2|M4.2 4.2l1.4 1.4|M18.4 18.4l1.4 1.4|M1 12h2|M21 12h2|M4.2 19.8l1.4-1.4|M18.4 5.6l1.4-1.4',
    moon: 'M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8z',
    auto: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z|M12 3v18',
    logout: 'M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4|M16 17l5-5-5-5|M21 12H9',
    eye: 'M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z|M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
    eyeoff: 'M17.9 17.9A10 10 0 0 1 12 20c-7 0-11-8-11-8a18 18 0 0 1 5.1-5.9|M9.9 4.2A9 9 0 0 1 12 4c7 0 11 8 11 8a18 18 0 0 1-2.2 3.2|M14.1 14.1a3 3 0 1 1-4.2-4.2|M1 1l22 22',
    play: 'M6 4l14 8-14 8z',
    refresh: 'M23 4v6h-6|M1 20v-6h6|M3.5 9a9 9 0 0 1 14.9-3.4L23 10|M1 14l4.6 4.4A9 9 0 0 0 20.5 15',
    edit: 'M12 20h9|M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z',
    trash: 'M3 6h18|M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2|M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6',
    plus: 'M12 5v14|M5 12h14',
    check: 'M20 6 9 17l-5-5',
    x: 'M18 6 6 18|M6 6l12 12',
    alert: 'M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z|M12 9v4|M12 17h.01',
    info: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z|M12 16v-4|M12 8h.01',
    okc: 'M22 11.1V12a10 10 0 1 1-5.9-9.1|M22 4 12 14l-3-3',
    globe: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z|M2 12h20|M12 2a15 15 0 0 1 4 10 15 15 0 0 1-4 10 15 15 0 0 1-4-10 15 15 0 0 1 4-10z',
    router: 'M3 14h18v6H3z|M7 17h.01|M11 17h.01|M8 10a6 6 0 0 1 8 0|M5 7a10 10 0 0 1 14 0',
    server: 'M3 3h18v7H3z|M3 14h18v7H3z|M7 6.5h.01|M7 17.5h.01',
    laptop: 'M4 5h16v10H4z|M2 19h20',
    switch: 'M16 3h5v5|M4 20 21 3|M21 16v5h-5|M15 15l6 6|M4 4l5 5',
    download: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4|M7 10l5 5 5-5|M12 15V3',
    upload: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4|M17 8l-5-5-5 5|M12 3v12',
    key: 'M21 2l-2 2m-7.6 7.6a5.5 5.5 0 1 1-7.8 7.8 5.5 5.5 0 0 1 7.8-7.8zm0 0L15.5 7.5m0 0 3 3L22 7l-3-3m-3.5 3.5L19 4',
    users: 'M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2|M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z|M23 21v-2a4 4 0 0 0-3-3.9|M16 3.1a4 4 0 0 1 0 7.8',
    bell: 'M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9|M13.7 21a2 2 0 0 1-3.4 0',
    archive: 'M21 8v13H3V8|M1 3h22v5H1z|M10 12h4',
    cpu: 'M4 4h16v16H4z|M9 9h6v6H9z|M9 1v3|M15 1v3|M9 20v3|M15 20v3|M20 9h3|M20 14h3|M1 9h3|M1 14h3',
    activity: 'M22 12h-4l-3 9L9 3l-3 9H2',
    clock: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z|M12 6v6l4 2',
    power: 'M18.4 6.6a9 9 0 1 1-12.8 0|M12 2v10',
    search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16z|M21 21l-4.3-4.3',
    stetho: 'M22 12h-4l-3 9L9 3l-3 9H2',
    wrench: 'M14.7 6.3a4 4 0 0 0 5 5L21 13l-8 8-3-3 1.3-1.3a4 4 0 0 0-5-5L3 10l8-8 3 3z',
    file: 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z|M14 2v6h6|M8 13h8|M8 17h8',
    shield: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z',
    layers: 'M12 2 2 7l10 5 10-5z|M2 17l10 5 10-5|M2 12l10 5 10-5',
    ruler: 'M21.3 8.7 15.3 2.7 2.7 15.3l6 6z|M7.5 10.5l2 2|M10.5 7.5l2 2|M13.5 4.5l2 2|M4.5 13.5l2 2',
    copy: 'M9 9h13v13H9z|M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1',
    tg: 'M22 2 11 13|M22 2l-7 20-4-9-9-4z',
    lock: 'M5 11h14v10H5z|M8 11V7a4 4 0 0 1 8 0v4',
    menu: 'M3 12h18|M3 6h18|M3 18h18',
    up: 'M12 19V5|M5 12l7-7 7 7',
    users2: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z|M4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1',
    link: 'M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7|M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7',
  };
  function icon(name, cls) {
    const s = sv('svg', { class: 'i' + (cls ? ' ' + cls : ''), viewBox: '0 0 24 24', 'aria-hidden': 'true' });
    for (const d of (IC[name] || IC.info).split('|')) s.appendChild(sv('path', { d }));
    return s;
  }
  function logo() {
    return sv('svg', { class: 'logo', viewBox: '0 0 32 32', 'aria-hidden': 'true' },
      sv('rect', { width: 32, height: 32, rx: 8, fill: '#006fff' }),
      sv('path', { d: 'M9 21.5 16 8l7 13.5M11.6 16.6h8.8', fill: 'none', stroke: '#fff', 'stroke-width': 2.6, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }),
      sv('circle', { cx: 16, cy: 24.5, r: 1.8, fill: '#fff' }));
  }

  // ===================================================================== форматирование
  const pad2 = (n) => String(n).padStart(2, '0');
  function fmtBits(bps) {
    bps = +bps || 0;
    if (bps < 1000) return Math.round(bps) + ' бит/с';
    if (bps < 1e6) return (bps / 1e3).toFixed(bps < 1e4 ? 1 : 0) + ' Кбит/с';
    if (bps < 1e9) return (bps / 1e6).toFixed(bps < 1e7 ? 2 : 1) + ' Мбит/с';
    return (bps / 1e9).toFixed(2) + ' Гбит/с';
  }
  function fmtBytes(b) {
    b = +b || 0;
    const u = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
    let i = 0;
    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
    return (i ? b.toFixed(b < 10 ? 2 : b < 100 ? 1 : 0) : b) + ' ' + u[i];
  }
  function fmtAge(s) {
    s = +s;
    if (!(s >= 0)) return 'нет';
    if (s < 90) return s + ' с назад';
    if (s < 5400) return Math.round(s / 60) + ' мин назад';
    if (s < 172800) return Math.round(s / 3600) + ' ч назад';
    return Math.round(s / 86400) + ' дн назад';
  }
  function fmtDur(s) {
    s = Math.max(0, Math.floor(+s || 0));
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return d + ' д ' + h + ' ч';
    if (h) return h + ' ч ' + m + ' мин';
    if (m) return m + ' мин';
    return s + ' с';
  }
  function fmtTime(t, full) {
    const d = new Date(t * 1000), n = new Date();
    const hm = pad2(d.getHours()) + ':' + pad2(d.getMinutes());
    if (!full && d.toDateString() === n.toDateString()) return hm + ':' + pad2(d.getSeconds());
    return pad2(d.getDate()) + '.' + pad2(d.getMonth() + 1) + (d.getFullYear() !== n.getFullYear() ? '.' + d.getFullYear() : '') + ' ' + hm;
  }
  function splitEndpoint(ep) {
    if (!ep) return ['', ''];
    const m = ep.match(/^\[?([^\]]+?)\]?:(\d+)$/);
    return m ? [m[1], m[2]] : [ep, ''];
  }

  // ===================================================================== состояние и API
  const S = { csrf: '', user: '', version: '', page: '', ov: null, live: {}, hist: null, timers: [], reveal: {}, histMode: 'live', chartTun: '' };
  const NAV = [
    ['overview', 'Обзор', 'home'],
    ['tunnels', 'Туннели', 'tunnel'],
    ['clients', 'Клиенты', 'users'],
    ['routing', 'Маршрутизация', 'route'],
    ['tools', 'Инструменты', 'tools'],
    ['logs', 'Журналы', 'logs'],
    ['settings', 'Настройки', 'settings'],
  ];

  class ApiErr extends Error {}
  async function api(path, data) {
    const opt = { credentials: 'same-origin', headers: { Accept: 'application/json' }, cache: 'no-store' };
    if (data !== undefined) {
      opt.method = 'POST';
      opt.headers['Content-Type'] = 'application/json';
      opt.headers['X-CSRF'] = S.csrf;
      opt.body = JSON.stringify(data);
    }
    let r;
    try { r = await fetch(path, opt); } catch (e) { throw new ApiErr('роутер не отвечает: ' + e.message); }
    let j = null;
    try { j = await r.json(); } catch (e) { j = { error: 'неожиданный ответ (' + r.status + ')' }; }
    if (r.status === 401 && path !== '/api/login') { stopTimers(); showLogin(j && j.setup); throw new ApiErr('нужен вход'); }
    if (!r.ok) throw new ApiErr((j && j.error) || ('ошибка ' + r.status));
    return j;
  }
  function every(ms, fn, now) {
    let busy = false;
    const tick = async () => {
      if (busy || document.hidden) return;
      busy = true;
      try { await fn(); } catch (e) { /* ошибки показаны в fn */ } finally { busy = false; }
    };
    S.timers.push(setInterval(tick, ms));
    if (now !== false) tick();
  }
  function stopTimers() { S.timers.forEach(clearInterval); S.timers = []; }

  // ===================================================================== тема
  function themeGet() { try { return localStorage.getItem('awg-theme') || 'auto'; } catch (e) { return 'auto'; } }
  function themeSet(t) {
    try { localStorage.setItem('awg-theme', t); } catch (e) { /* без хранилища тема на один сеанс */ }
    if (t === 'auto') document.documentElement.removeAttribute('data-theme');
    else document.documentElement.setAttribute('data-theme', t);
  }
  themeSet(themeGet());

  // ===================================================================== уведомления, окна
  let toastBox = null;
  function toast(msg, kind, ms) {
    if (!toastBox) { toastBox = el('div', { class: 'toasts', role: 'status', 'aria-live': 'polite' }); document.body.appendChild(toastBox); }
    const t = el('div', { class: 'toast ' + (kind || '') }, el('div', null, msg),
      el('button', { class: 'x', 'aria-label': 'Закрыть', onclick: () => t.remove() }, icon('x', 'sm')));
    toastBox.appendChild(t);
    setTimeout(() => t.remove(), ms || (kind === 'err' ? 9000 : 4500));
  }
  const ok = (m) => toast(m, 'ok');
  const err = (e) => toast(e && e.message ? e.message : String(e), 'err');

  function modal(title, body, buttons, opts) {
    opts = opts || {};
    const bg = el('div', { class: 'modal-bg' });
    const close = () => { bg.remove(); document.removeEventListener('keydown', esc); if (opts.onclose) opts.onclose(); };
    const esc = (e) => { if (e.key === 'Escape') close(); };
    const ft = el('div', { class: 'ft' });
    const m = el('div', { class: 'modal' + (opts.wide ? ' wide' : ''), role: 'dialog', 'aria-modal': 'true' },
      el('div', { class: 'hd' }, el('h2', null, title), el('button', { class: 'btn ghost icon', 'aria-label': 'Закрыть', onclick: close }, icon('x'))),
      el('div', { class: 'bd' }, body), ft);
    for (const b of buttons || []) ft.appendChild(b);
    if (!(buttons || []).length) ft.remove();
    bg.appendChild(m);
    bg.addEventListener('mousedown', (e) => { if (e.target === bg && !opts.sticky) close(); });
    document.addEventListener('keydown', esc);
    document.body.appendChild(bg);
    const f = m.querySelector('input,textarea,select');
    if (f) setTimeout(() => { f.focus(); if (f.tagName === 'TEXTAREA') { f.setSelectionRange(0, 0); f.scrollTop = 0; } }, 30);
    return { close, root: m };
  }
  function confirmBox(title, text, yes, danger) {
    return new Promise((res) => {
      let done = false;
      const m = modal(title, el('p', null, text), [
        el('button', { class: 'btn', onclick: () => { done = true; m.close(); res(false); } }, 'Отмена'),
        el('button', { class: 'btn ' + (danger ? 'danger' : 'primary'), onclick: () => { done = true; m.close(); res(true); } }, yes || 'Да'),
      ], { onclose: () => { if (!done) res(false); } });
    });
  }
  function promptPw(title, text) {
    return new Promise((res) => {
      let done = false;
      const inp = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = () => { done = true; m.close(); res(inp.value); };
      inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
      const m = modal(title, el('div', null, text ? el('p', null, text) : null, el('div', { class: 'field' }, el('label', null, 'Текущий пароль'), inp)), [
        el('button', { class: 'btn', onclick: () => { done = true; m.close(); res(null); } }, 'Отмена'),
        el('button', { class: 'btn primary', onclick: go }, 'Подтвердить'),
      ], { onclose: () => { if (!done) res(null); } });
    });
  }
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
    const tf = el('div', { class: 'field hidden' }, el('label', { for: 'lt' }, 'Код из приложения (2FA)'), t);
    const msg = el('div', { class: 'alert crit hidden' });
    const btn = el('button', { class: 'btn primary', type: 'submit' }, 'Войти');
    const form = el('form', { class: 'login', autocomplete: 'on' },
      el('div', { class: 'brand row' }, logo(), el('span', null, 'UDR-Amnezia')),
      el('div', { class: 'sub' }, 'Панель управления AmneziaWG'),
      setup ? el('div', { class: 'alert info' }, icon('info'), el('div', null, 'Пользователей ещё нет. На роутере выполните: ', el('code', null, 'python3 /data/awg/web/panel.py passwd admin'))) : null,
      msg,
      el('div', { class: 'field' }, el('label', { for: 'lu' }, 'Имя'), u),
      el('div', { class: 'field' }, el('label', { for: 'lp' }, 'Пароль'), p),
      tf, btn,
      el('div', { class: 'note' }, 'Доступ только из локальной сети'));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      msg.classList.add('hidden');
      await busy(btn, async () => {
        try {
          const r = await api('/api/login', { user: u.value.trim(), password: p.value, totp: t.value.trim() });
          if (r.need_totp) { tf.classList.remove('hidden'); t.focus(); return; }
          S.csrf = r.csrf; S.user = r.user;
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
    const side = el('nav', { class: 'side', 'aria-label': 'Разделы' },
      NAV.map(([id, name, ic]) => el('a', { class: 'nav', href: '#/' + id, 'data-page': id, title: name }, icon(ic), el('span', null, name))),
      el('div', { class: 'foot', id: 'side-foot' }));
    const thIcon = { auto: 'auto', light: 'sun', dark: 'moon' };
    const thBtn = el('button', { class: 'btn ghost icon', title: 'Тема', 'aria-label': 'Тема' });
    const setThIcon = () => replace(thBtn, icon(thIcon[themeGet()]));
    setThIcon();
    thBtn.addEventListener('click', () => {
      const order = ['auto', 'light', 'dark'];
      themeSet(order[(order.indexOf(themeGet()) + 1) % 3]);
      setThIcon();
      toast('Тема: ' + { auto: 'как в системе', light: 'светлая', dark: 'тёмная' }[themeGet()]);
      if (S.redraw) S.redraw();
    });
    const av = el('button', { class: 'avatar', 'aria-label': 'Меню пользователя' }, (S.user || '?').slice(0, 1));
    av.addEventListener('click', (e) => { e.stopPropagation(); userMenu(); });
    const top = el('header', { class: 'top' },
      el('div', { class: 'brand' }, logo(), el('span', { class: 'nm2' }, 'UDR-Amnezia'), el('span', { class: 'ver', id: 'ver' }, S.version)),
      el('div', { class: 'host', id: 'host' }),
      el('div', { class: 'actions' }, el('span', { id: 'gstat' }), thBtn, av));
    replace(app, el('div', { class: 'shell' }, top, side, el('main', { class: 'main', id: 'main' })));
  }
  function userMenu() {
    const old = $('.menu');
    if (old) { old.remove(); return; }
    const m = el('div', { class: 'menu' },
      el('div', { class: 'who' }, el('b', null, S.user), 'администратор'),
      el('button', { onclick: () => { m.remove(); location.hash = '#/settings/users'; } }, icon('key'), 'Пароль и 2FA'),
      el('button', { onclick: () => { m.remove(); logout(); } }, icon('logout'), 'Выйти'));
    document.body.appendChild(m);
    setTimeout(() => document.addEventListener('click', function f(e) { if (!m.contains(e.target)) { m.remove(); document.removeEventListener('click', f); } }), 0);
  }
  async function logout() {
    try { await api('/api/logout', {}); } catch (e) { /* всё равно на экран входа */ }
    S.csrf = '';
    showLogin(false);
  }
  function updateChrome(ov) {
    const host = $('#host');
    if (!host) return;
    replace(host, icon('router', 'sm'), el('span', { class: 'hn' }, ov.host));
    const lv = { ok: ['ok', 'Работает'], warn: ['warn', 'Внимание'], crit: ['crit', 'Проблема'] }[ov.level] || ['', '?'];
    replace($('#gstat'), el('a', { class: 'pill ' + lv[0], href: '#/overview' }, el('span', { class: 'dot ' + lv[0] }), lv[1]));
    replace($('#ver'), 'v' + ov.version);
    replace($('#side-foot'), el('div', null, 'Активен: ', el('b', null, ov.active || 'нет')), el('div', null, 'Аптайм ' + fmtDur(ov.uptime)));
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
    return el('section', { class: 'card' + (opts.cls ? ' ' + opts.cls : '') },
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
    active: ['ok', 'Активен'], standby: ['accent', 'Резерв'], nohs: ['warn', 'Нет handshake'], down: ['crit', 'Выключен'],
  };
  const ROLE = { main: 'Основной', backup: 'Запасной', extra: 'Дополнительный' };
  const EVT = {
    start: ['accent', 'power', 'Запуск'], stop: ['warn', 'power', 'Остановка'], switch: ['warn', 'switch', 'Переключение'],
    degrade: ['warn', 'activity', 'Качество'], return: ['ok', 'okc', 'Возврат'], force: ['accent', 'switch', 'Вручную'],
    auto: ['accent', 'refresh', 'Авто'], both: ['crit', 'alert', 'Нет каналов'], refused: ['warn', 'x', 'Отклонено'],
    drift: ['crit', 'alert', 'PBR изменён'],
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
      real.length ? null : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, 'Всё работает: трафик PBR идёт через ', el('b', null, ov.active || '—'), ', kill switch на месте.')),
      ov.alerts.map(([lv, t]) => el('div', { class: 'alert ' + lv }, icon(lv === 'info' ? 'info' : 'alert'), el('div', null, t))));
  }
  function secret(id, text, mask) {
    const shown = !!S.reveal[id];
    const s = el('span', { class: 'secret', title: shown ? 'Скрыть' : 'Показать', role: 'button', tabindex: 0 },
      el('span', { class: 'mono' }, shown ? text : (mask || '•••.•••.•••.•••')), icon(shown ? 'eyeoff' : 'eye', 'sm'));
    const flip = () => { S.reveal[id] = !S.reveal[id]; s.replaceWith(secret(id, text, mask)); };
    s.addEventListener('click', flip);
    s.addEventListener('keydown', (e) => { if (e.key === 'Enter') flip(); });
    return s;
  }

  // ===================================================================== графики
  function cssVar(n) { return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); }
  function drawChart(wrap, series, opts) {
    opts = opts || {};
    let cv = wrap.querySelector('canvas');
    if (!cv) { cv = el('canvas'); wrap.appendChild(cv); }
    let tip = wrap.querySelector('.chart-tip');
    const dpr = window.devicePixelRatio || 1;
    const W = wrap.clientWidth, H = wrap.clientHeight;
    if (!W || !H) return;
    cv.width = W * dpr; cv.height = H * dpr;
    const c = cv.getContext('2d');
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, W, H);
    const L = 64, R = 10, T = 10, B = 24;
    let t0 = Infinity, t1 = -Infinity, ymax = 0;
    for (const s of series) for (const p of s.points) { t0 = Math.min(t0, p[0]); t1 = Math.max(t1, p[0]); ymax = Math.max(ymax, p[1]); }
    const muted = cssVar('--muted'), line = cssVar('--line2');
    c.font = '11px ' + cssVar('--font');
    if (!isFinite(t0) || t1 === t0) {
      c.fillStyle = muted; c.textAlign = 'center';
      c.fillText(opts.empty || 'Данные появятся через несколько секунд', W / 2, H / 2);
      cv.onmousemove = null;
      return;
    }
    // «красивый» максимум оси Y
    const nice = (v) => { if (v <= 0) return 1000; const e = Math.pow(10, Math.floor(Math.log10(v))); const f = v / e; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * e; };
    ymax = opts.max ? Math.max(opts.max, ymax) : nice(ymax * 1.08);
    const F = opts.fmt || fmtBits;
    const X = (t) => L + (t - t0) / (t1 - t0) * (W - L - R);
    const Y = (v) => T + (1 - v / ymax) * (H - T - B);
    c.strokeStyle = line; c.lineWidth = 1; c.fillStyle = muted; c.textAlign = 'right'; c.textBaseline = 'middle';
    for (let i = 0; i <= 4; i++) {
      const v = ymax * i / 4, y = Math.round(Y(v)) + 0.5;
      c.beginPath(); c.moveTo(L, y); c.lineTo(W - R, y); c.stroke();
      c.fillText(opts.fmt ? F(v) : fmtBits(v).replace(' бит/с', ' б/с').replace('бит/с', 'б/с'), L - 8, y);
    }
    c.textAlign = 'center'; c.textBaseline = 'top';
    const nx = Math.max(2, Math.min(6, Math.floor((W - L) / 90)));
    for (let i = 0; i <= nx; i++) {
      const t = t0 + (t1 - t0) * i / nx;
      const d = new Date(t * 1000);
      c.fillText(pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + (t1 - t0 < 1200 ? ':' + pad2(d.getSeconds()) : ''), Math.min(Math.max(X(t), L + 20), W - R - 20), H - B + 7);
    }
    for (const s of series) {
      if (!s.points.length) continue;
      const col = cssVar(s.color) || s.color;
      if (s.fill) {
        c.beginPath(); c.moveTo(X(s.points[0][0]), Y(0));
        for (const p of s.points) c.lineTo(X(p[0]), Y(p[1]));
        c.lineTo(X(s.points[s.points.length - 1][0]), Y(0)); c.closePath();
        c.globalAlpha = 0.12; c.fillStyle = col; c.fill(); c.globalAlpha = 1;
      }
      c.beginPath();
      s.points.forEach((p, i) => (i ? c.lineTo(X(p[0]), Y(p[1])) : c.moveTo(X(p[0]), Y(p[1]))));
      c.strokeStyle = col; c.lineWidth = 1.8; c.setLineDash(s.dash ? [5, 4] : []); c.stroke(); c.setLineDash([]);
    }
    cv.onmousemove = (e) => {
      const r = cv.getBoundingClientRect(), x = e.clientX - r.left;
      if (x < L) { if (tip) tip.remove(); tip = null; return; }
      const t = t0 + (x - L) / (W - L - R) * (t1 - t0);
      const rows = [];
      for (const s of series) {
        let best = null;
        for (const p of s.points) if (!best || Math.abs(p[0] - t) < Math.abs(best[0] - t)) best = p;
        if (best) rows.push([s, best]);
      }
      if (!rows.length) return;
      if (!tip) { tip = el('div', { class: 'chart-tip' }); wrap.appendChild(tip); }
      replace(tip, el('div', { class: 'muted' }, fmtTime(rows[0][1][0], true)),
        rows.map(([s, p]) => el('div', null, s.name + ': ', el('b', null, F(p[1])))));
      tip.style.left = Math.min(x + 12, W - tip.offsetWidth - 4) + 'px';
      tip.style.top = '8px';
    };
    cv.onmouseleave = () => { if (tip) tip.remove(); tip = null; };
  }
  function sparkline(points) {
    const W = 300, H = 54;
    const s = sv('svg', { viewBox: '0 0 ' + W + ' ' + H, preserveAspectRatio: 'none', 'aria-hidden': 'true' });
    if (!points || points.length < 2) {
      s.appendChild(sv('line', { x1: 0, y1: H - 1, x2: W, y2: H - 1, class: 'ln rx' }));
      return s;
    }
    const pts = points.slice(-90);
    let m = 1;
    for (const p of pts) m = Math.max(m, p[1], p[2]);
    const X = (i) => i / (pts.length - 1) * W, Y = (v) => H - 2 - v / m * (H - 6);
    const path = (k) => pts.map((p, i) => (i ? 'L' : 'M') + X(i).toFixed(1) + ' ' + Y(p[k]).toFixed(1)).join(' ');
    s.appendChild(sv('path', { d: path(1) + ' L' + W + ' ' + H + ' L0 ' + H + ' Z', class: 'ar rx' }));
    s.appendChild(sv('path', { d: path(1), class: 'ln rx' }));
    s.appendChild(sv('path', { d: path(2), class: 'ln tx' }));
    return s;
  }
  function lastRate(t) {
    const q = S.live[t];
    return q && q.length ? q[q.length - 1] : null;
  }

  // ===================================================================== топология
  function topology(ov) {
    const tl = ov.tunnels;
    const n = Math.max(tl.length, 1);
    const rowH = 74, H = Math.max(250, n * rowH + 70);
    const W = 680;
    const s = sv('svg', { class: 'topo', viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': 'Схема подключения' });
    const cy = H / 2 - 12;
    const node = (x, y, w, h, ic, l1, l2, cls, st) => {
      const g = sv('g', { class: cls || '' });
      g.appendChild(sv('rect', { x: x - w / 2, y: y - h / 2, width: w, height: h, rx: 10, class: 'node' + (cls === 'router' ? ' router' : '') }));
      const ig = sv('g', { transform: 'translate(' + (x - w / 2 + 12) + ',' + (y - 11) + ') scale(0.92)', class: 'ic' + (cls === 'router' ? ' acc' : '') });
      for (const d of IC[ic].split('|')) ig.appendChild(sv('path', { d, class: 'ic' + (cls === 'router' ? ' acc' : '') }));
      g.appendChild(ig);
      g.appendChild(sv('text', { x: x - w / 2 + 44, y: y - 3, class: 'b' }, l1));
      if (l2) g.appendChild(sv('text', { x: x - w / 2 + 44, y: y + 13, class: 'm' }, l2));
      if (st) g.appendChild(sv('circle', { cx: x + w / 2 - 10, cy: y - h / 2 + 10, r: 4, class: 'sdot ' + st }));
      return g;
    };
    const link = (x1, y1, x2, y2, cls) => {
      const mx = (x1 + x2) / 2;
      return sv('path', { d: 'M' + x1 + ' ' + y1 + ' C' + mx + ' ' + y1 + ' ' + mx + ' ' + y2 + ' ' + x2 + ' ' + y2, class: 'link ' + cls });
    };
    const xL = 74, xR = 246, xT = 446, xI = 614;
    const links = sv('g'), nodes = sv('g');
    // клиенты → роутер
    links.appendChild(link(xL + 67, cy, xR - 70, cy, 'ok'));
    nodes.appendChild(node(xL, cy, 134, 56, 'laptop', 'Клиенты LAN', 'PBR ' + (ov.pbr.rail || '—'), '', 'ok'));
    nodes.appendChild(node(xR, cy, 140, 62, 'router', ov.host.length > 13 ? ov.host.slice(0, 12) + '…' : ov.host,
      ov.pbr.killswitch ? 'kill switch: есть' : 'kill switch: НЕТ', 'router', ov.level === 'crit' ? 'crit' : ov.level === 'warn' ? 'warn' : 'ok'));
    // туннели
    const top = cy - (n - 1) * rowH / 2;
    tl.forEach((t, i) => {
      const y = top + i * rowH;
      const st = t.status === 'active' ? 'ok' : t.status === 'standby' ? 'ok' : t.status === 'nohs' ? 'warn' : 'crit';
      links.appendChild(link(xR + 70, cy, xT - 72, y, t.active ? 'act' : t.status === 'standby' ? 'idle' : st));
      links.appendChild(link(xT + 72, y, xI - 58, cy, t.active ? 'act' : 'idle'));
      const nm = t.label || t.name;
      nodes.appendChild(node(xT, y, 144, 54, 'shield', nm.length > 13 ? nm.slice(0, 12) + '…' : nm,
        (t.active ? 'активен' : STATUS[t.status][1].toLowerCase()) + (t.handshake >= 0 ? ' · ' + (t.handshake < 90 ? t.handshake + ' с' : Math.round(t.handshake / 60) + ' мин') : ''),
        '', t.active ? 'ok' : st === 'ok' ? 'idle' : st));
    });
    nodes.appendChild(node(xI, cy, 116, 56, 'globe', 'Интернет', ov.wan.if || 'WAN', '', ov.active ? 'ok' : 'crit'));
    // прямой WAN (без PBR)
    const yb = H - 22;
    links.appendChild(sv('path', { d: 'M' + xR + ' ' + (cy + 31) + ' L' + xR + ' ' + yb + ' L' + xI + ' ' + yb + ' L' + xI + ' ' + (cy + 28), class: 'link idle' }));
    nodes.appendChild(sv('text', { x: (xR + xI) / 2, y: yb - 6, class: 'm', 'text-anchor': 'middle' }, 'напрямую через ' + (ov.wan.if || 'WAN') + ' — устройства вне PBR'));
    s.appendChild(links); s.appendChild(nodes);
    return s;
  }

  // ===================================================================== ОБЗОР
  PAGES.overview = function (main) {
    const alerts = el('div');
    const kpis = el('div', { class: 'grid g-kpi' });
    const topo = el('div');
    const evs = el('div');
    const svcs = el('div');
    const chartWrap = el('div', { class: 'chart-wrap' });
    const clBox = el('div', { class: 'empty' }, 'загрузка…');
    const upBox = el('div', { class: 'stack' });
    const drawUp = () => replace(upBox, (S.ov ? S.ov.tunnels : []).map((t) => el('div', null, el('div', { class: 'row small' }, el('span', { class: 'dot ' + dotFor(t.status) }), el('b', null, t.label || t.name), el('span', { class: 'muted' }, ROLE[t.role])), uptimeBar(hist, t.name))));
    const legend = el('div', { class: 'legend' });
    const tunSel = el('select', { class: 'input', 'aria-label': 'Туннель' });
    tunSel.style.width = 'auto'; tunSel.style.height = '30px';
    const seg = el('div', { class: 'seg' });
    const segBtn = (m, t) => el('button', { class: S.histMode === m ? 'on' : '', onclick: (e) => { S.histMode = m; seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b === e.currentTarget)); drawMain(); } }, t);
    add(seg, [segBtn('live', '10 мин'), segBtn('day', '24 ч')]);
    tunSel.addEventListener('change', () => { S.chartTun = tunSel.value; drawMain(); });
    let hist = [];
    add(main, [
      head('Обзор', el('a', { class: 'btn', href: '#/tools' }, icon('stetho'), 'Диагностика')),
      alerts, el('div', { class: 'spacer' }), kpis, el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card('Схема', topo, { icon: 'layers' }),
        card('События', evs, { icon: 'activity', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/logs' }, 'Все') })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card('Трафик', el('div', { class: 'stack' }, chartWrap, legend), { icon: 'activity', right: el('div', { class: 'row' }, tunSel, seg) }),
        card('Службы', svcs, { icon: 'cpu', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/settings/services' }, 'Управление') })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card('Клиенты в туннеле', clBox, { icon: 'users', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/clients' }, 'Все') }),
        card('Доступность каналов', upBox, { icon: 'okc' })),
    ]);
    function kpi(lbl, ic, val, sub, extra) {
      return el('div', { class: 'card kpi' }, el('div', { class: 'lbl' }, icon(ic, 'sm'), lbl), el('div', { class: 'val' }, val), sub ? el('div', { class: 'sub' }, sub) : null, extra || null);
    }
    function drawMain() {
      const t = S.chartTun;
      if (!t) return;
      if (S.histMode === 'live') {
        const q = S.live[t] || [];
        drawChart(chartWrap, [
          { name: 'Получено', color: '--chart-rx', fill: true, points: q.map((p) => [p[0], p[1]]) },
          { name: 'Отправлено', color: '--chart-tx', points: q.map((p) => [p[0], p[2]]) }]);
      } else {
        const pts = hist.filter((p) => p.tun && p.tun[t]);
        drawChart(chartWrap, [
          { name: 'Получено', color: '--chart-rx', fill: true, points: pts.map((p) => [p.t, p.tun[t].rx]) },
          { name: 'Отправлено', color: '--chart-tx', points: pts.map((p) => [p.t, p.tun[t].tx]) }],
        { empty: 'История копится раз в минуту — загляните позже' });
      }
      const r = lastRate(t);
      replace(legend, el('span', null, el('i', null), 'Получено ', el('b', null, r ? fmtBits(r[1]) : '—')),
        el('span', null, el('i', null), 'Отправлено ', el('b', null, r ? fmtBits(r[2]) : '—')));
      const is = legend.querySelectorAll('i');
      is[0].style.background = cssVar('--chart-rx'); is[1].style.background = cssVar('--chart-tx');
    }
    S.redraw = drawMain;
    function render(ov) {
      S.ov = ov;
      updateChrome(ov);
      replace(alerts, alertsBox(ov));
      const act = ov.tunnels.find((t) => t.active);
      const r = act ? lastRate(act.name) : null;
      const lv = { ok: ['ok', 'Работает'], warn: ['warn', 'Внимание'], crit: ['crit', 'Проблема'] }[ov.level];
      const memPct = ov.mem.total_mb ? Math.round(ov.mem.used_mb * 100 / ov.mem.total_mb) : 0;
      const onMain = ov.stats.on_main_pct;
      const bar = (pct) => { const i = el('i'); i.style.width = Math.max(0, Math.min(100, pct)) + '%'; return el('div', { class: 'bar' }, i); };
      replace(kpis,
        kpi('Состояние', 'shield', [el('span', { class: 'dot ' + lv[0] + ' pulse' }), el('span', { class: 't' }, lv[1])], ov.alerts.filter((a) => a[0] !== 'info').length ? ov.alerts.filter((a) => a[0] !== 'info').length + ' предупр.' : 'без замечаний'),
        kpi('Активный канал', 'tunnel', el('span', { class: 't' }, act ? (act.label || act.name) : 'нет'), act ? (act.name + (ov.forced ? ' · выбран вручную' : ' · авто')) : 'трафик PBR заблокирован'),
        kpi('Handshake', 'clock', el('span', { class: 't' }, act && act.handshake >= 0 ? fmtAge(act.handshake) : '—'), act ? ('потери ' + (act.loss !== '' ? act.loss + '%' : '—') + ' · RTT ' + (act.rtt !== '' ? act.rtt + ' мс' : '—')) : ''),
        kpi('Скорость', 'activity', el('span', { class: 't' }, r ? fmtBits(r[1]) : '—'), r ? '↑ ' + fmtBits(r[2]) : 'нет данных'),
        kpi('На основном (7 дн)', 'okc', el('span', { class: 't' }, onMain + '%'), 'переключений: ' + ov.stats.switch + ', качество: ' + ov.stats.degrade, bar(onMain)),
        kpi('Роутер', 'cpu', el('span', { class: 't' }, 'load ' + (ov.load[0] || '?')), 'память ' + memPct + '% · /data ' + (ov.data_free_mb >= 0 ? ov.data_free_mb + ' МБ' : '?'), bar(memPct)));
      replace(topo, topology(ov));
      drawUp();
      replace(evs, ov.events.length ? ov.events.slice(0, 9).map(evRow) : el('div', { class: 'empty' }, 'Событий пока нет'));
      replace(svcs, Object.entries(ov.services).filter(([, s]) => s.installed).map(([u, s]) =>
        el('div', { class: 'svc' }, el('span', { class: 'dot ' + (s.active ? 'ok' : 'crit') }), el('span', { class: 'nm' }, u.replace('awg-', '')), el('span', { class: 'ds' }, s.info),
          el('span', { class: 'badge ' + (s.active ? 'ok' : 'crit') }, s.active ? 'работает' : 'стоит'))));
      const names = ov.tunnels.map((t) => t.name);
      if (!S.chartTun || !names.includes(S.chartTun)) S.chartTun = (act || ov.tunnels[0] || {}).name || '';
      if (Array.from(tunSel.options).map((o) => o.value).join() !== names.join()) {
        replace(tunSel, ov.tunnels.map((t) => el('option', { value: t.name }, t.label ? t.label + ' (' + t.name + ')' : t.name)));
      }
      tunSel.value = S.chartTun;
    }
    every(5000, async () => { try { render(await api('/api/overview')); } catch (e) { if (!(e instanceof ApiErr && e.message === 'нужен вход')) replace(alerts, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); } });
    every(2000, async () => { S.live = (await api('/api/live')).live; if (S.histMode === 'live') drawMain(); });
    every(60000, async () => { hist = S.hist = (await api('/api/history')).points; if (S.histMode === 'day') drawMain(); drawUp(); });
    every(10000, async () => { const c = await api('/api/clients'); replace(clBox, clientsTable(c.clients.slice(0, 6), true)); clBox.className = ''; });
    const ro = new ResizeObserver(() => drawMain());
    ro.observe(chartWrap);
  };

  // ===================================================================== ТУННЕЛИ
  function upOk(p, t) {
    const x = p.tun && p.tun[t];
    if (!x) return null;
    return x.hs >= 0 && x.hs < 180 && String(x.loss) !== '100';
  }
  function uptimeBar(points, t, buckets) {
    buckets = buckets || 48;
    const nowT = Math.floor(Date.now() / 1000), span = 86400, step = span / buckets;
    const bins = Array.from({ length: buckets }, () => [0, 0]);
    for (const p of points || []) {
      const i = Math.floor((p.t - (nowT - span)) / step);
      if (i < 0 || i >= buckets) continue;
      const o = upOk(p, t);
      if (o === null) continue;
      bins[i][1]++;
      if (o) bins[i][0]++;
    }
    let good = 0, all = 0;
    const bar = el('div', { class: 'ubar', role: 'img' });
    bins.forEach(([g, n], i) => {
      good += g; all += n;
      const r = n ? g / n : -1;
      const from = new Date((nowT - span + i * step) * 1000);
      bar.appendChild(el('i', { class: r < 0 ? '' : r >= 0.99 ? 'ok' : r >= 0.9 ? 'warn' : 'crit',
        title: pad2(from.getHours()) + ':' + pad2(from.getMinutes()) + ' — ' + (r < 0 ? 'нет данных' : Math.round(r * 1000) / 10 + '% времени работал') }));
    });
    const pct = all ? Math.round(good * 1000 / all) / 10 : null;
    bar.setAttribute('aria-label', 'Доступность за сутки: ' + (pct == null ? 'нет данных' : pct + '%'));
    return el('div', { class: 'uptime' }, el('div', { class: 'row between small muted' }, el('span', null, 'Доступность, 24 ч'), el('b', null, pct == null ? '—' : pct + '%')), bar);
  }
  function lineDiff(a, b) {
    const A = a.replace(/\n$/, '').split('\n'), B = b.replace(/\n$/, '').split('\n');
    const n = A.length, m = B.length, L = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = A[i] === B[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
    const out = [];
    let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && A[i] === B[j]) { out.push([' ', A[i]]); i++; j++; }
      else if (j < m && (i >= n || L[i][j + 1] >= L[i + 1][j])) { out.push(['+', B[j]]); j++; }
      else { out.push(['-', A[i]]); i++; }
    }
    return out;
  }
  function diffView(a, b) {
    const d = lineDiff(a, b);
    if (!d.some((x) => x[0] !== ' ')) return el('div', { class: 'alert info' }, icon('info'), el('div', null, 'Изменений нет.'));
    return el('pre', { class: 'diff' }, d.map(([k, l]) => el('span', { class: k === '+' ? 'add' : k === '-' ? 'del' : '' }, (k === ' ' ? '  ' : k + ' ') + l + '\n')));
  }
  function dropZone(onText, hint) {
    const f = el('input', { type: 'file', accept: '.conf,.txt,.json,.vpn,text/plain,application/json', class: 'hidden' });
    const read = (file) => {
      if (!file) return;
      if (file.size > 200000) { err('файл слишком большой'); return; }
      const rd = new FileReader();
      rd.onload = () => onText(String(rd.result), file.name);
      rd.readAsText(file);
    };
    f.addEventListener('change', () => read(f.files[0]));
    const z = el('div', { class: 'drop', tabindex: 0, role: 'button', onclick: () => f.click() },
      icon('upload', 'lg'), el('b', null, 'Перетащите файл сюда или нажмите'), el('span', { class: 'small muted' }, hint || '.conf из AmneziaVPN, панели сервера или провайдера'), f);
    z.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); f.click(); } });
    z.addEventListener('dragover', (e) => { e.preventDefault(); z.classList.add('over'); });
    z.addEventListener('dragleave', () => z.classList.remove('over'));
    z.addEventListener('drop', (e) => { e.preventDefault(); z.classList.remove('over'); read(e.dataTransfer.files[0]); });
    return z;
  }
  function closeTop() { const m = document.querySelectorAll('.modal-bg'); if (m.length) m[m.length - 1].remove(); }

  PAGES.tunnels = function (main) {
    const autoBtn = el('button', { class: 'btn hidden', onclick: async () => { try { ok((await api('/api/tunnel/auto', {})).msg); load(); } catch (e) { err(e); } } }, icon('refresh'), 'Автовыбор канала');
    const grid = el('div', { class: 'grid g-tun' });
    const alerts = el('div');
    add(main, [head('Туннели', autoBtn,
      el('button', { class: 'btn', onclick: () => importDialog(load) }, icon('upload'), 'Импорт'),
      el('button', { class: 'btn primary', onclick: () => importDialog(load, 'new') }, icon('plus'), 'Добавить')), alerts, el('div', { class: 'spacer' }), grid]);
    const cards = {};
    async function load() {
      const ov = await api('/api/overview');
      S.ov = ov;
      updateChrome(ov);
      autoBtn.classList.toggle('hidden', !ov.forced);
      replace(alerts, ov.forced ? el('div', { class: 'alert warn' }, icon('info'), el('div', null, 'Канал выбран вручную: ', el('b', null, ov.forced), '. Сторож не переключит его, пока он работает. Чтобы вернуть автоматику — «Автовыбор канала».')) : null);
      const names = ov.tunnels.map((t) => t.name);
      for (const k of Object.keys(cards)) if (!names.includes(k)) { cards[k].remove(); delete cards[k]; }
      const extras = ov.tunnels.filter((t) => t.role === 'extra').map((t) => t.name);
      for (const t of ov.tunnels) {
        const c = tunnelCard(t, ov, load, extras);
        if (cards[t.name]) cards[t.name].replaceWith(c); else grid.appendChild(c);
        cards[t.name] = c;
      }
      for (const t of ov.tunnels) grid.appendChild(cards[t.name]);
      let addc = grid.querySelector('.tun.add');
      if (!addc) addc = el('button', { class: 'card tun add', onclick: () => importDialog(load, 'new') }, el('div', { class: 'stack' }, icon('plus', 'lg'), 'Добавить туннель', el('span', { class: 'small' }, 'Файл .conf, ссылка vpn:// или текст: сторож будет переключаться и на него')));
      grid.appendChild(addc);
    }
    every(5000, load);
    every(60000, async () => { S.hist = (await api('/api/history')).points; for (const [t, c] of Object.entries(cards)) { const u = c.querySelector('.uptime'); if (u) u.replaceWith(uptimeBar(S.hist, t)); } });
    every(2000, async () => {
      S.live = (await api('/api/live')).live;
      for (const [t, c] of Object.entries(cards)) {
        const sp = c.querySelector('.spark'), rt = c.querySelector('.rates');
        if (sp) replace(sp, sparkline(S.live[t]));
        const r = lastRate(t);
        if (rt) replace(rt, el('span', null, '↓ ', el('b', null, r ? fmtBits(r[1]) : '—')), el('span', null, '↑ ', el('b', null, r ? fmtBits(r[2]) : '—')));
      }
    });
  };
  function tunnelCard(t, ov, reload, extras) {
    const [host, port] = splitEndpoint(t.endpoint);
    const st = STATUS[t.status];
    const kv = el('dl', { class: 'kv' },
      el('dt', null, 'Сервер'), el('dd', null, host ? secret('ep-' + t.name, host) : '—'),
      el('dt', null, 'Порт'), el('dd', null, el('span', { class: 'mono' }, port || '—')),
      el('dt', null, 'Адрес туннеля'), el('dd', null, el('span', { class: 'mono' }, (t.address || '—').split(',')[0])),
      el('dt', null, 'Handshake'), el('dd', null, t.handshake >= 0 ? fmtAge(t.handshake) : el('span', { class: 'badge warn' }, 'нет')),
      el('dt', null, 'Потери / RTT'), el('dd', null, (t.loss !== '' ? t.loss + '%' : '—') + ' / ' + (t.rtt !== '' ? t.rtt + ' мс' : '—')),
      el('dt', null, 'DNS через туннель'), el('dd', null, t.dns === '' ? '—' : t.dns === '1' || t.dns === 'ok' ? el('span', { class: 'badge ok' }, 'работает') : el('span', { class: 'badge warn' }, 'нет ответа')),
      el('dt', null, 'MTU'), el('dd', null, t.mtu || '—'),
      el('dt', null, 'Всего ↓ / ↑'), el('dd', null, fmtBytes(t.rx) + ' / ' + fmtBytes(t.tx)),
      el('dt', null, 'Конфиг'), el('dd', null, el('span', { class: 'mono' }, t.conf), t.conf_mode && t.conf_mode !== '600' ? el('span', { class: 'badge warn', title: 'Права на файл с ключом' }, t.conf_mode) : null));
    const r = lastRate(t.name);
    const act = el('button', { class: 'btn sm' + (t.active ? '' : ' primary'), disabled: t.active || t.status === 'down' },
      icon(t.active ? 'check' : 'switch', 'sm'), t.active ? 'Активен' : 'Активировать');
    act.addEventListener('click', () => busy(act, async () => {
      try { const x = await api('/api/tunnel/switch', { name: t.name }); (x.ok ? ok : err)(x.msg); reload(); } catch (e) { err(e); }
    }));
    const xi = extras.indexOf(t.name);
    const more = [
      el('button', { class: 'btn sm icon', title: 'Тест канала', 'aria-label': 'Тест', onclick: () => tunnelTest(t) }, icon('stetho', 'sm')),
      el('button', { class: 'btn sm icon', title: 'Перезапустить туннель', 'aria-label': 'Перезапустить', onclick: async () => {
        if (!await confirmBox('Перезапустить ' + t.name + '?', t.active ? 'Это активный канал: на несколько секунд трафик PBR остановится (kill switch не даст ему уйти мимо).' : 'Интерфейс будет пересоздан с текущим конфигом.', 'Перезапустить')) return;
        try { const x = await api('/api/tunnel/restart', { name: t.name }); (x.ok ? ok : err)(x.msg || 'готово'); reload(); } catch (ex) { err(ex); }
      } }, icon('refresh', 'sm')),
    ];
    const lbl = el('button', { class: 'btn ghost icon sm', title: 'Название', 'aria-label': 'Переименовать', onclick: () => tunnelLabel(t, reload) }, icon('edit', 'sm'));
    return el('section', { class: 'card tun' + (t.active ? ' active' : '') },
      el('div', { class: 'hd' },
        el('div', { class: 'title' }, el('div', { class: 'nm' }, el('span', { class: 'dot ' + dotFor(t.status) }), t.label || t.name, lbl),
          el('div', { class: 'lb' }, t.label ? t.name + ' · ' : '', ROLE[t.role], t.role === 'extra' ? ' №' + (xi + 1) : '')),
        el('div', { class: 'badges' }, el('span', { class: 'badge accent' }, t.proto), el('span', { class: 'badge ' + st[0] }, st[1]), t.forced ? el('span', { class: 'badge warn' }, 'вручную') : null)),
      el('div', { class: 'bd' }, kv),
      el('div', { class: 'rates' }, el('span', null, '↓ ', el('b', null, r ? fmtBits(r[1]) : '—')), el('span', null, '↑ ', el('b', null, r ? fmtBits(r[2]) : '—'))),
      el('div', { class: 'spark' }, sparkline(S.live[t.name])),
      el('div', { class: 'upw' }, uptimeBar(S.hist, t.name)),
      el('div', { class: 'ft' }, act, el('button', { class: 'btn sm', onclick: () => tunnelEditor(t, reload) }, icon('settings', 'sm'), 'Настроить'), el('span', { class: 'push' }), more));
  }
  function tunnelLabel(t, reload) {
    const inp = el('input', { class: 'input', value: t.label, maxlength: 40, placeholder: 'например: Германия, Hetzner' });
    const save = async () => { try { await api('/api/tunnel/label', { name: t.name, label: inp.value }); m.close(); reload(); } catch (e) { err(e); } };
    inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') save(); });
    const m = modal('Название ' + t.name, el('div', { class: 'field' }, el('label', null, 'Название (видно только в панели)'), inp),
      [el('button', { class: 'btn', onclick: () => m.close() }, 'Отмена'), el('button', { class: 'btn primary', onclick: save }, 'Сохранить')]);
  }
  function tunnelTest(t) {
    const body = el('div', null, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), 'Проверяю ' + t.name + ': HTTPS к трём адресам, DNS через туннель, внешний IP, MTU… (до 30 с)'));
    modal('Тест ' + (t.label || t.name), body, []);
    api('/api/tunnel/test', { name: t.name }).then((r) => {
      const it = (name, good, val) => el('div', { class: 'it' }, el('span', { class: 'dot ' + (good ? 'ok' : 'crit') }), name, el('span', { class: 'v' }, val));
      replace(body,
        el('div', { class: 'alert ' + (r.ok ? 'ok' : 'crit') }, icon(r.ok ? 'okc' : 'alert'), el('div', null, r.ok ? 'Канал работает' : 'Канал не пропускает трафик')),
        el('div', { class: 'spacer' }),
        el('div', { class: 'test-list' },
          it('Handshake', r.handshake >= 0 && r.handshake < 180, r.handshake >= 0 ? fmtAge(r.handshake) : 'нет'),
          r.https.map((h) => it('HTTPS ' + h.target, h.ok, h.ok ? h.ms + ' мс' : 'нет ответа')),
          it('DNS через туннель (DoH)', r.dns, r.dns ? 'работает' : 'нет'),
          it('Внешний IP', !!r.ip, r.ip ? secret('tip-' + t.name, r.ip) : 'не получен'),
          r.mtu ? it('MTU ' + (t.mtu || ''), r.mtu === 'ok', r.mtu === 'ok' ? 'проходит' : 'пакеты не проходят — подберите MTU') : null));
    }).catch((e) => replace(body, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))));
  }

  // ---------- редактор туннеля: параметры, текст, история, качество, экспорт
  const FGROUPS = [
    ['Сервер', [['Peer', 'Endpoint'], ['Peer', 'AllowedIPs'], ['Peer', 'PersistentKeepalive']]],
    ['Интерфейс', [['Interface', 'Address'], ['Interface', 'MTU'], ['Interface', 'DNS']]],
    ['Ключи', [['Interface', 'PrivateKey'], ['Peer', 'PublicKey'], ['Peer', 'PresharedKey']]],
    ['Обфускация AmneziaWG', [['Interface', 'Jc'], ['Interface', 'Jmin'], ['Interface', 'Jmax'], ['Interface', 'S1'], ['Interface', 'S2'], ['Interface', 'H1'], ['Interface', 'H2'], ['Interface', 'H3'], ['Interface', 'H4']]],
    ['AmneziaWG 2.0', [['Interface', 'S3'], ['Interface', 'S4'], ['Interface', 'I1'], ['Interface', 'I2'], ['Interface', 'I3'], ['Interface', 'I4'], ['Interface', 'I5']]],
  ];
  const MASKV = '<скрыто>';
  async function tunnelEditor(t, reload, start) {
    let d;
    try { d = await api('/api/tunnel/fields?name=' + encodeURIComponent(t.name)); } catch (e) { err(e); return; }
    const body = el('div');
    const foot = el('div', { class: 'row wrap grow' });
    let cur = start || 'form';
    const tb = el('div', { class: 'tabs' });
    const TABS = [['form', 'Параметры'], ['text', 'Текст конфига'], ['hist', 'История (' + d.revisions + ')'], ['quality', 'Качество'], ['export', 'Ещё']];
    const m = modal((t.label || t.name) + ' · настройка', el('div', null, tb, body), [foot], { wide: true, sticky: true });
    const show = (k) => {
      cur = k;
      replace(tb, TABS.map(([id, name]) => el('button', { class: 'tab' + (id === cur ? ' on' : ''), onclick: () => show(id) }, name)));
      clear(body); clear(foot);
      ({ form: edForm, text: edText, hist: edHist, quality: edQuality, export: edExport })[k]();
    };
    const res = el('div', { class: 'res hidden' });
    async function applyFlow(payload, btn) {
      await busy(btn, async () => {
        let p;
        try { p = await api('/api/tunnel/preview', Object.assign({ name: t.name }, payload)); } catch (e) { err(e); return; }
        if (p.errors.length) {
          replace(res, 'Не принято:\n• ' + p.errors.join('\n• ')); res.classList.remove('hidden'); res.classList.add('bad');
          return;
        }
        if (!p.changed) { toast('Изменений нет'); return; }
        const go = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Применить');
        const cm = modal('Проверьте изменения · ' + t.name, el('div', null,
          el('p', { class: 'muted small' }, 'Туннель будет пересоздан с новым конфигом (несколько секунд без трафика через него). Если он не поднимется — вернётся прежний конфиг. Прежняя версия сохранится в истории.'),
          diffView(p.old, p.new)), [el('button', { class: 'btn', onclick: () => cm.close() }, 'Отмена'), go], { wide: true });
        go.addEventListener('click', () => busy(go, async () => {
          try {
            const x = await api('/api/tunnel/conf', Object.assign({ name: t.name }, payload));
            cm.close();
            replace(res, x.msg); res.classList.remove('hidden', 'bad');
            (x.ok ? ok : err)(x.ok ? 'Конфиг применён' : 'Конфиг не применён: возвращён прежний');
            reload();
            d = await api('/api/tunnel/fields?name=' + encodeURIComponent(t.name));
            TABS[2][1] = 'История (' + d.revisions + ')';
            replace(tb, TABS.map(([id, name]) => el('button', { class: 'tab' + (id === cur ? ' on' : ''), onclick: () => show(id) }, name)));
          } catch (e) { err(e); }
        }));
      });
    }
    function edForm() {
      const sch = {};
      d.schema.forEach((x) => { sch[x.sec + '.' + x.key] = x; });
      const ctl = {};
      const groups = FGROUPS.map(([title, keys]) => {
        const has2 = keys.some(([s, k]) => (d.fields[s] || {})[k]);
        const rows = keys.map(([s, k]) => {
          const x = sch[s + '.' + k] || { hint: '' };
          const v = (d.fields[s] || {})[k] || '';
          let inp;
          if (x.secret) {
            inp = el('input', { class: 'input mono', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: v ? 'задан — не показывается' : 'не задан' });
            ctl[s + '.' + k] = () => (inp.value.trim() ? inp.value.trim() : (v ? MASKV : ''));
          } else if (/^I[1-5]$/.test(k)) {
            inp = el('textarea', { class: 'input mono', rows: 2, spellcheck: 'false' }); inp.value = v;
            ctl[s + '.' + k] = () => inp.value.trim();
          } else {
            inp = el('input', { class: 'input mono', value: v, spellcheck: 'false', autocomplete: 'off', inputmode: /^(Jc|Jmin|Jmax|S\d|MTU|PersistentKeepalive)$/.test(k) ? 'numeric' : 'text' });
            ctl[s + '.' + k] = () => inp.value.trim();
          }
          ctl[s + '.' + k].orig = x.secret ? (v ? MASKV : '') : v;
          return el('div', { class: 'field' }, el('label', null, k, x.req ? el('span', { class: 'req' }, ' *') : null), inp, x.hint ? el('span', { class: 'hint' }, x.hint) : null);
        });
        const g = el('div', { class: 'form-grid' }, rows);
        if (title === 'AmneziaWG 2.0' || title === 'Ключи') {
          return el('details', { class: 'fgroup', open: title === 'AmneziaWG 2.0' ? has2 : false }, el('summary', null, title, title === 'Ключи' ? el('span', { class: 'muted small' }, ' — менять только при смене сервера или ключей') : null), g);
        }
        return el('div', { class: 'fgroup' }, el('h3', null, title), g);
      });
      add(body, [
        d.peers > 1 ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, 'В конфиге несколько [Peer]: форма меняет только первый. Остальные — во вкладке «Текст конфига».')) : null,
        d.other.length ? el('div', { class: 'small muted' }, 'Другие строки конфига сохраняются как есть: ' + d.other.join(', ')) : null,
        groups, res]);
      const chk = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Проверить и применить');
      chk.addEventListener('click', () => {
        const f = { Interface: {}, Peer: {} };
        for (const [key, g] of Object.entries(ctl)) {
          const val = g();
          if (val !== g.orig) { const [s, k] = key.split('.'); f[s][k] = val; }
        }
        if (!Object.keys(f.Interface).length && !Object.keys(f.Peer).length) { toast('Изменений нет'); return; }
        applyFlow({ fields: f }, chk);
      });
      add(foot, [el('span', { class: 'small muted grow' }, 'Файл: ' + d.path), el('button', { class: 'btn', onclick: () => m.close() }, 'Закрыть'), chk]);
    }
    function edText() {
      const ta = el('textarea', { class: 'input tall', spellcheck: 'false', autocomplete: 'off' });
      ta.value = d.text;
      add(body, [
        el('div', { class: 'alert info' }, icon('lock'), el('div', null, 'Ключи заменены на «', el('code', null, MASKV), '» — такие строки сохранят прежнее значение. Новый конфиг можно вставить целиком или перетащить файл. Строки PostUp/PreDown не допускаются.')),
        el('div', { class: 'spacer' }), dropZone((txt) => { ta.value = txt; toast('Файл загружен: проверьте и примените'); }, 'Заменить конфиг этого туннеля файлом .conf'),
        el('div', { class: 'spacer' }), ta, res]);
      const chk = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Проверить и применить');
      chk.addEventListener('click', () => {
        if (/^\s*vpn:\/\//.test(ta.value)) { m.close(); importDialog(reload, t.name, ta.value); return; }
        applyFlow({ text: ta.value }, chk);
      });
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, 'Закрыть'), chk]);
    }
    async function edHist() {
      const box = el('div', null, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), 'загрузка…'));
      add(body, [el('p', { class: 'muted small' }, 'Каждое изменение конфига сохраняется (до 15 версий, права 600). Можно сравнить с текущим и вернуть.'), box]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, 'Закрыть')]);
      try {
        const r = await api('/api/tunnel/revisions?name=' + encodeURIComponent(t.name));
        replace(box, r.revisions.length ? el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
          el('thead', null, el('tr', null, el('th', null, 'Версия'), el('th', null, 'Что'), el('th', null, 'Сервер'), el('th', null, ''), el('th', null, ''))),
          el('tbody', null, r.revisions.map((v) => el('tr', null,
            el('td', { class: 'nowrap' }, fmtTime(v.time, true), v.current ? el('span', { class: 'badge ok' }, 'текущая') : null),
            el('td', { class: 'muted' }, v.why || '—'),
            el('td', null, el('span', { class: 'mono small' }, v.summary.endpoint || '—'), ' ', el('span', { class: 'badge outline' }, v.summary.proto)),
            el('td', { class: 'r nowrap' }, el('button', { class: 'btn sm', onclick: async () => {
              try { const x = await api('/api/tunnel/revision?name=' + encodeURIComponent(t.name) + '&id=' + encodeURIComponent(v.id)); modal('Версия ' + fmtTime(v.time, true) + ' → текущая', diffView(x.text, x.current), [], { wide: true }); } catch (e) { err(e); }
            } }, 'Сравнить')),
            el('td', { class: 'r nowrap' }, v.current ? null : el('button', { class: 'btn sm primary', onclick: async (e) => {
              if (!await confirmBox('Вернуть версию?', 'Конфиг ' + t.name + ' станет таким, как ' + fmtTime(v.time, true) + '. Текущий сохранится в истории.', 'Вернуть')) return;
              try { const x = await api('/api/tunnel/revision/restore', { name: t.name, id: v.id }); (x.ok ? ok : err)(x.msg.split('\n')[0]); reload(); show('hist'); } catch (ex) { err(ex); }
            } }, 'Вернуть'))))))) : el('div', { class: 'empty' }, 'Версий пока нет: они появятся после первого изменения.'));
      } catch (e) { replace(box, e.message); }
    }
    async function edQuality() {
      const rtt = el('div', { class: 'chart-wrap sm' }), loss = el('div', { class: 'chart-wrap sm' });
      const sp = el('div');
      const spOut = el('pre', { class: 'console hidden' });
      const size = el('select', { class: 'input' }, [5, 10, 25, 50].map((x) => el('option', { value: x, selected: x === 10 }, x + ' МБ')));
      size.style.width = 'auto';
      const run = el('button', { class: 'btn' }, icon('activity', 'sm'), 'Замерить скорость');
      add(body, [uptimeBar(S.hist, t.name), el('div', { class: 'spacer' }),
        el('div', { class: 'grid g-2e' }, el('div', null, el('h3', null, 'Задержка (RTT), мс'), rtt), el('div', null, el('h3', null, 'Потери, %'), loss)),
        el('div', { class: 'spacer' }), el('h3', null, 'Замеры скорости'), el('p', { class: 'small muted' }, 'Скачивание и отдача через этот туннель (speed.cloudflare.com). Трафик замера считается у провайдера VPN.'),
        el('div', { class: 'row' }, size, run), spOut, sp]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, 'Закрыть')]);
      const loadSp = async () => {
        const r = await api('/api/speed');
        const xs = r.history.filter((x) => x.iface === t.name).slice(0, 10);
        replace(sp, xs.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, 'Когда'), el('th', null, 'Загрузка'), el('th', null, 'Отдача'), el('th', null, 'Задержка'))),
          el('tbody', null, xs.map((x) => el('tr', null, el('td', null, fmtTime(x.t, true)), el('td', null, x.down_bps ? fmtBits(x.down_bps) : '—'), el('td', null, x.up_bps ? fmtBits(x.up_bps) : '—'), el('td', null, x.ping_ms ? x.ping_ms + ' мс' : '—'))))) : el('div', { class: 'empty' }, 'Замеров ещё не было'));
      };
      run.addEventListener('click', () => busy(run, async () => {
        spOut.classList.remove('hidden'); spOut.textContent = '';
        try { await runJob({ tool: 'speedtest', iface: t.name, mb: +size.value }, spOut); await loadSp(); } catch (e) { err(e); }
      }));
      try {
        if (!S.hist) S.hist = (await api('/api/history')).points;
        const pts = S.hist.filter((p) => p.tun && p.tun[t.name]);
        drawChart(rtt, [{ name: 'RTT', color: '--chart-rx', fill: true, points: pts.filter((p) => p.tun[t.name].rtt !== '').map((p) => [p.t, +p.tun[t.name].rtt]) }],
          { fmt: (v) => Math.round(v) + ' мс', empty: 'Нет данных: RTT меряется, когда включено переключение по качеству' });
        drawChart(loss, [{ name: 'Потери', color: '--crit', fill: true, points: pts.filter((p) => p.tun[t.name].loss !== '').map((p) => [p.t, +p.tun[t.name].loss]) }],
          { fmt: (v) => Math.round(v) + '%', max: 100, empty: 'Нет данных' });
        await loadSp();
      } catch (e) { err(e); }
    }
    function edExport() {
      const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), 'Скачать ' + t.name + '.conf');
      go.addEventListener('click', () => busy(go, async () => {
        try {
          const x = await api('/api/tunnel/export', { name: t.name, current: pw.value });
          const a = el('a', { href: URL.createObjectURL(new Blob([x.text], { type: 'text/plain' })), download: x.filename });
          document.body.appendChild(a); a.click(); a.remove(); pw.value = '';
          ok('Файл скачан: храните его как пароль');
        } catch (e) { err(e); }
      }));
      const extras = (S.ov ? S.ov.tunnels : []).filter((x) => x.role === 'extra').map((x) => x.name);
      const xi = extras.indexOf(t.name);
      const move = (dir) => async () => {
        const n = extras.slice(); n.splice(xi + dir, 0, n.splice(xi, 1)[0]);
        try { ok((await api('/api/tunnel/order', { extra: n })).msg); m.close(); reload(); } catch (ex) { err(ex); }
      };
      add(body, [
        el('h3', null, 'Скачать конфиг'),
        el('div', { class: 'alert warn' }, icon('key'), el('div', null, 'Файл содержит закрытый ключ роутера. Не отправляйте его в чаты. Одновременно использовать этот же конфиг на другом устройстве нельзя: сервер будет «перекидывать» сеанс между ними.')),
        el('div', { class: 'spacer' }), el('div', { class: 'input-group' }, el('div', { class: 'field grow' }, el('label', null, 'Ваш пароль от панели'), pw)), go,
        xi >= 0 ? [el('div', { class: 'spacer' }), el('h3', null, 'Приоритет'), el('p', { class: 'muted small' }, 'Порядок: основной → запасной → дополнительные. Сейчас этот туннель №' + (xi + 1) + ' из ' + extras.length + ' дополнительных.'),
          el('div', { class: 'row' }, el('button', { class: 'btn', disabled: xi === 0, onclick: move(-1) }, icon('up', 'sm'), 'Выше'),
            el('button', { class: 'btn', disabled: xi === extras.length - 1, onclick: move(1) }, 'Ниже'))] : null,
        t.role === 'extra' ? [el('div', { class: 'spacer' }), el('h3', null, 'Удалить туннель'),
          el('p', { class: 'muted small' }, 'Туннель будет остановлен и убран из сторожа вместе с его правилами. Файл конфига и история версий останутся на роутере.'),
          el('button', { class: 'btn danger', onclick: async () => {
            if (!await confirmBox('Удалить ' + t.name + '?', 'Туннель будет остановлен и убран из сторожа.', 'Удалить', true)) return;
            try { ok((await api('/api/tunnel/remove', { name: t.name })).msg); m.close(); reload(); } catch (ex) { err(ex); }
          } }, icon('trash', 'sm'), 'Удалить ' + t.name)]
          : el('p', { class: 'small muted' }, 'Основной и запасной туннели удаляются установщиком: install.sh → Компоненты → Туннели.')]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, 'Закрыть')]);
    }
    show(cur);
  }

  // ---------- импорт: файл, текст, ссылка vpn://
  function importDialog(reload, target, preset) {
    const ta = el('textarea', { class: 'input', rows: 7, spellcheck: 'false', placeholder: '[Interface]\nPrivateKey = …\n…\n\nили ссылка vpn://… из AmneziaVPN («Поделиться» → «Ключ»)' });
    if (preset) ta.value = preset;
    let fname = '';
    const res = el('div');
    const parse = el('button', { class: 'btn primary' }, icon('search', 'sm'), 'Разобрать');
    const foot = [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, 'Закрыть'), parse];
    const m = modal(target === 'new' ? 'Новый туннель' : 'Импорт конфига', el('div', null,
      dropZone((txt, n) => { ta.value = txt; fname = n; parse.click(); }),
      el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, 'Или вставьте текст конфига или ссылку vpn://'), ta), res), foot, { wide: true, sticky: true });
    parse.addEventListener('click', () => busy(parse, async () => {
      let r;
      try { r = await api('/api/import/parse', { data: ta.value }); } catch (e) { replace(res, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); return; }
      const f = r.fields;
      const info = el('dl', { class: 'kv' },
        el('dt', null, 'Источник'), el('dd', null, r.source === 'vpn://' ? 'ссылка AmneziaVPN' : r.source === 'json' ? 'JSON AmneziaVPN' : (fname || 'текст конфига')),
        el('dt', null, 'Протокол'), el('dd', null, el('span', { class: 'badge accent' }, r.proto)),
        el('dt', null, 'Сервер'), el('dd', null, el('span', { class: 'mono' }, f.Peer.Endpoint || '—')),
        el('dt', null, 'Адрес'), el('dd', null, el('span', { class: 'mono' }, f.Interface.Address || '—')),
        el('dt', null, 'MTU'), el('dd', null, f.Interface.MTU || 'по умолчанию'));
      const used = S.ov ? S.ov.tunnels : [];
      let sug = 'awgalt1';
      for (let i = 1; used.some((t) => t.name === sug); i++) sug = 'awgalt' + (i + 1);
      const nm = el('input', { class: 'input mono', value: sug, maxlength: 13, autocapitalize: 'off', spellcheck: 'false' });
      const lb = el('input', { class: 'input', maxlength: 40, placeholder: 'например: Нидерланды' });
      const tsel = el('select', { class: 'input' }, el('option', { value: 'new' }, 'Новый дополнительный туннель'),
        used.map((t) => el('option', { value: t.name, selected: target === t.name }, 'Заменить конфиг: ' + (t.label ? t.label + ' (' + t.name + ')' : t.name) + ' — ' + ROLE[t.role].toLowerCase())));
      const newBox = el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, 'Имя интерфейса'), nm, el('span', { class: 'hint' }, 'awg + до 10 латинских букв/цифр')),
        el('div', { class: 'field' }, el('label', null, 'Название'), lb));
      const sync = () => newBox.classList.toggle('hidden', tsel.value !== 'new');
      tsel.addEventListener('change', sync); sync();
      const out = el('div', { class: 'res hidden' });
      const apply = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Применить');
      apply.addEventListener('click', () => busy(apply, async () => {
        if (tsel.value !== 'new' && !await confirmBox('Заменить конфиг ' + tsel.value + '?', 'Туннель будет пересоздан с новым конфигом. Прежний сохранится в истории версий; если новый не поднимется — вернётся прежний.', 'Заменить')) return;
        try {
          const x = await api('/api/import/apply', { token: r.token, target: tsel.value, name: nm.value.trim(), label: lb.value.trim() });
          out.textContent = x.msg; out.classList.remove('hidden');
          (x.ok ? ok : err)(x.ok ? 'Готово' : 'Применено с ошибкой — смотрите вывод');
          reload();
        } catch (e) { out.textContent = e.message; out.classList.remove('hidden'); err(e); }
      }));
      replace(res, el('div', { class: 'spacer' }),
        r.errors.length ? el('div', { class: 'alert crit' }, icon('alert'), el('div', null, 'Конфиг не подходит:', el('ul', null, r.errors.map((x) => el('li', null, x))))) : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, 'Конфиг распознан. Ключи остаются на роутере и в браузер не возвращаются.')),
        r.warnings.length ? el('div', { class: 'alert warn' }, icon('info'), el('div', null, r.warnings.join('; '))) : null,
        el('div', { class: 'spacer' }), info,
        r.ok ? [el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, 'Куда'), tsel), newBox, out] : null);
      const ft = m.root.querySelector('.ft');
      if (r.ok) { parse.classList.remove('primary'); if (!ft.contains(apply)) ft.appendChild(apply); } else { apply.remove(); parse.classList.add('primary'); }
    }));
    if (preset) parse.click();
  }
  async function runJob(payload, pre) {
    const j = await api('/api/tool', payload);
    let off = 0, text = '';
    for (;;) {
      const r = await api('/api/job?id=' + j.job + '&from=' + off);
      off = r.len;
      if (r.out) { text += r.out; if (pre) { paint(pre, text); pre.scrollTop = pre.scrollHeight; } }
      if (r.done) return { rc: r.rc, text };
      await new Promise((ok2) => setTimeout(ok2, 1000));
    }
  }

  // ===================================================================== КЛИЕНТЫ
  function clientsTable(list, compact) {
    if (!list.length) return el('div', { class: 'empty' }, 'Сейчас через туннель никто не ходит (или conntrack недоступен)');
    return el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
      el('thead', null, el('tr', null, el('th', null, 'Устройство'), el('th', null, 'IP'), compact ? null : el('th', null, 'MAC'), el('th', null, 'Туннель'),
        el('th', { class: 'r' }, 'Соединений'), compact ? null : el('th', { class: 'r' }, 'Трафик'), compact ? null : el('th', null, 'Куда чаще всего'))),
      el('tbody', null, list.map((c) => el('tr', null,
        el('td', null, el('span', { class: 'row' }, el('span', { class: 'cav' }, icon('laptop', 'sm')), el('b', null, c.name || 'без имени'))),
        el('td', null, el('span', { class: 'mono' }, c.ip)),
        compact ? null : el('td', null, el('span', { class: 'mono small muted' }, c.mac || '—')),
        el('td', null, el('span', { class: 'badge accent' }, c.tunnel)),
        el('td', { class: 'r' }, c.conns),
        compact ? null : el('td', { class: 'r nowrap' }, c.bytes ? fmtBytes(c.bytes) : '—'),
        compact ? null : el('td', { class: 'mono small muted' }, c.top.join(', ')))))));
  }
  PAGES.clients = function (main) {
    const box = el('div');
    const q = el('input', { class: 'input', placeholder: 'поиск по имени, IP, MAC', spellcheck: 'false' });
    q.style.maxWidth = '260px'; q.style.height = '30px';
    const sum = el('span', { class: 'muted small' });
    let data = { clients: [] };
    const show = () => {
      const f = q.value.trim().toLowerCase();
      replace(box, clientsTable(data.clients.filter((c) => !f || (c.name + ' ' + c.ip + ' ' + c.mac).toLowerCase().includes(f)), false));
      replace(sum, data.clients.length + ' устр. · ' + data.total + ' соединений');
    };
    q.addEventListener('input', show);
    add(main, [head('Клиенты в туннеле'),
      el('div', { class: 'alert info' }, icon('info'), el('div', null, 'Устройства LAN, чьи соединения сейчас идут через туннели (по таблице conntrack: метка PBR ', el('code', null, '—'), ' или адрес туннеля). Кто попадает в туннель, задаётся правилами PBR в UniFi и доменами в «Маршрутизации».')),
      el('div', { class: 'spacer' }),
      el('section', { class: 'card' }, el('div', { class: 'hd' }, icon('users'), el('h2', null, 'Сейчас'), sum, q), box)]);
    every(5000, async () => {
      data = await api('/api/clients');
      const c = main.querySelector('.alert.info code'); if (c) c.textContent = data.mark || '—';
      show();
    });
  };

  // ===================================================================== формы настроек
  const SPEC = {
    RECOVER_SEC: { t: 'num', unit: 'с', hint: 'Сколько основной канал должен проработать стабильно, прежде чем сторож вернётся на него.' },
    QUALITY: { t: 'bool', hint: 'Уходить с канала, если потери или задержка выше порога, а другой канал лучше.' },
    QUALITY_LOSS: { t: 'num', unit: '%', hint: 'Потери пакетов, при которых канал считается плохим.' },
    QUALITY_RTT: { t: 'num', unit: 'мс', hint: 'Порог задержки; 0 — не учитывать.' },
    MIN_DWELL: { t: 'num', unit: 'с', hint: 'Пауза после переключения, чтобы каналы не «прыгали».' },
    EXTRA_SUBNETS: { t: 'list', ph: '192.168.3.0/24', hint: 'Подсети VPN-сервера на роутере (WireGuard / L2TP / OpenVPN): их клиенты тоже идут через туннель.' },
    TUN_DOMAINS: { t: 'list', ph: 'youtube.com\ngooglevideo.com', hint: 'Сайты, которые открываются через туннель для всей LAN (или выбранных клиентов) без PBR. Поддомены включаются. Клиенты должны спрашивать DNS у роутера.' },
    TUN_CLIENTS: { t: 'list', ph: '192.168.1.50\n192.168.1.0/28', hint: 'Для кого действуют домены через туннель. Пусто — вся LAN.' },
    DIRECT_DOMAINS: { t: 'list', ph: 'gosuslugi.ru\nsberbank.ru', hint: 'Устройства под PBR откроют эти сайты напрямую, мимо туннеля.' },
    DIRECT_SUBNETS: { t: 'list', ph: '95.173.128.0/19', hint: 'Адреса и подсети, куда устройства под PBR ходят напрямую.' },
    LEAK_GUARD: { t: 'bool', hint: 'Запрет выхода трафика PBR-устройств в WAN мимо туннеля — вторая линия защиты после blackhole.' },
    LEAK_V6: { t: 'choice', opts: [['block', 'Блокировать'], ['off', 'Не трогать']], hint: 'IPv6 устройств под PBR идёт мимо туннеля: его стоит блокировать.' },
    UI_FIX: { t: 'bool', hint: 'Соединения самого роутера с облаком UniFi (unifi.ui.com) — через туннель. Нужно, если ui.com недоступен напрямую.' },
    UI_DOMAINS: { t: 'list', hint: 'Домены облака UniFi.' },
    UI_DNS: { t: 'text', hint: 'DNS-сервер для доменов UniFi (запрос уходит через туннель).' },
    DNS_ALL_TUNNEL: { t: 'bool', hint: 'Все DNS-запросы самого роутера — через туннель (защита от подмены DNS провайдером).' },
    METRICS_PORT: { t: 'num', hint: 'Порт /metrics для Prometheus. Пусто — выключено.' },
  };
  let SETTINGS_CACHE = null;
  async function settings(force) {
    if (!SETTINGS_CACHE || force) SETTINGS_CACHE = await api('/api/settings');
    return SETTINGS_CACHE;
  }
  function settingsForm(title, ic, keys, data, note) {
    const ctl = {};
    const rows = keys.map((k) => {
      const sp = SPEC[k], v = data.values[k] || '';
      let c;
      if (sp.t === 'bool') {
        const inp = el('input', { type: 'checkbox', checked: v === 'yes' });
        c = el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }));
        ctl[k] = () => (inp.checked ? 'yes' : 'no');
      } else if (sp.t === 'choice') {
        const s = el('select', { class: 'input' }, sp.opts.map(([val, name]) => el('option', { value: val, selected: v === val }, name)));
        c = s; ctl[k] = () => s.value;
      } else if (sp.t === 'list') {
        const ta = el('textarea', { class: 'input', placeholder: sp.ph || '', spellcheck: 'false', rows: 3 });
        ta.value = v.split(/\s+/).filter(Boolean).join('\n');
        c = ta; ctl[k] = () => ta.value.split(/[\s,]+/).filter(Boolean).join(' ');
      } else {
        const inp = el('input', { class: 'input', value: v, inputmode: sp.t === 'num' ? 'numeric' : 'text', placeholder: sp.unit || '' });
        c = sp.unit ? el('div', { class: 'input-group' }, inp, el('span', { class: 'muted row' }, sp.unit)) : inp;
        ctl[k] = () => inp.value.trim();
      }
      return el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, data.labels[k] || k), el('span', null, sp.hint), el('div', { class: 'small muted mono' }, k)),
        el('div', { class: 'ctl' + (sp.t === 'bool' ? ' auto' : '') }, c));
    });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Применить');
    const res = el('div', { class: 'res hidden' });
    save.addEventListener('click', () => busy(save, async () => {
      const ch = {};
      for (const k of keys) if (ctl[k]() !== (data.values[k] || '')) ch[k] = ctl[k]();
      if (!Object.keys(ch).length) { toast('Изменений нет'); return; }
      try {
        const x = await api('/api/settings', { values: ch });
        Object.assign(data.values, ch);
        res.textContent = x.msg; res.classList.remove('hidden');
        ok('Сохранено');
      } catch (e) { err(e); }
    }));
    return card(title, el('div', null, note || null, rows, res), { icon: ic, foot: save });
  }

  // ===================================================================== МАРШРУТИЗАЦИЯ
  PAGES.routing = async function (main) {
    add(main, head('Маршрутизация'));
    const body = el('div', { class: 'stack' }, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), 'загрузка…'));
    main.appendChild(body);
    let d, ov;
    try { [d, ov] = await Promise.all([settings(true), api('/api/overview')]); } catch (e) { replace(body, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); return; }
    updateChrome(ov);
    const p = d.pbr;
    const pbr = card('Policy-Based Routing UniFi', el('div', { class: 'grid g-2e' },
      el('dl', { class: 'kv' },
        el('dt', null, 'Профиль (интерфейс)'), el('dd', null, el('span', { class: 'mono' }, p.RAIL_IF || '—')),
        el('dt', null, 'Таблица'), el('dd', null, el('span', { class: 'mono' }, p.TABLE || '—')),
        el('dt', null, 'Метка (fwmark/mask)'), el('dd', null, el('span', { class: 'mono' }, p.MARK || '—')),
        el('dt', null, 'Приоритет ip rule'), el('dd', null, el('span', { class: 'mono' }, p.PRIO || '—')),
        el('dt', null, 'Kill switch (blackhole)'), el('dd', null, ov.pbr.killswitch ? el('span', { class: 'badge ok' }, 'на месте') : el('span', { class: 'badge crit' }, 'нет')),
        el('dt', null, 'Каналы по приоритету'), el('dd', null, [p.MAIN, p.BACKUP].concat((p.TUNNELS_EXTRA || '').split(' ')).filter(Boolean).join(' → '))),
      el('div', null, el('div', { class: 'small muted' }, 'Маршруты в таблице ' + (p.TABLE || '')),
        el('pre', { class: 'res' }, ov.pbr.routes.join('\n') || '(пусто)'))),
    { icon: 'route', right: el('a', { class: 'btn sm', href: '#/tools' }, 'Проверить') });
    replace(body,
      el('div', { class: 'alert info' }, icon('info'), el('div', null, 'Какие устройства идут через туннель, задаётся в UniFi Network: Settings → Routing → Policy-Based Routes (профиль ', el('b', null, p.RAIL_IF || '—'), '). Здесь — то, что работает поверх: домены, исключения, защита от утечек.')),
      pbr,
      settingsForm('Домены через туннель', 'globe', ['TUN_DOMAINS', 'TUN_CLIENTS'], d),
      settingsForm('Исключения: напрямую мимо туннеля', 'link', ['DIRECT_DOMAINS', 'DIRECT_SUBNETS'], d),
      settingsForm('Защита от утечек', 'shield', ['LEAK_GUARD', 'LEAK_V6', 'DNS_ALL_TUNNEL'], d),
      settingsForm('VPN-сервер роутера', 'users', ['EXTRA_SUBNETS'], d),
      settingsForm('Облако UniFi', 'globe', ['UI_FIX', 'UI_DOMAINS', 'UI_DNS'], d));
  };

  // ===================================================================== ИНСТРУМЕНТЫ
  const TOOLS = [
    ['diagnose', 'Диагностика', 'stetho', 'Дерево причин: WAN → туннели → PBR → NAT → IPv6 → службы. Итог — первая причина и команда исправления.'],
    ['selftest', 'Самопроверка', 'okc', 'Проверка установки: файлы, службы, правила, маршруты, handshake.'],
    ['selftest-full', 'Проверка kill switch', 'shield', 'Самопроверка с кратким отключением туннелей: трафик PBR не должен уйти в WAN.'],
    ['switch-test', 'Тест переключения', 'switch', 'Имитация падения основного канала: сторож должен уйти на запасной (до 45 с).'],
    ['audit', 'Аудит', 'search', 'Права на файлы, ключи, открытые порты, лишние правила.'],
    ['dedup', 'Очистка дубликатов', 'layers', 'Убрать повторяющиеся правила iptables, если они накопились.'],
    ['mtu', 'Подбор MTU', 'ruler', 'Найти наибольший MTU, который проходит через каждый туннель.'],
    ['guard-check', 'Проверка защиты', 'shield', 'Правила защиты от утечек, наборы доменов и исключений.'],
    ['self-check', 'Трафик роутера', 'router', 'Проверка awg-self: unifi.ui.com и DNS самого роутера.'],
    ['subnets-check', 'Подсети VPN', 'users', 'Правила для клиентов VPN-сервера роутера.'],
    ['self-reconnect', 'Переподключить облако', 'refresh', 'Сбросить соединения роутера с облаком UniFi, чтобы они пошли новым путём.'],
    ['report', 'Отчёт для помощи', 'file', 'Обезличенный отчёт (ключи, токены и IP скрыты) — приложить к issue на GitHub.'],
  ];
  PAGES.tools = function (main) {
    const out = el('pre', { class: 'console', 'aria-live': 'polite' }, 'Выберите инструмент — вывод появится здесь.');
    const status = el('span', { class: 'muted small' });
    const dl = el('span');
    const outCard = el('section', { class: 'card' }, el('div', { class: 'hd' }, icon('logs'), el('h2', null, 'Вывод'), dl, status), out);
    let polling = null;
    async function runTool(payload, title) {
      if (polling) clearInterval(polling);
      replace(dl);
      out.textContent = '';
      replace(status, el('span', { class: 'row' }, el('span', { class: 'spinner sm' }), title + '…'));
      outCard.scrollIntoView({ behavior: 'smooth', block: 'start' });
      let j;
      try { j = await api(payload.ep || '/api/tool', payload); } catch (e) { replace(status, ''); out.textContent = e.message; return; }
      let off = 0, text = '';
      const poll = async () => {
        try {
          const r = await api('/api/job?id=' + j.job + '&from=' + off);
          off = r.len;
          if (r.out) { text += r.out; paint(out, text); out.scrollTop = out.scrollHeight; }
          if (r.done) {
            clearInterval(polling); polling = null;
            replace(status, el('span', { class: 'badge ' + (r.rc === 0 ? 'ok' : 'warn') }, r.rc === 0 ? 'готово' : 'код ' + r.rc));
            const m = text.match(/awg-report-\d{8}-\d{6}\.txt/);
            if (m) replace(dl, el('a', { class: 'btn sm', href: '/api/report/file?name=' + m[0], download: m[0] }, icon('download', 'sm'), 'Скачать отчёт'));
          }
        } catch (e) { clearInterval(polling); polling = null; replace(status, e.message); }
      };
      polling = setInterval(poll, 1000);
      S.timers.push(polling);
      poll();
    }
    const tiles = TOOLS.map(([k, name, ic, desc]) => el('div', { class: 'card tool' },
      el('div', { class: 'ti' }, el('span', { class: 'ib' }, icon(ic)), name), el('p', null, desc),
      el('div', null, el('button', { class: 'btn sm', onclick: async () => {
        if ((k === 'selftest-full' || k === 'switch-test') && !await confirmBox(name, k === 'switch-test' ? 'Основной канал будет «уронен» флагом на время теста. Трафик PBR ненадолго уйдёт на запасной канал.' : 'Туннели будут кратко отключены: трафик PBR остановится на несколько секунд.', 'Запустить')) return;
        runTool({ tool: k }, name);
      } }, icon('play', 'sm'), 'Запустить'))));
    const dom = el('input', { class: 'input', placeholder: 'youtube.com', autocapitalize: 'off', spellcheck: 'false' });
    const domGo = () => { if (dom.value.trim()) runTool({ tool: 'domain-check', domain: dom.value.trim() }, 'Проверка ' + dom.value.trim()); };
    dom.addEventListener('keydown', (e) => { if (e.key === 'Enter') domGo(); });
    const mtuSel = el('select', { class: 'input' });
    const spSel = el('select', { class: 'input' }), spSize = el('select', { class: 'input' }, [5, 10, 25, 50].map((x) => el('option', { value: x, selected: x === 10 }, x + ' МБ')));
    const pgSel = el('select', { class: 'input' }), pgHost = el('input', { class: 'input', value: '1.1.1.1', spellcheck: 'false', autocapitalize: 'off' });
    spSize.style.width = 'auto';
    const spHist = el('div');
    const loadSp = async () => {
      const r = await api('/api/speed');
      replace(spHist, r.history.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, 'Когда'), el('th', null, 'Канал'), el('th', null, '↓'), el('th', null, '↑'), el('th', null, 'Задержка'))),
        el('tbody', null, r.history.slice(0, 8).map((x) => el('tr', null, el('td', { class: 'nowrap' }, fmtTime(x.t)), el('td', null, el('span', { class: 'mono' }, x.iface)),
          el('td', { class: 'nowrap' }, x.down_bps ? fmtBits(x.down_bps) : '—'), el('td', { class: 'nowrap' }, x.up_bps ? fmtBits(x.up_bps) : '—'), el('td', null, x.ping_ms ? x.ping_ms + ' мс' : '—'))))) : el('div', { class: 'small muted' }, 'Замеров ещё не было'));
    };
    loadSp().catch(() => {});
    api('/api/overview').then((ov) => {
      updateChrome(ov);
      const opts = () => ov.tunnels.map((t) => el('option', { value: t.name }, t.label ? t.label + ' (' + t.name + ')' : t.name));
      replace(mtuSel, opts());
      replace(spSel, el('option', { value: 'all' }, 'все туннели и WAN'), opts(), el('option', { value: 'wan' }, 'WAN напрямую (' + (ov.wan.if || '?') + ')'));
      replace(pgSel, opts(), el('option', { value: 'wan' }, 'WAN напрямую'));
    }).catch(() => {});
    const watchDone = async () => { await new Promise((r) => setTimeout(r, 2000)); for (let i = 0; i < 300 && polling; i++) await new Promise((r) => setTimeout(r, 1000)); loadSp().catch(() => {}); };
    add(main, [
      head('Инструменты'),
      el('div', { class: 'grid g-2e' },
        card('Проверка домена', el('div', null, el('p', { class: 'muted small' }, 'Куда пойдёт сайт, открывается ли он через туннель и напрямую, попал ли в наборы доменов.'),
          el('div', { class: 'input-group' }, dom, el('button', { class: 'btn primary', onclick: domGo }, icon('search', 'sm'), 'Проверить'))), { icon: 'globe' }),
        card('Подобрать и применить MTU', el('div', null, el('p', { class: 'muted small' }, 'Найти MTU для туннеля и сразу записать его в конфиг (туннель перезапустится).'),
          el('div', { class: 'input-group' }, mtuSel, el('button', { class: 'btn', onclick: async () => {
            if (!await confirmBox('MTU для ' + mtuSel.value, 'Туннель будет перезапущен с новым MTU.', 'Подобрать и применить')) return;
            runTool({ tool: 'mtu-apply', name: mtuSel.value }, 'MTU ' + mtuSel.value);
          } }, icon('ruler', 'sm'), 'Применить'))), { icon: 'ruler' })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2e' },
        card('Скорость каналов', el('div', null, el('p', { class: 'muted small' }, 'Загрузка и отдача через туннель и напрямую (speed.cloudflare.com). Сравните каналы между собой и с WAN.'),
          el('div', { class: 'input-group' }, spSel, spSize, el('button', { class: 'btn primary', onclick: () => { runTool({ tool: 'speedtest', iface: spSel.value, mb: +spSize.value }, 'Замер скорости'); watchDone(); } }, icon('activity', 'sm'), 'Замерить')),
          el('div', { class: 'spacer' }), spHist), { icon: 'activity' }),
        card('Ping и трассировка', el('div', null, el('p', { class: 'muted small' }, 'Проверить доступность адреса через выбранный туннель или напрямую.'),
          el('div', { class: 'input-group' }, pgHost, pgSel),
          el('div', { class: 'spacer' }),
          el('div', { class: 'row' }, el('button', { class: 'btn', onclick: () => runTool({ ep: '/api/net', kind: 'ping', host: pgHost.value.trim(), iface: pgSel.value }, 'ping ' + pgHost.value) }, icon('activity', 'sm'), 'Ping'),
            el('button', { class: 'btn', onclick: () => runTool({ ep: '/api/net', kind: 'trace', host: pgHost.value.trim(), iface: pgSel.value }, 'трассировка ' + pgHost.value) }, icon('route', 'sm'), 'Трассировка'))), { icon: 'globe' })),
      el('div', { class: 'spacer' }),
      card('Сверка правил с эталоном (drift)', el('div', null,
        el('p', { class: 'muted small' }, 'Эталон снимается после установки и обновления. Сверка покажет, какие правила iptables, ip rule, маршруты PBR и службы пропали или появились — и чьи они: набора или UniFi. «Вернуть правила набора» перезапускает только службы UDR-Amnezia; правила UniFi не трогаются никогда.'),
        el('div', { class: 'row wrap' },
          el('button', { class: 'btn primary', onclick: () => runTool({ tool: 'drift' }, 'Сверка') }, icon('search', 'sm'), 'Сверить'),
          el('button', { class: 'btn', onclick: async () => { if (await confirmBox('Вернуть правила набора?', 'Службы awg-failover, guard, self, subnets будут перезапущены (на секунды прерывается трафик PBR).', 'Вернуть')) runTool({ tool: 'drift-repair' }, 'Восстановление'); } }, icon('wrench', 'sm'), 'Вернуть правила набора'),
          el('button', { class: 'btn', onclick: async () => { if (await confirmBox('Принять текущее состояние?', 'Текущие правила станут эталоном. Делайте это, когда всё работает (например, после изменения PBR в UniFi).', 'Принять')) runTool({ tool: 'drift-save' }, 'Новый эталон'); } }, icon('check', 'sm'), 'Принять текущее как эталон'))), { icon: 'layers' }),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-tools' }, tiles),
      el('div', { class: 'spacer' }), outCard]);
  };
  function paint(pre, text) {
    clear(pre);
    for (const line of text.split('\n')) {
      let cls = '';
      if (/^\s*(OK|ОК)\b|✓/.test(line)) cls = 'ok';
      else if (/^\s*(WARN|ВНИМАНИЕ)\b|⚠/.test(line)) cls = 'warn';
      else if (/^\s*(FAIL|ОШИБКА|ПРИЧИНА)\b|✗/.test(line)) cls = 'fail';
      else if (/^\s*(==|──|\[\d+\]|#)/.test(line)) cls = 'h';
      pre.appendChild(cls ? el('span', { class: cls }, line) : document.createTextNode(line));
      pre.appendChild(document.createTextNode('\n'));
    }
  }

  // ===================================================================== ЖУРНАЛЫ
  const LOGS = [['events', 'События'], ['failover', 'Сторож'], ['journal', 'systemd'], ['notify', 'Уведомления'], ['bot', 'Бот'], ['install', 'Установка'], ['update', 'Обновление'], ['restore', 'Восстановление'], ['audit', 'Действия в панели']];
  PAGES.logs = function (main, sub) {
    const cur = LOGS.some((l) => l[0] === sub) ? sub : 'events';
    add(main, [head('Журналы'), tabs(LOGS, cur, (id) => { location.hash = '#/logs/' + id; })]);
    if (cur === 'events') return eventsPage(main);
    const box = el('pre', { class: 'logbox' }, 'загрузка…');
    const auto = el('input', { type: 'checkbox', checked: true });
    const n = el('select', { class: 'input' }, ['200', '500', '1000', '3000'].map((x) => el('option', { value: x }, x + ' строк')));
    n.style.width = 'auto'; n.style.height = '30px';
    const filt = el('input', { class: 'input', placeholder: 'фильтр', spellcheck: 'false' });
    filt.style.height = '30px'; filt.style.maxWidth = '220px';
    let text = '';
    const show = () => {
      const f = filt.value.trim().toLowerCase();
      const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
      box.textContent = (f ? text.split('\n').filter((l) => l.toLowerCase().includes(f)).join('\n') : text) || '(пусто)';
      if (atBottom) box.scrollTop = box.scrollHeight;
    };
    const load = async () => { text = (await api('/api/logs?kind=' + cur + '&n=' + n.value)).text; show(); };
    filt.addEventListener('input', show);
    n.addEventListener('change', load);
    main.appendChild(el('section', { class: 'card' },
      el('div', { class: 'hd' }, el('h2', null, LOGS.find((l) => l[0] === cur)[1]), filt, n,
        el('label', { class: 'switch small' }, auto, el('span', { class: 'knob' }), 'авто'),
        el('button', { class: 'btn sm icon', 'aria-label': 'Обновить', onclick: load }, icon('refresh', 'sm'))), box));
    load().then(() => { box.scrollTop = box.scrollHeight; }).catch(err);
    every(5000, async () => { if (auto.checked) await load(); }, false);
  };
  async function eventsPage(main) {
    const stats = el('div', { class: 'grid g-kpi' });
    const list = el('div');
    const types = el('select', { class: 'input' }, el('option', { value: '' }, 'все типы'), Object.entries(EVT).map(([k, v]) => el('option', { value: k }, v[2])));
    types.style.width = 'auto'; types.style.height = '30px';
    const q = el('input', { class: 'input', placeholder: 'поиск', spellcheck: 'false' });
    q.style.height = '30px'; q.style.maxWidth = '220px';
    let evs = [];
    const show = () => {
      const f = q.value.trim().toLowerCase();
      const xs = evs.filter((e) => (!types.value || e.type === types.value) && (!f || e.text.toLowerCase().includes(f)));
      replace(list, xs.length ? xs.slice(0, 500).map(evRow) : el('div', { class: 'empty' }, 'Нет событий'));
    };
    types.addEventListener('change', show);
    q.addEventListener('input', show);
    add(main, [stats, el('div', { class: 'spacer' }),
      el('section', { class: 'card' }, el('div', { class: 'hd' }, el('h2', null, 'События сторожа'), q, types), list)]);
    const st = (lbl, v, sub) => el('div', { class: 'card kpi' }, el('div', { class: 'lbl' }, lbl), el('div', { class: 'val' }, v), el('div', { class: 'sub' }, sub));
    const load = async () => {
      const r = await api('/api/events?n=3000');
      evs = r.events;
      replace(stats,
        st('На основном · 7 дн', r.stats7.on_main_pct + '%', 'вне основного ' + fmtDur(r.stats7.off_main_sec)),
        st('На основном · 30 дн', r.stats30.on_main_pct + '%', 'вне основного ' + fmtDur(r.stats30.off_main_sec)),
        st('Переключений · 7 дн', r.stats7.switch, 'по качеству: ' + r.stats7.degrade + ', вручную: ' + r.stats7.force),
        st('Оба канала лежали · 7 дн', r.stats7.both, 'запусков сторожа: ' + r.stats7.start));
      show();
    };
    every(10000, load);
  }

  // ===================================================================== НАСТРОЙКИ
  const SET_TABS = [['failover', 'Переключение'], ['services', 'Службы'], ['telegram', 'Telegram'], ['users', 'Пользователи и 2FA'], ['web', 'Панель и сертификат'], ['backups', 'Резервные копии'], ['system', 'Система и обновление']];
  PAGES.settings = function (main, sub) {
    const cur = SET_TABS.some((t) => t[0] === sub) ? sub : 'failover';
    add(main, [head('Настройки'), tabs(SET_TABS, cur, (id) => { location.hash = '#/settings/' + id; })]);
    const body = el('div', { class: 'stack' });
    main.appendChild(body);
    ({ failover: setFailover, services: setServices, telegram: setTelegram, users: setUsers, web: setWeb, backups: setBackups, system: setSystem })[cur](body);
  };
  async function setFailover(body) {
    try {
      const d = await settings(true);
      add(body, [
        settingsForm('Переключение каналов', 'switch', ['RECOVER_SEC', 'QUALITY', 'QUALITY_LOSS', 'QUALITY_RTT', 'MIN_DWELL'], d,
          el('div', { class: 'alert info' }, icon('info'), el('div', null, 'Сторож проверяет каналы каждые несколько секунд (HTTPS к 1.1.1.1, 8.8.8.8, 9.9.9.9). При падении активного — уходит на следующий по приоритету; на основной возвращается после стабильной работы.'))),
        settingsForm('Мониторинг', 'activity', ['METRICS_PORT'], d)]);
    } catch (e) { err(e); }
  }
  async function setServices(body) {
    const tb = el('tbody');
    const load = async () => {
      const r = await api('/api/services');
      replace(tb, Object.entries(r.services).map(([u, s]) => {
        const act = (a, label, cls) => el('button', { class: 'btn sm ' + (cls || ''), onclick: async (e) => {
          if (a === 'disable' && !await confirmBox('Выключить ' + u + '?', 'Служба будет остановлена и убрана из автозапуска, её правила — удалены.', 'Выключить', true)) return;
          await busy(e.currentTarget, async () => { try { const x = await api('/api/service', { name: u, action: a }); (x.ok ? ok : err)(x.msg); load(); } catch (ex) { err(ex); } });
        } }, label);
        return el('tr', null,
          el('td', null, el('span', { class: 'row' }, el('span', { class: 'dot ' + (s.active ? 'ok' : s.installed ? 'crit' : '') }), el('b', null, u))),
          el('td', { class: 'muted' }, s.info),
          el('td', null, s.active ? el('span', { class: 'badge ok' }, 'работает') : s.installed ? el('span', { class: 'badge crit' }, 'стоит') : el('span', { class: 'badge' }, 'выключена')),
          el('td', { class: 'r nowrap' }, s.installed ? [act('restart', 'Перезапуск'), ' ', u !== 'awg-failover' ? act('disable', 'Выключить', 'danger') : null] : (s.available ? act('enable', 'Включить', 'primary') : el('span', { class: 'muted small' }, 'нет файла службы'))));
      }));
    };
    body.appendChild(card('Службы набора', el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, 'Служба'), el('th', null, 'Назначение'), el('th', null, 'Состояние'), el('th', { class: 'r' }, ''))), tb)),
      { icon: 'cpu', flush: true, right: el('a', { class: 'btn sm', href: '#/logs/journal' }, 'Журнал') }));
    every(10000, load);
  }
  async function setTelegram(body) {
    let r;
    try { r = await api('/api/telegram'); } catch (e) { err(e); return; }
    const tok = el('input', { class: 'input mono', placeholder: r.configured ? r.token + ' (оставьте пустым, чтобы не менять)' : '123456789:AA…', autocomplete: 'off', spellcheck: 'false' });
    const chat = el('input', { class: 'input mono', value: r.chat, placeholder: 'например 123456789', inputmode: 'numeric' });
    const rt = el('input', { class: 'input mono', value: r.report_time.replace(/^(\d\d)(\d\d)$/, '$1:$2'), placeholder: '09:00' });
    const nw = el('input', { type: 'checkbox', checked: r.no_wan });
    const en = el('input', { type: 'checkbox', checked: r.notify || !r.configured });
    const bot = el('input', { type: 'checkbox', checked: r.bot });
    const res = el('div', { class: 'res hidden' });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Сохранить');
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/telegram', { token: tok.value.trim(), chat: chat.value.trim(), report_time: rt.value.trim(), no_wan: nw.checked, enable_notify: en.checked, enable_bot: bot.checked });
        res.textContent = x.msg; res.classList.remove('hidden'); ok('Сохранено'); tok.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('tg', 'sm'), 'Тестовое сообщение');
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/telegram/test', {}); (x.ok ? ok : err)(x.msg); } catch (e) { err(e); } }));
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    body.appendChild(card('Telegram', el('div', null,
      el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.configured ? 'ok' : '') }, r.configured ? 'настроен' : 'не настроен'),
        el('span', { class: 'badge ' + (r.notify ? 'ok' : '') }, 'уведомления: ' + (r.notify ? 'работают' : 'выкл')),
        el('span', { class: 'badge ' + (r.bot ? 'ok' : '') }, 'бот: ' + (r.bot ? 'работает' : 'выкл'))),
      el('div', { class: 'spacer' }),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, 'Токен бота'), tok, el('span', { class: 'hint' }, 'От @BotFather. В панели не показывается целиком.')),
        el('div', { class: 'field' }, el('label', null, 'Chat ID'), chat, el('span', { class: 'hint' }, 'Ваш id: напишите боту @userinfobot.')),
        el('div', { class: 'field' }, el('label', null, 'Ежедневный отчёт'), rt, el('span', { class: 'hint' }, 'Время ЧЧ:ММ'))),
      sw(en, 'Уведомления', 'Переключения каналов, падения, возвраты, ежедневный отчёт.'),
      sw(bot, 'Команды бота', '/status, /switch, /auto, /events — управление из Telegram (только ваш chat id).'),
      sw(nw, 'Не слать напрямую через WAN', 'Если туннели лежат, уведомления не пойдут мимо VPN (тише, но можно не узнать о сбое).'),
      res), { icon: 'tg', foot: [test, save] }));
  }
  async function setUsers(body) {
    let r;
    try { r = await api('/api/users'); } catch (e) { err(e); return; }
    const me = r.users.find((u) => u.me) || { name: S.user, totp: false };
    const list = el('tbody', null, r.users.map((u) => el('tr', null,
      el('td', null, el('b', null, u.name), u.me ? el('span', { class: 'badge accent' }, 'вы') : null),
      el('td', null, u.totp ? el('span', { class: 'badge ok' }, '2FA') : el('span', { class: 'badge' }, 'без 2FA')),
      el('td', { class: 'r' }, u.me ? null : el('button', { class: 'btn sm danger', onclick: async () => {
        const pw = await promptPw('Удалить ' + u.name + '?', 'Пользователь будет удалён, его сеансы закрыты.');
        if (pw == null) return;
        try { await api('/api/user/delete', { user: u.name, current: pw }); ok('Удалён'); location.reload(); } catch (e) { err(e); }
      } }, 'Удалить')))));
    const un = el('input', { class: 'input', value: S.user, autocapitalize: 'off', spellcheck: 'false', autocomplete: 'username' });
    const p1 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const p2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const cur = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Сохранить');
    save.addEventListener('click', () => busy(save, async () => {
      if (p1.value !== p2.value) { err('пароли не совпадают'); return; }
      try { const x = await api('/api/passwd', { user: un.value.trim(), password: p1.value, current: cur.value }); ok(x.msg); p1.value = p2.value = cur.value = ''; setTimeout(() => location.reload(), 800); } catch (e) { err(e); }
    }));
    const tf = el('div');
    const totpView = () => {
      if (me.totp) {
        const off = el('button', { class: 'btn danger' }, 'Выключить 2FA');
        off.addEventListener('click', async () => {
          const pw = await promptPw('Выключить 2FA?', 'Вход будет только по паролю.');
          if (pw == null) return;
          try { await api('/api/totp/disable', { current: pw }); me.totp = false; ok('2FA выключена'); totpView(); } catch (e) { err(e); }
        });
        replace(tf, el('div', { class: 'alert ok' }, icon('okc'), el('div', null, 'Второй фактор включён: при входе нужен код из приложения.')), el('div', { class: 'spacer' }), off);
      } else {
        const on = el('button', { class: 'btn primary' }, icon('key', 'sm'), 'Включить 2FA');
        on.addEventListener('click', async () => {
          let b;
          try { b = await api('/api/totp/begin', {}); } catch (e) { err(e); return; }
          const code = el('input', { class: 'input mono', inputmode: 'numeric', maxlength: 6, placeholder: '000000', autocomplete: 'one-time-code' });
          let qr = null;
          try { qr = qrSvg(b.uri); } catch (e) { qr = null; }
          const go = async () => {
            try { await api('/api/totp/enable', { secret: b.secret, code: code.value }); me.totp = true; m.close(); ok('2FA включена'); totpView(); } catch (e) { err(e); }
          };
          code.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
          const m = modal('Включить 2FA', el('div', null,
            el('p', null, 'Отсканируйте код в Google Authenticator, Aegis, 1Password или другом приложении TOTP, затем введите 6 цифр.'),
            qr, el('div', { class: 'secret-box' }, b.secret.replace(/(.{4})/g, '$1 ').trim()),
            el('div', { class: 'small muted' }, 'Если камеры нет — введите ключ вручную (тип: по времени, 6 цифр, 30 с).'),
            el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, 'Код из приложения'), code),
            el('div', { class: 'small muted' }, 'Потеряли телефон — на роутере: ', el('code', null, 'python3 /data/awg/web/panel.py totp-off ' + S.user))),
          [el('button', { class: 'btn', onclick: () => m.close() }, 'Отмена'), el('button', { class: 'btn primary', onclick: go }, 'Включить')], { sticky: true });
          setTimeout(() => code.focus(), 50);
        });
        replace(tf, el('p', { class: 'muted' }, 'Код из приложения на телефоне в дополнение к паролю. Рекомендуется, если панель открывают несколько человек или в LAN есть гостевые устройства.'), on);
      }
    };
    totpView();
    add(body, [
      el('div', { class: 'grid g-2e' },
        card('Пользователи', el('table', { class: 'tbl' }, list), { icon: 'users', flush: true }),
        card('Двухфакторная защита (' + S.user + ')', tf, { icon: 'key' })),
      card('Пароль: сменить свой или добавить пользователя', el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, 'Имя пользователя'), un, el('span', { class: 'hint' }, 'Новое имя — новый пользователь')),
        el('div', { class: 'field' }, el('label', null, 'Новый пароль'), p1, el('span', { class: 'hint' }, 'Не короче 10 символов')),
        el('div', { class: 'field' }, el('label', null, 'Повторите'), p2),
        el('div', { class: 'field' }, el('label', null, 'Ваш текущий пароль'), cur)), { icon: 'lock', foot: save }),
      await sessionsCard()]);
  }
  async function setBackups(body) {
    const tb = el('tbody');
    const load = async () => {
      const r = await api('/api/backups');
      replace(tb, r.backups.length ? r.backups.map((b) => el('tr', null,
        el('td', null, el('span', { class: 'mono' }, b.name)),
        el('td', null, fmtTime(b.time, true)),
        el('td', null, fmtBytes(b.size)),
        el('td', null, b.enc ? el('span', { class: 'badge ok' }, 'зашифрована') : el('span', { class: 'badge warn' }, 'без пароля')),
        el('td', { class: 'r nowrap' }, el('button', { class: 'btn sm', onclick: () => {
          const pw = el('input', { class: 'input', type: 'password', autocomplete: 'off' });
          const out = el('div', { class: 'res hidden' });
          const go = el('button', { class: 'btn primary' }, 'Проверить');
          go.addEventListener('click', () => busy(go, async () => { try { const x = await api('/api/backup/verify', { name: b.name, password: pw.value }); out.textContent = x.msg; out.classList.remove('hidden'); (x.ok ? ok : err)(x.ok ? 'Копия читается' : 'Копия не прошла проверку'); } catch (e) { err(e); } }));
          const vm = modal('Проверить ' + b.name, el('div', null, el('p', { class: 'muted small' }, 'Копия расшифровывается во временный файл и проверяется целостность архива; на роутере ничего не меняется.'),
            b.enc ? el('div', { class: 'field' }, el('label', null, 'Пароль копии'), pw) : null, out), [el('button', { class: 'btn', onclick: () => vm.close() }, 'Закрыть'), go]);
        } }, icon('okc', 'sm'), 'Проверить'), ' ',
          el('a', { class: 'btn sm', href: '/api/backup/file?name=' + encodeURIComponent(b.name), download: b.name }, icon('download', 'sm'), 'Скачать'), ' ',
          el('button', { class: 'btn sm danger icon', 'aria-label': 'Удалить', onclick: async () => {
            if (!await confirmBox('Удалить копию?', b.name, 'Удалить', true)) return;
            try { await api('/api/backup/delete', { name: b.name }); load(); } catch (e) { err(e); }
          } }, icon('trash', 'sm'))))) : el('tr', null, el('td', { class: 'empty', colspan: 5 }, 'Копий пока нет')));
    };
    const p1 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const p2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const mk = el('button', { class: 'btn primary' }, icon('archive', 'sm'), 'Создать копию');
    const res = el('div', { class: 'res hidden' });
    mk.addEventListener('click', () => busy(mk, async () => {
      if (p1.value !== p2.value) { err('пароли не совпадают'); return; }
      try { const x = await api('/api/backup/create', { password: p1.value }); res.textContent = x.msg; res.classList.remove('hidden'); (x.ok ? ok : err)(x.ok ? 'Копия создана' : 'Ошибка'); p1.value = p2.value = ''; load(); } catch (e) { err(e); }
    }));
    add(body, [
      card('Новая копия', el('div', null, el('p', { class: 'muted' }, 'В копию входят конфиги туннелей с ключами, awg.env, Telegram и пользователи панели. Она шифруется паролем — храните его отдельно. Восстановление: install.sh → Резервная копия.'),
        el('div', { class: 'form-grid' }, el('div', { class: 'field' }, el('label', null, 'Пароль копии'), p1), el('div', { class: 'field' }, el('label', null, 'Повторите'), p2)), res), { icon: 'archive', foot: mk }),
      card('Копии на роутере', el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, 'Файл'), el('th', null, 'Создана'), el('th', null, 'Размер'), el('th', null, ''), el('th', null, ''))), tb)), { icon: 'archive', flush: true })]);
    load().catch(err);
  }
  async function setSystem(body) {
    let r;
    try { r = await api('/api/system'); } catch (e) { err(e); return; }
    const upd = el('div');
    const log = el('pre', { class: 'console hidden' });
    const chk = el('button', { class: 'btn' }, icon('refresh', 'sm'), 'Проверить обновления');
    async function followUpdate() {
      log.classList.remove('hidden');
      let lost = 0;
      for (let i = 0; i < 600; i++) {
        await new Promise((ok2) => setTimeout(ok2, 2000));
        try {
          const x = await api('/api/update/log');
          paint(log, x.text); log.scrollTop = log.scrollHeight;
          if (lost) { lost = 0; toast('Панель снова на связи'); }
          if (!x.running && i > 2) {
            const good = /\[код 0\]/.test(x.text);
            replace(upd, el('div', { class: 'alert ' + (good ? 'ok' : 'crit') }, icon(good ? 'okc' : 'alert'), el('div', null,
              good ? 'Обновление завершено: версия ' + x.version + '. Страница перезагрузится.' : 'Обновление завершилось с ошибкой (при сбое выполнен откат). Журнал — ниже и в «Журналах → Обновление».')));
            if (good) setTimeout(() => location.reload(), 4000);
            return;
          }
        } catch (e) {
          lost++;
          if (lost === 1) replace(upd, el('div', { class: 'alert info' }, el('span', { class: 'spinner sm' }), el('div', null, 'Панель перезапускается после обновления — жду, когда она вернётся…')));
        }
      }
    }
    chk.addEventListener('click', () => busy(chk, async () => {
      try {
        const u = await api('/api/update/check', {});
        if (u.running) { replace(upd, el('div', { class: 'alert info' }, icon('info'), el('div', null, 'Обновление уже идёт.'))); followUpdate(); return; }
        const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), 'Обновить до ' + u.latest);
        go.addEventListener('click', async () => {
          if (!await confirmBox('Обновить до ' + u.latest + '?', 'Перед обновлением делается копия скриптов. Службы перезапустятся (несколько секунд без трафика PBR). Если после обновления сторож, маршрут или панель не заработают — автоматически вернётся прежняя версия.', 'Обновить')) return;
          try { ok((await api('/api/update/run', {})).msg); go.disabled = true; followUpdate(); } catch (e) { err(e); }
        });
        replace(upd, u.latest ? (u.update ? el('div', null, el('div', { class: 'alert info' }, icon('download'), el('div', null, 'Доступна версия ', el('b', null, u.latest), ' (у вас ' + u.current + ', ветка ' + u.branch + ').')),
          u.notes ? el('details', { class: 'fgroup' }, el('summary', null, 'Что нового'), el('pre', { class: 'res' }, u.notes)) : null,
          el('div', { class: 'spacer' }), go, el('div', { class: 'small muted' }, 'Или по SSH: ', el('code', null, u.cmd)))
          : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, 'Установлена последняя версия ' + u.current + ' (ветка ' + u.branch + ').')))
          : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, 'Не удалось узнать последнюю версию в ' + u.repo + ' (GitHub недоступен с роутера?)')));
      } catch (e) { err(e); }
    }));
    const kv = (rows) => el('dl', { class: 'kv' }, rows.map(([k, v]) => [el('dt', null, k), el('dd', null, v)]));
    const exp = el('button', { class: 'btn' }, icon('download', 'sm'), 'Экспорт настроек');
    exp.addEventListener('click', async () => {
      try {
        const x = await api('/api/settings/export');
        const a = el('a', { href: URL.createObjectURL(new Blob([JSON.stringify(x, null, 1)], { type: 'application/json' })), download: 'udr-amnezia-settings.json' });
        document.body.appendChild(a); a.click(); a.remove();
      } catch (e) { err(e); }
    });
    const imp = el('button', { class: 'btn' }, icon('upload', 'sm'), 'Импорт настроек');
    imp.addEventListener('click', () => {
      const m = modal('Импорт настроек', el('div', null, el('p', { class: 'muted small' }, 'Файл udr-amnezia-settings.json с другого роутера или сохранённый ранее: домены, исключения, защита, параметры переключения, названия туннелей. Ключей и паролей в нём нет.'),
        dropZone(async (txt) => {
          let data;
          try { data = JSON.parse(txt); } catch (e) { err('это не JSON'); return; }
          try { const x = await api('/api/settings/import', { data }); ok(x.msg.split('\n')[0]); m.close(); } catch (e) { err(e); }
        }, 'udr-amnezia-settings.json')), []);
    });
    add(body, [
      el('div', { class: 'grid g-2e' },
        card('Версии и обновление', el('div', null, kv([['Набор', r.version || '?'], ['Установщик', r.installer], ['Панель', r.panel], ['awg', r.awg], ['amneziawg-go', r.amneziawg_go], ['Python', r.python], ['Свободно в /data', r.data_free_mb + ' МБ']]),
          el('div', { class: 'spacer' }), upd, log), { icon: 'info', foot: chk }),
        card('Перенос настроек', el('div', null, el('p', { class: 'muted small' }, 'Настройки без секретов в файл JSON: перенести на другой роутер или сохранить перед экспериментами. Конфиги туннелей переносятся отдельно (Туннели → Настроить → Экспорт) или резервной копией.')),
          { icon: 'archive', foot: [exp, imp] }))]);
  }
  async function setWeb(body) {
    let r;
    try { r = await api('/api/web'); } catch (e) { err(e); return; }
    const port = el('input', { class: 'input mono', value: r.port, inputmode: 'numeric' });
    const allow = el('input', { class: 'input mono', value: r.allow });
    const hosts = el('input', { class: 'input mono', value: r.hosts, placeholder: 'udr.example.com' });
    const cm = el('select', { class: 'input' }, [['auto', 'Автоматически: сертификат UniFi, если он настоящий, иначе свой'], ['unifi', 'Сертификат UniFi (как у веб-интерфейса роутера)'], ['self', 'Свой самоподписанный']]
      .map(([v, t]) => el('option', { value: v, selected: r.cert_mode === v }, t)));
    const ci = r.cert || {};
    const certKv = el('dl', { class: 'kv' },
      el('dt', null, 'Используется'), el('dd', null, el('span', { class: 'badge ' + (r.cert_used === 'unifi' || r.cert_used === 'file' ? 'ok' : 'warn') }, { self: 'самоподписанный', unifi: 'сертификат UniFi', file: 'файл из web.conf' }[r.cert_used] || 'нет (HTTP)')),
      el('dt', null, 'Имя'), el('dd', null, ci.subject || '—'),
      el('dt', null, 'Издатель'), el('dd', null, ci.issuer || '—'),
      el('dt', null, 'Действует до'), el('dd', null, ci.expires ? fmtTime(ci.expires, true) + (ci.expires - Date.now() / 1000 < 14 * 86400 ? ' ⚠' : '') : '—'),
      el('dt', null, 'Имена в сертификате'), el('dd', null, (ci.names || []).join(', ') || '—'));
    const found = r.unifi_certs.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, 'Найден сертификат UniFi'), el('th', null, 'Издатель'), el('th', null, 'До'))),
      el('tbody', null, r.unifi_certs.map((c) => el('tr', null, el('td', null, el('b', null, c.subject || '?'), el('div', { class: 'small muted mono' }, c.path)), el('td', null, c.issuer || '—', c.self_signed ? el('span', { class: 'badge warn' }, 'самоподписанный') : null), el('td', { class: 'nowrap' }, c.expires ? fmtTime(c.expires, true) : '—')))))
      : el('div', { class: 'small muted' }, 'Сертификатов UniFi не найдено в /data/unifi-core/config.');
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), 'Сохранить и перезапустить панель');
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/web', { port: port.value.trim(), allow: allow.value.trim(), hosts: hosts.value.trim(), cert_mode: cm.value });
        ok(x.msg);
        setTimeout(() => { location.href = x.url; }, 5000);
      } catch (e) { err(e); }
    }));
    add(body, [
      el('div', { class: 'grid g-2e' },
        card('Доступ', el('div', null,
          el('div', { class: 'field' }, el('label', null, 'Порт'), port, el('span', { class: 'hint' }, 'Сейчас панель на ' + r.lan + ':' + r.port + '. Порты UniFi (443, 8443, 8080…) заняты.')),
          el('div', { class: 'field' }, el('label', null, 'Разрешённые сети'), allow, el('span', { class: 'hint' }, 'Только частные сети через пробел. Для доступа извне используйте VPN-сервер роутера.')),
          el('div', { class: 'field' }, el('label', null, 'Имена для входа (кроме IP)'), hosts, el('span', { class: 'hint' }, 'Имена из сертификата добавляются сами.'))), { icon: 'lock' }),
        card('Сертификат HTTPS', el('div', null,
          el('div', { class: 'field' }, el('label', null, 'Источник'), cm, el('span', { class: 'hint' }, 'Сертификат UniFi обновляется роутером; панель перечитывает его сама в течение минуты, перезапуск не нужен.')),
          r.cert_warn ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, r.cert_warn)) : null,
          certKv, el('div', { class: 'spacer' }), found), { icon: 'shield' })),
      el('div', { class: 'row end' }, save)]);
  }
  async function sessionsCard() {
    const tb = el('tbody');
    const load = async () => {
      const r = await api('/api/sessions');
      replace(tb, r.sessions.map((x) => el('tr', null,
        el('td', null, el('b', null, x.user), x.me ? el('span', { class: 'badge accent' }, 'этот') : null, el('div', { class: 'small muted' }, (x.ua || '').replace(/\(.*?\)/g, '').slice(0, 60))),
        el('td', null, el('span', { class: 'mono' }, x.ip)),
        el('td', { class: 'nowrap' }, 'вход ' + fmtTime(x.born), el('div', { class: 'small muted' }, 'активность ' + fmtAge(Math.floor(Date.now() / 1000) - x.seen))),
        el('td', { class: 'r' }, x.me ? null : el('button', { class: 'btn sm danger', onclick: async () => { try { await api('/api/session/revoke', { id: x.id }); load(); } catch (e) { err(e); } } }, 'Завершить')))));
    };
    load().catch(err);
    const all = el('button', { class: 'btn sm', onclick: async () => { try { await api('/api/session/revoke', { id: 'others' }); ok('Остальные сеансы завершены'); load(); } catch (e) { err(e); } } }, 'Завершить остальные');
    return card('Активные сеансы', el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb)), { icon: 'key', flush: true, right: all });
  }

  // ===================================================================== QR-код (байтовый режим, уровень M, версии 1–10)
  function qrMatrix(text) {
    const data = Array.from(new TextEncoder().encode(text));
    const ECC = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26], BLK = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
    const rawMods = (v) => { let r = (16 * v + 128) * v + 64; if (v >= 2) { const n = Math.floor(v / 7) + 2; r -= (25 * n - 10) * n - 55; if (v >= 7) r -= 36; } return r; };
    let ver = 1, cap = 0;
    for (; ver <= 10; ver++) { cap = Math.floor(rawMods(ver) / 8) - ECC[ver] * BLK[ver]; if (4 + (ver < 10 ? 8 : 16) + data.length * 8 <= cap * 8) break; }
    if (ver > 10) throw new Error('слишком длинно для QR');
    const bits = [];
    const push = (v, n) => { for (let i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1); };
    push(4, 4); push(data.length, ver < 10 ? 8 : 16); data.forEach((b) => push(b, 8));
    push(0, Math.min(4, cap * 8 - bits.length)); push(0, (8 - bits.length % 8) % 8);
    for (let p = 0xEC; bits.length < cap * 8; p ^= 0xEC ^ 0x11) push(p, 8);
    const cw = [];
    for (let i = 0; i < bits.length; i += 8) { let b = 0; for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j]; cw.push(b); }
    // Рида — Соломона
    const mul = (x, y) => { let z = 0; for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11D); z ^= ((y >>> i) & 1) * x; } return z & 0xFF; };
    const deg = ECC[ver], div = new Array(deg).fill(0);
    div[deg - 1] = 1;
    for (let i = 0, root = 1; i < deg; i++) { for (let j = 0; j < deg; j++) { div[j] = mul(div[j], root); if (j + 1 < deg) div[j] ^= div[j + 1]; } root = mul(root, 2); }
    const rem = (d) => { const r = new Array(deg).fill(0); for (const b of d) { const f = b ^ r.shift(); r.push(0); div.forEach((c, i) => { r[i] ^= mul(c, f); }); } return r; };
    const nb = BLK[ver], raw = Math.floor(rawMods(ver) / 8), nShort = nb - raw % nb, shortLen = Math.floor(raw / nb);
    const blocks = [];
    for (let i = 0, k = 0; i < nb; i++) {
      const d = cw.slice(k, k + shortLen - deg + (i < nShort ? 0 : 1));
      k += d.length;
      const e = rem(d);
      if (i < nShort) d.push(0);
      blocks.push(d.concat(e));
    }
    const all = [];
    for (let i = 0; i < blocks[0].length; i++) blocks.forEach((b, j) => { if (i !== shortLen - deg || j >= nShort) all.push(b[i]); });
    // матрица
    const N = ver * 4 + 17;
    const M = [], F = [];
    for (let y = 0; y < N; y++) { M.push(new Array(N).fill(false)); F.push(new Array(N).fill(false)); }
    const setF = (x, y, d) => { M[y][x] = d; F[y][x] = true; };
    for (let i = 0; i < N; i++) { setF(6, i, i % 2 === 0); setF(i, 6, i % 2 === 0); }
    const finder = (x, y) => { for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) { const d = Math.max(Math.abs(dx), Math.abs(dy)), xx = x + dx, yy = y + dy; if (xx >= 0 && xx < N && yy >= 0 && yy < N) setF(xx, yy, d !== 2 && d !== 4); } };
    finder(3, 3); finder(N - 4, 3); finder(3, N - 4);
    if (ver > 1) {
      const na = Math.floor(ver / 7) + 2, step = Math.ceil((ver * 4 + 4) / (na * 2 - 2)) * 2;
      const pos = [6];
      for (let p = N - 7; pos.length < na; p -= step) pos.splice(1, 0, p);
      for (let i = 0; i < na; i++) for (let j = 0; j < na; j++) {
        if ((i === 0 && j === 0) || (i === 0 && j === na - 1) || (i === na - 1 && j === 0)) continue;
        for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) setF(pos[i] + dx, pos[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
      }
    }
    const fmt = (mask) => {
      const d = (0 << 3) | mask;
      let r = d;
      for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537);
      const b = ((d << 10) | r) ^ 0x5412, g = (i) => ((b >>> i) & 1) !== 0;
      for (let i = 0; i <= 5; i++) setF(8, i, g(i));
      setF(8, 7, g(6)); setF(8, 8, g(7)); setF(7, 8, g(8));
      for (let i = 9; i < 15; i++) setF(14 - i, 8, g(i));
      for (let i = 0; i < 8; i++) setF(N - 1 - i, 8, g(i));
      for (let i = 8; i < 15; i++) setF(8, N - 15 + i, g(i));
      setF(8, N - 8, true);
    };
    fmt(0);
    if (ver >= 7) {
      let r = ver;
      for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1F25);
      const b = (ver << 12) | r;
      for (let i = 0; i < 18; i++) { const bit = ((b >>> i) & 1) !== 0, a = N - 11 + i % 3, c = Math.floor(i / 3); setF(a, c, bit); setF(c, a, bit); }
    }
    let i = 0;
    for (let right = N - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let v = 0; v < N; v++) for (let j = 0; j < 2; j++) {
        const x = right - j, up = ((right + 1) & 2) === 0, y = up ? N - 1 - v : v;
        if (!F[y][x] && i < all.length * 8) { M[y][x] = ((all[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0; i++; }
      }
    }
    const MASKS = [(x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
      (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => x * y % 2 + x * y % 3 === 0,
      (x, y) => (x * y % 2 + x * y % 3) % 2 === 0, (x, y) => ((x + y) % 2 + x * y % 3) % 2 === 0];
    const apply = (m) => { for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (!F[y][x] && MASKS[m](x, y)) M[y][x] = !M[y][x]; };
    const penalty = () => {
      let p = 0, dark = 0;
      for (let a = 0; a < N; a++) {
        for (const line of [(k) => M[a][k], (k) => M[k][a]]) {
          let run = 1;
          for (let k = 1; k < N; k++) { if (line(k) === line(k - 1)) { run++; if (run === 5) p += 3; else if (run > 5) p++; } else run = 1; }
          for (let k = 0; k + 10 < N; k++) {
            const s = []; for (let q = 0; q < 11; q++) s.push(line(k + q) ? 1 : 0);
            const t = s.join('');
            if (t === '10111010000' || t === '00001011101') p += 40;
          }
        }
      }
      for (let y = 0; y < N - 1; y++) for (let x = 0; x < N - 1; x++) { const c = M[y][x]; if (c === M[y][x + 1] && c === M[y + 1][x] && c === M[y + 1][x + 1]) p += 3; }
      for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (M[y][x]) dark++;
      p += Math.floor(Math.abs(dark * 20 - N * N * 10) / (N * N)) * 10;
      return p;
    };
    let best = 0, bestP = Infinity;
    for (let m = 0; m < 8; m++) { apply(m); fmt(m); const p = penalty(); if (p < bestP) { bestP = p; best = m; } apply(m); }
    apply(best); fmt(best);
    return M;
  }
  function qrSvg(text) {
    const M = qrMatrix(text), N = M.length, q = 4;
    let d = '';
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (M[y][x]) d += 'M' + (x + q) + ' ' + (y + q) + 'h1v1h-1z';
    return sv('svg', { class: 'qr', viewBox: '0 0 ' + (N + 2 * q) + ' ' + (N + 2 * q), 'shape-rendering': 'crispEdges', role: 'img', 'aria-label': 'QR-код для приложения' },
      sv('rect', { width: N + 2 * q, height: N + 2 * q, fill: '#fff' }), sv('path', { d, fill: '#000' }));
  }
  window.__awgQR = qrMatrix;  // для автотестов

  // ===================================================================== запуск
  function start() {
    shell();
    if (!location.hash || location.hash === '#' || location.hash === '#/') location.hash = '#/overview';
    route();
  }
  (async function boot() {
    try {
      const r = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' });
      const j = await r.json();
      if (r.ok) { S.csrf = j.csrf; S.user = j.user; S.version = j.version; start(); } else showLogin(j.setup);
    } catch (e) {
      replace($('#app'), el('div', { class: 'login-wrap' }, el('div', { class: 'login' }, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, 'Панель не отвечает: ' + e.message)))));
    }
  }());
}());
