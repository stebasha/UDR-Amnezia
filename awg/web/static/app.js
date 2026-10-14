/* UDR-Amnezia — веб-панель. Без внешних библиотек; совместимо с CSP (без inline-скриптов и стилей).
   Файл собран из awg/web/src/*.js командой python3 tools/build-app.py: правьте части там, не этот файл. */
'use strict';
(function () {
  // ===================================================================== язык (ru по умолчанию, en — словарь lang-en.js)
  const LANG = (() => { try { return localStorage.getItem('awg-lang') || 'ru'; } catch (e) { return 'ru'; } })();
  const DICT = LANG === 'en' && window.AWG_EN ? window.AWG_EN : null;
  function T(s) { return DICT && typeof s === 'string' && DICT.s[s] !== undefined ? DICT.s[s] : s; }
  function TM(s) {   // текст с сервера или из скриптов: точное совпадение или шаблон
    if (!DICT || typeof s !== 'string') return s;
    if (DICT.s[s] !== undefined) return DICT.s[s];
    for (const [re, to] of DICT.re) if (re.test(s)) return s.replace(re, to);
    return s;
  }
  function setLang(l) { try { localStorage.setItem('awg-lang', l); } catch (e) { /* без хранилища — до перезагрузки */ } location.reload(); }
  document.documentElement.lang = LANG;
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
    home: 'M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8|M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
    tunnel: 'M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z|M9 12l2 2 4-4',
    route: 'M6 22a3 3 0 1 0 0-6 3 3 0 0 0 0 6z|M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15|M18 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
    tools: 'M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z',
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
    router: 'M4 14h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2z|M6.01 18H6|M10.01 18H10|M15 10v4|M17.84 7.17a4 4 0 0 0-5.66 0|M20.66 4.34a8 8 0 0 0-11.31 0',
    server: 'M3 3h18v7H3z|M3 14h18v7H3z|M7 6.5h.01|M7 17.5h.01',
    laptop: 'M4 5h16v10H4z|M2 19h20',
    switch: 'M16 3h5v5|M4 20 21 3|M21 16v5h-5|M15 15l6 6|M4 4l5 5',
    download: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4|M7 10l5 5 5-5|M12 15V3',
    upload: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4|M17 8l-5-5-5 5|M12 3v12',
    key: 'M21 2l-2 2m-7.6 7.6a5.5 5.5 0 1 1-7.8 7.8 5.5 5.5 0 0 1 7.8-7.8zm0 0L15.5 7.5m0 0 3 3L22 7l-3-3m-3.5 3.5L19 4',
    users: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2|M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z|M22 21v-2a4 4 0 0 0-3-3.87|M16 3.13a4 4 0 0 1 0 7.75',
    bell: 'M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9|M13.7 21a2 2 0 0 1-3.4 0',
    archive: 'M21 8v13H3V8|M1 3h22v5H1z|M10 12h4',
    cpu: 'M12 20v2|M12 2v2|M17 20v2|M17 2v2|M2 12h2|M2 17h2|M2 7h2|M20 12h2|M20 17h2|M20 7h2|M7 20v2|M7 2v2|M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z|M9 8h6a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z',
    activity: 'M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2',
    clock: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z|M12 6v6l4 2',
    power: 'M18.4 6.6a9 9 0 1 1-12.8 0|M12 2v10',
    search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16z|M21 21l-4.3-4.3',
    stetho: 'M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2',
    wrench: 'M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z',
    file: 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z|M14 2v6h6|M8 13h8|M8 17h8',
    shield: 'M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z',
    layers: 'M12 2 2 7l10 5 10-5z|M2 17l10 5 10-5|M2 12l10 5 10-5',
    ruler: 'M21.3 8.7 15.3 2.7 2.7 15.3l6 6z|M7.5 10.5l2 2|M10.5 7.5l2 2|M13.5 4.5l2 2|M4.5 13.5l2 2',
    copy: 'M9 9h13v13H9z|M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1',
    tg: 'M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z|M21.854 2.147l-10.94 10.939',
    lock: 'M5 11h14v10H5z|M8 11V7a4 4 0 0 1 8 0v4',
    menu: 'M3 12h18|M3 6h18|M3 18h18',
    up: 'M12 19V5|M5 12l7-7 7 7',
    thermo: 'M14 4v10.54a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0z',
    disk: 'M22 12H2|M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z|M6 16h.01|M10 16h.01',
    gauge: 'M12 14l4-4|M3.34 19a10 10 0 1 1 17.32 0',
    mem: 'M6 19v-3|M10 19v-3|M14 19v-3|M18 19v-3|M8 11V9|M16 11V9|M12 11V9|M2 15h20|M2 7a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v1.1a2 2 0 0 0 0 3.84V17a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-5.06a2 2 0 0 0 0-3.84z',
    lang: 'M5 8l6 6|M4 14l6-6 2-3|M2 5h12|M7 2h1|M22 22l-5-10-5 10|M14 18h6',
    chev: 'M9 18l6-6-6-6',

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
    if (bps < 1000) return Math.round(bps) + T(' бит/с');
    if (bps < 1e6) return (bps / 1e3).toFixed(bps < 1e4 ? 1 : 0) + T(' Кбит/с');
    if (bps < 1e9) return (bps / 1e6).toFixed(bps < 1e7 ? 2 : 1) + T(' Мбит/с');
    return (bps / 1e9).toFixed(2) + T(' Гбит/с');
  }
  function fmtBytes(b) {
    b = +b || 0;
    const u = [T('Б'), T('КБ'), T('МБ'), T('ГБ'), T('ТБ')];
    let i = 0;
    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
    return (i ? b.toFixed(b < 10 ? 2 : b < 100 ? 1 : 0) : b) + ' ' + u[i];
  }
  function fmtAge(s) {
    s = +s;
    if (!(s >= 0)) return T('нет');
    if (s < 90) return s + T(' с назад');
    if (s < 5400) return Math.round(s / 60) + T(' мин назад');
    if (s < 172800) return Math.round(s / 3600) + T(' ч назад');
    return Math.round(s / 86400) + T(' дн назад');
  }
  function fmtDur(s) {
    s = Math.max(0, Math.floor(+s || 0));
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return d + T(' д ') + h + T(' ч');
    if (h) return h + T(' ч ') + m + T(' мин');
    if (m) return m + T(' мин');
    return s + T(' с');
  }
  function fmtTime(t, full) {
    const d = new Date(t * 1000), n = new Date();
    const hm = pad2(d.getHours()) + ':' + pad2(d.getMinutes());
    if (!full && d.toDateString() === n.toDateString()) return hm + ':' + pad2(d.getSeconds());
    return pad2(d.getDate()) + '.' + pad2(d.getMonth() + 1) + (d.getFullYear() !== n.getFullYear() ? '.' + d.getFullYear() : '') + ' ' + hm;
  }
  function fmtMB(mb) { mb = +mb; if (!(mb >= 0)) return '?'; return mb >= 1024 ? (mb / 1024).toFixed(1) + T(' ГБ') : mb + T(' МБ'); }
  function qText(t) {   // качество канала: RTT и потери; ICMP через туннель может не ходить — тогда меряется TCP
    if (t.rtt === '' && t.loss === '') return T('качество не измерялось');
    if (t.qm !== 'tcp' && t.loss === '100' && (t.rtt === '0' || t.rtt === '')) return T('ICMP не ходит · качество — после обновления сторожа');
    return 'RTT ' + (t.rtt !== '' ? t.rtt + T(' мс') : '—') + T(' · потери ') + (t.loss !== '' ? t.loss + '%' : '—') + (t.qm === 'tcp' ? ' (TCP)' : '');
  }
  function checkRow(c) {
    const ic = { ok: 'okc', warn: 'alert', crit: 'alert', info: 'info' }[c.level] || 'info';
    return el('div', { class: 'chk ' + c.level }, el('span', { class: 'ci' }, icon(ic, 'sm')),
      el('div', null, el('div', null, TM(c.text)), c.advice ? el('div', { class: 'adv' }, TM(c.advice)) : null));
  }
  function splitEndpoint(ep) {
    if (!ep) return ['', ''];
    const m = ep.match(/^\[?([^\]]+?)\]?:(\d+)$/);
    return m ? [m[1], m[2]] : [ep, ''];
  }

  // ===================================================================== состояние и API
  const S = { csrf: '', user: '', version: '', page: '', ov: null, live: {}, hist: null, timers: [], ticks: [], reveal: {}, histMode: 'live', chartTun: '' };
  const NAV = [
    ['overview', T('Обзор'), 'home'],
    ['tunnels', T('Туннели'), 'tunnel'],
    ['clients', T('Клиенты'), 'users'],
    ['system', T('Роутер'), 'router'],
    ['routing', T('Маршрутизация'), 'route'],
    ['tools', T('Инструменты'), 'tools'],
    ['logs', T('Журналы'), 'logs'],
    ['settings', T('Настройки'), 'settings'],
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
    try { j = await r.json(); } catch (e) { j = { error: T('неожиданный ответ (') + r.status + ')' }; }
    if (r.status === 401 && path !== '/api/login') { stopTimers(); showLogin(j && j.setup); const e401 = new ApiErr('нужен вход'); e401.auth = true; throw e401; }
    if (!r.ok) throw new ApiErr((j && j.error) || (T('ошибка ') + r.status));
    return j;
  }
  function every(ms, fn, now) {
    let busy = false;
    const tick = async () => {
      if (busy || document.hidden) return;
      busy = true;
      try { await fn(); } catch (e) { if (!(e instanceof ApiErr)) console.debug('poll', e); } finally { busy = false; }
    };
    S.timers.push(setInterval(tick, ms));
    S.ticks.push(tick);
    if (now !== false) tick();
  }
  function stopTimers() { S.timers.forEach(clearInterval); S.timers = []; S.ticks = []; }
  // в фоновой вкладке опрос стоит; вернулись на вкладку — обновить сразу, не дожидаясь интервала (до 60 с)
  document.addEventListener('visibilitychange', () => { if (!document.hidden) S.ticks.slice().forEach((t) => t()); });

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
    const t = el('div', { class: 'toast ' + (kind || '') }, el('div', null, TM(msg)),
      el('button', { class: 'x', 'aria-label': T('Закрыть'), onclick: () => t.remove() }, icon('x', 'sm')));
    toastBox.appendChild(t);
    setTimeout(() => t.remove(), ms || (kind === 'err' ? 9000 : 4500));
  }
  const ok = (m) => toast(m, 'ok');
  const err = (e) => toast(e && e.message ? e.message : String(e), 'err');

  function modal(title, body, buttons, opts) {
    opts = opts || {};
    const bg = el('div', { class: 'modal-bg' });
    const close = () => { bg.remove(); document.removeEventListener('keydown', esc); if (opts.onclose) opts.onclose(); };
    // Esc закрывает только верхнее окно (раньше закрывались все открытые разом — например, редактор вместе со сравнением)
    const esc = (e) => { if (e.key === 'Escape' && Array.from(document.querySelectorAll('.modal-bg')).pop() === bg) close(); };
    const ft = el('div', { class: 'ft' });
    const m = el('div', { class: 'modal' + (opts.wide ? ' wide' : ''), role: 'dialog', 'aria-modal': 'true' },
      el('div', { class: 'hd' }, el('h2', null, title), el('button', { class: 'btn ghost icon', 'aria-label': T('Закрыть'), onclick: close }, icon('x'))),
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
        el('button', { class: 'btn', onclick: () => { done = true; m.close(); res(false); } }, T('Отмена')),
        el('button', { class: 'btn ' + (danger ? 'danger' : 'primary'), onclick: () => { done = true; m.close(); res(true); } }, yes || T('Да')),
      ], { onclose: () => { if (!done) res(false); } });
    });
  }
  function promptPw(title, text) {
    return new Promise((res) => {
      let done = false;
      const inp = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = () => { done = true; m.close(); res(inp.value); };
      inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
      const m = modal(title, el('div', null, text ? el('p', null, text) : null, el('div', { class: 'field' }, el('label', null, T('Пароль от этой веб-панели (тот же, что при входе)')), inp)), [
        el('button', { class: 'btn', onclick: () => { done = true; m.close(); res(null); } }, T('Отмена')),
        el('button', { class: 'btn primary', onclick: go }, T('Подтвердить')),
      ], { onclose: () => { if (!done) res(null); } });
    });
  }
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
    const L = 64, R = 10, TP = 10, B = 24;
    let t0 = Infinity, t1 = -Infinity, ymax = 0;
    for (const s of series) for (const p of s.points) { t0 = Math.min(t0, p[0]); t1 = Math.max(t1, p[0]); ymax = Math.max(ymax, p[1]); }
    const muted = cssVar('--muted'), line = cssVar('--line2');
    c.font = '11px ' + cssVar('--font');
    if (!isFinite(t0) || t1 === t0) {
      c.fillStyle = muted; c.textAlign = 'center';
      c.fillText(opts.empty || T('Данные появятся через несколько секунд'), W / 2, H / 2);
      cv.onmousemove = null;
      return;
    }
    // «красивый» максимум оси Y
    const nice = (v) => { if (v <= 0) return 1000; const e = Math.pow(10, Math.floor(Math.log10(v))); const f = v / e; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * e; };
    ymax = opts.max ? Math.max(opts.max, ymax) : nice(ymax * 1.08);
    const F = opts.fmt || fmtBits;
    const X = (t) => L + (t - t0) / (t1 - t0) * (W - L - R);
    const Y = (v) => TP + (1 - v / ymax) * (H - TP - B);
    c.strokeStyle = line; c.lineWidth = 1; c.fillStyle = muted; c.textAlign = 'right'; c.textBaseline = 'middle';
    for (let i = 0; i <= 4; i++) {
      const v = ymax * i / 4, y = Math.round(Y(v)) + 0.5;
      c.beginPath(); c.moveTo(L, y); c.lineTo(W - R, y); c.stroke();
      c.fillText(opts.fmt ? F(v) : fmtBits(v).replace(T(' бит/с'), T(' б/с')).replace(T('бит/с'), T('б/с')), L - 8, y);
    }
    c.textAlign = 'center'; c.textBaseline = 'top';
    const nx = Math.max(2, Math.min(6, Math.floor((W - L) / 90)));
    for (let i = 0; i <= nx; i++) {
      const t = t0 + (t1 - t0) * i / nx;
      const d = new Date(t * 1000);
      // больше двух суток — подписи датами (7 и 30 дней), иначе временем
      c.fillText(t1 - t0 > 2 * 86400 ? pad2(d.getDate()) + '.' + pad2(d.getMonth() + 1) : pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + (t1 - t0 < 1200 ? ':' + pad2(d.getSeconds()) : ''), Math.min(Math.max(X(t), L + 20), W - R - 20), H - B + 7);
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
    const s = sv('svg', { class: 'topo', viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': T('Схема подключения') });
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
    nodes.appendChild(node(xL, cy, 134, 56, 'laptop', T('Клиенты LAN'), 'PBR ' + (ov.pbr.rail || '—'), '', 'ok'));
    nodes.appendChild(node(xR, cy, 140, 62, 'router', ov.host.length > 13 ? ov.host.slice(0, 12) + '…' : ov.host,
      ov.pbr.killswitch ? T('kill switch: есть') : T('kill switch: НЕТ'), 'router', ov.level === 'crit' ? 'crit' : ov.level === 'warn' ? 'warn' : 'ok'));
    // туннели
    const top = cy - (n - 1) * rowH / 2;
    tl.forEach((t, i) => {
      const y = top + i * rowH;
      const st = t.status === 'active' ? 'ok' : t.status === 'standby' ? 'ok' : t.status === 'nohs' ? 'warn' : 'crit';
      links.appendChild(link(xR + 70, cy, xT - 72, y, t.active ? 'act' : t.status === 'standby' ? 'idle' : st));
      links.appendChild(link(xT + 72, y, xI - 58, cy, t.active ? 'act' : 'idle'));
      const nm = t.label || t.name;
      nodes.appendChild(node(xT, y, 144, 54, 'shield', nm.length > 13 ? nm.slice(0, 12) + '…' : nm,
        (t.active ? T('активен') : STATUS[t.status][1].toLowerCase()) + (t.handshake >= 0 ? ' · ' + (t.handshake < 90 ? t.handshake + T(' с') : Math.round(t.handshake / 60) + T(' мин')) : ''),
        '', t.active ? 'ok' : st === 'ok' ? 'idle' : st));
    });
    nodes.appendChild(node(xI, cy, 116, 56, 'globe', T('Интернет'), ov.wan.if || 'WAN', '', ov.active ? 'ok' : 'crit'));
    // прямой WAN (без PBR)
    const yb = H - 22;
    links.appendChild(sv('path', { d: 'M' + xR + ' ' + (cy + 31) + ' L' + xR + ' ' + yb + ' L' + xI + ' ' + yb + ' L' + xI + ' ' + (cy + 28), class: 'link idle' }));
    nodes.appendChild(sv('text', { x: (xR + xI) / 2, y: yb - 6, class: 'm', 'text-anchor': 'middle' }, T('напрямую через ') + (ov.wan.if || 'WAN') + T(' — устройства вне PBR')));
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
    const clBox = el('div', { class: 'empty' }, T('загрузка…'));
    const upBox = el('div', { class: 'stack' });
    const drawUp = () => replace(upBox, (S.ov ? S.ov.tunnels : []).map((t) => el('div', null, el('div', { class: 'row small' }, el('span', { class: 'dot ' + dotFor(t.status) }), el('b', null, t.label || t.name), el('span', { class: 'muted' }, ROLE[t.role])), uptimeBar(hist, t.name))));
    const legend = el('div', { class: 'legend' });
    const tunSel = el('select', { class: 'input', 'aria-label': T('Туннель') });
    tunSel.style.width = 'auto'; tunSel.style.height = '30px';
    const seg = el('div', { class: 'seg' });
    const segBtn = (m, t) => el('button', { class: S.histMode === m ? 'on' : '', onclick: (e) => { S.histMode = m; seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b === e.currentTarget)); drawMain(); } }, t);
    add(seg, [segBtn('live', T('10 мин')), segBtn('day', T('24 ч')), segBtn('7d', T('7 дн')), segBtn('30d', T('30 дн'))]);
    // выгрузка истории в CSV (#10): за выбранный период (10 минут — как сутки)
    const csv = el('a', { class: 'btn sm ghost icon', title: T('Скачать CSV'), 'aria-label': T('Скачать CSV') }, icon('download', 'sm'));
    csv.addEventListener('click', () => { csv.href = '/api/history.csv?range=' + ({ live: '24h', day: '24h' }[S.histMode] || S.histMode); });
    S.histLong = S.histLong || {};
    const longPts = async (rg) => {
      const c = S.histLong[rg];
      if (!c || Date.now() - c.at > 600000) S.histLong[rg] = { at: Date.now(), hours: (await api('/api/history?range=' + rg)).hours };
      return S.histLong[rg].hours;
    };
    tunSel.addEventListener('change', () => { S.chartTun = tunSel.value; drawMain(); });
    let hist = [];
    add(main, [
      head(T('Обзор'), el('a', { class: 'btn', href: '#/tools' }, icon('stetho'), T('Диагностика')), rebootBtn()),
      alerts, el('div', { class: 'spacer' }), kpis, el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Схема'), topo, { icon: 'layers' }),
        card(T('События'), evs, { icon: 'activity', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/logs' }, T('Все')) })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Трафик'), el('div', { class: 'stack' }, chartWrap, legend), { icon: 'activity', id: 'traffic', right: el('div', { class: 'row' }, tunSel, seg, csv) }),
        card(T('Службы'), svcs, { icon: 'cpu', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/settings/services' }, T('Управление')) })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Клиенты в туннеле'), clBox, { icon: 'users', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/clients' }, T('Все')) }),
        card(T('Доступность каналов'), upBox, { icon: 'okc' })),
    ]);
    function kpi(lbl, ic, val, sub, extra, tone, go, hint) {
      const k = el('button', { class: 'card kpi' + (tone ? ' t-' + tone : ''), type: 'button', title: hint || '', onclick: go },
        el('div', { class: 'kh' }, el('span', { class: 'lbl' }, lbl), el('span', { class: 'kic' }, icon(ic))),
        el('div', { class: 'val' }, val), el('div', { class: 'sub' }, sub || ' '), el('div', { class: 'kx' }, extra || null));
      return k;
    }
    function alertsModal(ov) {
      api('/api/health').then((h) => {
        modal(T('Состояние'), el('div', { class: 'stack' }, alertsBox(ov),
          el('h3', null, T('Роутер')), el('div', { class: 'checks' }, h.checks.map(checkRow))), [], { wide: true });
      }).catch(err);
    }
    function drawMain() {
      const t = S.chartTun;
      if (!t) return;
      if (S.histMode === 'live') {
        const q = S.live[t] || [];
        drawChart(chartWrap, [
          { name: T('Получено'), color: '--chart-rx', fill: true, points: q.map((p) => [p[0], p[1]]) },
          { name: T('Отправлено'), color: '--chart-tx', points: q.map((p) => [p[0], p[2]]) }]);
      } else if (S.histMode === 'day') {
        const pts = hist.filter((p) => p.tun && p.tun[t]);
        drawChart(chartWrap, [
          { name: T('Получено'), color: '--chart-rx', fill: true, points: pts.map((p) => [p.t, p.tun[t].rx]) },
          { name: T('Отправлено'), color: '--chart-tx', points: pts.map((p) => [p.t, p.tun[t].tx]) }],
        { empty: T('История копится раз в минуту — загляните позже') });
      } else {
        const mode = S.histMode;
        longPts(mode).then((hs) => {
          if (S.histMode !== mode || S.chartTun !== t) return;
          const pts = hs.filter((p) => p.tun && p.tun[t]);
          drawChart(chartWrap, [
            { name: T('Получено'), color: '--chart-rx', fill: true, points: pts.map((p) => [p.t, p.tun[t].rx]) },
            { name: T('Отправлено'), color: '--chart-tx', points: pts.map((p) => [p.t, p.tun[t].tx]) }],
          { empty: T('Сводки копятся раз в час — загляните позже') });
        }).catch(err);
      }
      const r = lastRate(t);
      replace(legend, el('span', null, el('i', null), T('Получено '), el('b', null, r ? fmtBits(r[1]) : '—')),
        el('span', null, el('i', null), T('Отправлено '), el('b', null, r ? fmtBits(r[2]) : '—')));
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
      const lv = { ok: ['ok', T('Работает')], warn: ['warn', T('Внимание')], crit: ['crit', T('Проблема')] }[ov.level];
      const memPct = ov.mem.total_mb ? Math.round(ov.mem.used_mb * 100 / ov.mem.total_mb) : 0;
      const sy = ov.sys || {};
      const nAl = ov.alerts.filter((a) => a[0] !== 'info').length;
      const onMain = ov.stats.on_main_pct;
      const bar = (pct) => { const i = el('i'); i.style.width = Math.max(0, Math.min(100, pct)) + '%'; return el('div', { class: 'bar' }, i); };
      replace(kpis,
        kpi(T('Состояние'), 'shield', [el('span', { class: 'dot ' + lv[0] + ' pulse' }), el('span', { class: 't' }, lv[1])], nAl ? T('замечаний: ') + nAl : T('без замечаний'), null, lv[0], () => alertsModal(ov), T('Все замечания')),
        kpi(T('Канал'), 'tunnel', el('span', { class: 't' }, act ? (act.label || act.name) : T('нет')), act ? (act.name + (ov.forced ? T(' · выбран вручную') : T(' · авто'))) : T('трафик PBR заблокирован'), null, act ? 'ok' : 'crit', () => { location.hash = '#/tunnels'; }, T('Туннели')),
        kpi('Handshake', 'clock', el('span', { class: 't' }, act && act.handshake >= 0 ? fmtAge(act.handshake) : '—'), act ? qText(act) : '', null, act && act.handshake >= 0 && act.handshake < 180 ? 'ok' : 'warn', () => { if (act) tunnelTest(act); }, T('Тест активного канала')),
        kpi(T('Скорость'), 'activity', el('span', { class: 't' }, r ? fmtBits(r[1]) : '—'), r ? '↑ ' + fmtBits(r[2]) : T('нет данных'), null, '', () => { $('#traffic').scrollIntoView({ behavior: 'smooth' }); }, T('График трафика')),
        kpi(T('За 7 дней'), 'okc', el('span', { class: 't' }, onMain + '%'), T('на основном · переключений: ') + ov.stats.switch, bar(onMain), onMain >= 99 ? 'ok' : 'warn', () => { location.hash = '#/logs/events'; }, T('События и статистика')),
        kpi(T('Роутер'), 'cpu', el('span', { class: 't' }, 'CPU ' + Math.round(sy.cpu || 0) + '%'), T('память ') + memPct + '%' + (sy.temp ? ' · ' + Math.round(sy.temp) + '°C' : '') + ' · /data ' + fmtMB(ov.data_free_mb), bar(memPct), sy.level === 'ok' ? 'ok' : sy.level, () => { location.hash = '#/system'; }, T('Процессор, память, диск, температура')));
      replace(topo, topology(ov));
      drawUp();
      replace(evs, ov.events.length ? ov.events.slice(0, 9).map(evRow) : el('div', { class: 'empty' }, T('Событий пока нет')));
      replace(svcs, Object.entries(ov.services).filter(([, s]) => s.installed).map(([u, s]) =>
        el('div', { class: 'svc' }, el('span', { class: 'dot ' + (s.active ? 'ok' : 'crit') }), el('span', { class: 'nm' }, u.replace('awg-', '')), el('span', { class: 'ds' }, TM(s.info)),
          el('span', { class: 'badge ' + (s.active ? 'ok' : 'crit') }, s.active ? T('работает') : T('стоит')))));
      const names = ov.tunnels.map((t) => t.name);
      if (!S.chartTun || !names.includes(S.chartTun)) S.chartTun = (act || ov.tunnels[0] || {}).name || '';
      if (Array.from(tunSel.options).map((o) => o.value).join() !== names.join()) {
        replace(tunSel, ov.tunnels.map((t) => el('option', { value: t.name }, t.label ? t.label + ' (' + t.name + ')' : t.name)));
      }
      tunSel.value = S.chartTun;
    }
    every(5000, async () => { try { render(await api('/api/overview')); } catch (e) { if (!(e instanceof ApiErr && e.auth)) replace(alerts, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); } });
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
    // работает = свежий handshake; потери учитываем, только если их мерили по TCP (ICMP через туннель часто закрыт)
    return x.hs >= 0 && x.hs < 180 && !(x.qm === 'tcp' && String(x.loss) === '100');
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
        title: pad2(from.getHours()) + ':' + pad2(from.getMinutes()) + ' — ' + (r < 0 ? T('нет данных') : Math.round(r * 1000) / 10 + T('% времени работал')) }));
    });
    const pct = all ? Math.round(good * 1000 / all) / 10 : null;
    bar.setAttribute('aria-label', T('Доступность за сутки: ') + (pct == null ? T('нет данных') : pct + '%'));
    return el('div', { class: 'uptime' }, el('div', { class: 'row between small muted' }, el('span', null, T('Доступность, 24 ч')), el('b', null, pct == null ? '—' : pct + '%')), bar);
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
    if (!d.some((x) => x[0] !== ' ')) return el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Изменений нет.')));
    return el('pre', { class: 'diff' }, d.map(([k, l]) => el('span', { class: k === '+' ? 'add' : k === '-' ? 'del' : '' }, (k === ' ' ? '  ' : k + ' ') + l + '\n')));
  }
  function dropZone(onText, hint) {
    const f = el('input', { type: 'file', accept: '.conf,.txt,.json,.vpn,text/plain,application/json', class: 'hidden' });
    const read = (file) => {
      if (!file) return;
      if (file.size > 200000) { err(T('файл слишком большой')); return; }
      const rd = new FileReader();
      rd.onload = () => onText(String(rd.result), file.name);
      rd.readAsText(file);
    };
    f.addEventListener('change', () => read(f.files[0]));
    const z = el('div', { class: 'drop', tabindex: 0, role: 'button', onclick: () => f.click() },
      icon('upload', 'lg'), el('b', null, T('Перетащите файл сюда или нажмите')), el('span', { class: 'small muted' }, hint || T('.conf из AmneziaVPN, панели сервера или провайдера')), f);
    z.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); f.click(); } });
    z.addEventListener('dragover', (e) => { e.preventDefault(); z.classList.add('over'); });
    z.addEventListener('dragleave', () => z.classList.remove('over'));
    z.addEventListener('drop', (e) => { e.preventDefault(); z.classList.remove('over'); read(e.dataTransfer.files[0]); });
    return z;
  }
  function closeTop() { const m = document.querySelectorAll('.modal-bg'); if (m.length) m[m.length - 1].remove(); }

  PAGES.tunnels = function (main) {
    const autoBtn = el('button', { class: 'btn hidden', onclick: async () => { try { ok((await api('/api/tunnel/auto', {})).msg); load(); } catch (e) { err(e); } } }, icon('refresh'), T('Автовыбор канала'));
    const grid = el('div', { class: 'grid g-tun' });
    const alerts = el('div');
    add(main, [head(T('Туннели'), autoBtn,
      el('button', { class: 'btn', onclick: () => importDialog(load) }, icon('upload'), T('Импорт')),
      el('button', { class: 'btn primary', onclick: () => importDialog(load, 'new') }, icon('plus'), T('Добавить'))), alerts, el('div', { class: 'spacer' }), grid]);
    const cards = {};
    async function load() {
      const ov = await api('/api/overview');
      S.ov = ov;
      updateChrome(ov);
      autoBtn.classList.toggle('hidden', !ov.forced);
      replace(alerts, ov.forced ? el('div', { class: 'alert warn' }, icon('info'), el('div', null, T('Канал выбран вручную: '), el('b', null, ov.forced), T('. Сторож не переключит его, пока он работает. Чтобы вернуть автоматику — «Автовыбор канала».'))) : null);
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
      if (!addc) addc = el('button', { class: 'card tun add', onclick: () => importDialog(load, 'new') }, el('div', { class: 'stack' }, icon('plus', 'lg'), T('Добавить туннель'), el('span', { class: 'small' }, T('Файл .conf, ссылка vpn:// или текст: сторож будет переключаться и на него'))));
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
      el('dt', null, T('Сервер')), el('dd', null, host ? secret('ep-' + t.name, host) : '—'),
      el('dt', null, T('Порт')), el('dd', null, el('span', { class: 'mono' }, port || '—')),
      el('dt', null, T('Адрес туннеля')), el('dd', null, el('span', { class: 'mono' }, (t.address || '—').split(',')[0])),
      el('dt', null, 'Handshake'), el('dd', null, t.handshake >= 0 ? fmtAge(t.handshake) : el('span', { class: 'badge warn' }, T('нет'))),
      el('dt', null, T('Качество')), el('dd', null, qText(t)),
      el('dt', null, T('DNS через туннель')), el('dd', null, t.dns === '' ? '—' : t.dns === '1' || t.dns === 'ok' ? el('span', { class: 'badge ok' }, T('работает')) : el('span', { class: 'badge warn' }, T('нет ответа'))),
      el('dt', null, 'MTU'), el('dd', null, t.mtu || '—'),
      el('dt', null, T('Всего ↓ / ↑')), el('dd', null, fmtBytes(t.rx) + ' / ' + fmtBytes(t.tx)),
      el('dt', null, T('Конфиг')), el('dd', null, el('span', { class: 'mono' }, t.conf), t.conf_mode && t.conf_mode !== '600' ? el('span', { class: 'badge warn', title: T('Права на файл с ключом') }, t.conf_mode) : null));
    const r = lastRate(t.name);
    const act = el('button', { class: 'btn sm' + (t.active ? '' : ' primary'), disabled: t.active || t.status === 'down' },
      icon(t.active ? 'check' : 'switch', 'sm'), t.active ? T('Активен') : T('Активировать'));
    act.addEventListener('click', () => busy(act, async () => {
      try { const x = await api('/api/tunnel/switch', { name: t.name }); (x.ok ? ok : err)(x.msg); reload(); } catch (e) { err(e); }
    }));
    const xi = extras.indexOf(t.name);
    const more = [
      el('button', { class: 'btn sm icon', title: T('Тест канала'), 'aria-label': T('Тест'), onclick: () => tunnelTest(t) }, icon('stetho', 'sm')),
      el('button', { class: 'btn sm icon', title: T('Перезапустить туннель'), 'aria-label': T('Перезапустить'), onclick: async () => {
        if (!await confirmBox(T('Перезапустить ') + t.name + '?', t.active ? T('Это активный канал: на несколько секунд трафик PBR остановится (kill switch не даст ему уйти мимо).') : T('Интерфейс будет пересоздан с текущим конфигом.'), T('Перезапустить'))) return;
        try { const x = await api('/api/tunnel/restart', { name: t.name }); (x.ok ? ok : err)(x.msg || T('готово')); reload(); } catch (ex) { err(ex); }
      } }, icon('refresh', 'sm')),
    ];
    const lbl = el('button', { class: 'btn ghost icon sm', title: T('Название'), 'aria-label': T('Переименовать'), onclick: () => tunnelLabel(t, reload) }, icon('edit', 'sm'));
    return el('section', { class: 'card tun' + (t.active ? ' active' : '') },
      el('div', { class: 'hd' },
        el('div', { class: 'title' }, el('div', { class: 'nm' }, el('span', { class: 'dot ' + dotFor(t.status) }), t.label || t.name, lbl),
          el('div', { class: 'lb' }, t.label ? t.name + ' · ' : '', ROLE[t.role], t.role === 'extra' ? ' №' + (xi + 1) : '')),
        el('div', { class: 'badges' }, el('span', { class: 'badge accent' }, t.proto), el('span', { class: 'badge ' + st[0] }, st[1]), t.forced ? el('span', { class: 'badge warn' }, T('вручную')) : null)),
      el('div', { class: 'bd' }, kv),
      el('div', { class: 'rates' }, el('span', null, '↓ ', el('b', null, r ? fmtBits(r[1]) : '—')), el('span', null, '↑ ', el('b', null, r ? fmtBits(r[2]) : '—'))),
      el('div', { class: 'spark' }, sparkline(S.live[t.name])),
      el('div', { class: 'upw' }, uptimeBar(S.hist, t.name)),
      el('div', { class: 'ft' }, act, el('button', { class: 'btn sm', onclick: () => tunnelEditor(t, reload) }, icon('settings', 'sm'), T('Настроить')), el('span', { class: 'push' }), more));
  }
  function tunnelLabel(t, reload) {
    const inp = el('input', { class: 'input', value: t.label, maxlength: 40, placeholder: T('например: Германия, Hetzner') });
    const save = async () => { try { await api('/api/tunnel/label', { name: t.name, label: inp.value }); m.close(); reload(); } catch (e) { err(e); } };
    inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') save(); });
    const m = modal(T('Название ') + t.name, el('div', { class: 'field' }, el('label', null, T('Название (видно только в панели)')), inp),
      [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), el('button', { class: 'btn primary', onclick: save }, T('Сохранить'))]);
  }
  function tunnelTest(t) {
    const body = el('div', null, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), T('Проверяю ') + t.name + T(': HTTPS к трём адресам, DNS через туннель, внешний IP, MTU… (до 30 с)')));
    modal(T('Тест ') + (t.label || t.name), body, []);
    api('/api/tunnel/test', { name: t.name }).then((r) => {
      const it = (name, good, val) => el('div', { class: 'it' }, el('span', { class: 'dot ' + (good ? 'ok' : 'crit') }), name, el('span', { class: 'v' }, val));
      replace(body,
        el('div', { class: 'alert ' + (r.ok ? 'ok' : 'crit') }, icon(r.ok ? 'okc' : 'alert'), el('div', null, r.ok ? T('Канал работает') : T('Канал не пропускает трафик'))),
        el('div', { class: 'spacer' }),
        el('div', { class: 'test-list' },
          it('Handshake', r.handshake >= 0 && r.handshake < 180, r.handshake >= 0 ? fmtAge(r.handshake) : T('нет')),
          r.https.map((h) => it('HTTPS ' + h.target, h.ok, h.ok ? h.ms + T(' мс') : T('нет ответа'))),
          it(T('DNS через туннель (DoH)'), r.dns, r.dns ? T('работает') : T('нет')),
          it(T('Внешний IP'), !!r.ip, r.ip ? secret('tip-' + t.name, r.ip) : T('не получен')),
          r.mtu ? it('MTU ' + (t.mtu || ''), r.mtu === 'ok', r.mtu === 'ok' ? T('проходит') : T('пакеты не проходят — подберите MTU')) : null));
    }).catch((e) => replace(body, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))));
  }

  // ---------- редактор туннеля: параметры, текст, история, качество, экспорт
  const FGROUPS = [
    [T('Сервер'), [['Peer', 'Endpoint'], ['Peer', 'AllowedIPs'], ['Peer', 'PersistentKeepalive']]],
    [T('Интерфейс'), [['Interface', 'Address'], ['Interface', 'MTU'], ['Interface', 'DNS']]],
    [T('Ключи'), [['Interface', 'PrivateKey'], ['Peer', 'PublicKey'], ['Peer', 'PresharedKey']]],
    [T('Обфускация AmneziaWG'), [['Interface', 'Jc'], ['Interface', 'Jmin'], ['Interface', 'Jmax'], ['Interface', 'S1'], ['Interface', 'S2'], ['Interface', 'H1'], ['Interface', 'H2'], ['Interface', 'H3'], ['Interface', 'H4']]],
    ['AmneziaWG 2.0', [['Interface', 'S3'], ['Interface', 'S4'], ['Interface', 'I1'], ['Interface', 'I2'], ['Interface', 'I3'], ['Interface', 'I4'], ['Interface', 'I5']]],
    ['AmneziaWG 3.x', [['Interface', 'HeaderProtectionKey'], ['Interface', 'ContentPaddingAddition'], ['Interface', 'RekeyAfterTime'], ['Interface', 'RekeyTimeout'], ['Interface', 'RejectAfterTime'], ['Interface', 'KeepaliveTimeout'], ['Interface', 'MaxHandshakeAttempts'], ['Interface', 'RandomTrailers'], ['Interface', 'DisableCookies']]],
  ];
  const MASKV = '<скрыто>';
  async function tunnelEditor(t, reload, start) {
    let d;
    try { d = await api('/api/tunnel/fields?name=' + encodeURIComponent(t.name)); } catch (e) { err(e); return; }
    const body = el('div');
    const foot = el('div', { class: 'row wrap grow' });
    let cur = start || 'form';
    const tb = el('div', { class: 'tabs' });
    const TABS = [['form', T('Параметры')], ['text', T('Текст конфига')], ['hist', T('История (') + d.revisions + ')'], ['quality', T('Качество')], ['export', T('Ещё')]];
    const m = modal((t.label || t.name) + T(' · настройка'), el('div', null, tb, body), [foot], { wide: true, sticky: true });
    const show = (k) => {
      cur = k;
      replace(tb, TABS.map(([id, name]) => el('button', { class: 'tab' + (id === cur ? ' on' : ''), onclick: () => show(id) }, name)));
      clear(body); clear(foot);
      ({ form: edForm, text: edText, hist: edHist, quality: edQuality, export: edExport })[k]();
    };
    // число версий в названии вкладки: после применения, возврата или импорта история растёт
    const setHist = (n) => {
      TABS[2][1] = T('История (') + n + ')';
      replace(tb, TABS.map(([id, name]) => el('button', { class: 'tab' + (id === cur ? ' on' : ''), onclick: () => show(id) }, name)));
    };
    const res = el('div', { class: 'res hidden' });
    async function applyFlow(payload, btn) {
      await busy(btn, async () => {
        let p;
        try { p = await api('/api/tunnel/preview', Object.assign({ name: t.name }, payload)); } catch (e) { err(e); return; }
        if (p.errors.length) {
          replace(res, T('Не принято:\n• ') + p.errors.join('\n• ')); res.classList.remove('hidden'); res.classList.add('bad');
          res.scrollIntoView({ block: 'nearest', behavior: 'smooth' });   // форма длинная: без прокрутки ошибку внизу не видно
          err(T('Не принято: ') + p.errors.length + T(' — подробности под формой'));
          return;
        }
        if (!p.changed) { toast(T('Изменений нет')); return; }
        const go = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Применить'));
        const cm = modal(T('Проверьте изменения · ') + t.name, el('div', null,
          el('p', { class: 'muted small' }, T('Туннель будет пересоздан с новым конфигом (несколько секунд без трафика через него). Если он не поднимется — вернётся прежний конфиг. Прежняя версия сохранится в истории.')),
          diffView(p.old, p.new)), [el('button', { class: 'btn', onclick: () => cm.close() }, T('Отмена')), go], { wide: true });
        go.addEventListener('click', () => busy(go, async () => {
          try {
            const x = await api('/api/tunnel/conf', Object.assign({ name: t.name }, payload));
            cm.close();
            replace(res, x.msg); res.classList.remove('hidden', 'bad');
            (x.ok ? ok : err)(x.ok ? T('Конфиг применён') : T('Конфиг не применён: возвращён прежний'));
            reload();
            d = await api('/api/tunnel/fields?name=' + encodeURIComponent(t.name));
            setHist(d.revisions);
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
            inp = el('input', { class: 'input mono', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: v ? T('задан — не показывается') : T('не задан') });
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
        if (title === 'AmneziaWG 2.0' || title === 'AmneziaWG 3.x' || title === T('Ключи')) {
          return el('details', { class: 'fgroup', open: title !== T('Ключи') ? has2 : false }, el('summary', null, title, title === T('Ключи') ? el('span', { class: 'muted small' }, T(' — менять только при смене сервера или ключей')) : null), g);
        }
        return el('div', { class: 'fgroup' }, el('h3', null, title), g);
      });
      add(body, [
        d.peers > 1 ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('В конфиге несколько [Peer]: форма меняет только первый. Остальные — во вкладке «Текст конфига».'))) : null,
        d.other.length ? el('div', { class: 'small muted' }, T('Другие строки конфига сохраняются как есть: ') + d.other.join(', ')) : null,
        groups, res]);
      const chk = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Проверить и применить'));
      chk.addEventListener('click', () => {
        const f = { Interface: {}, Peer: {} };
        for (const [key, g] of Object.entries(ctl)) {
          const val = g();
          if (val !== g.orig) { const [s, k] = key.split('.'); f[s][k] = val; }
        }
        if (!Object.keys(f.Interface).length && !Object.keys(f.Peer).length) { toast(T('Изменений нет')); return; }
        applyFlow({ fields: f }, chk);
      });
      add(foot, [el('span', { class: 'small muted grow' }, T('Файл: ') + d.path), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть')), chk]);
    }
    function edText() {
      const ta = el('textarea', { class: 'input tall', spellcheck: 'false', autocomplete: 'off' });
      ta.value = d.text;
      add(body, [
        el('div', { class: 'alert info' }, icon('lock'), el('div', null, T('Ключи заменены на «'), el('code', null, MASKV), T('» — такие строки сохранят прежнее значение. Новый конфиг можно вставить целиком или перетащить файл. Строки PostUp/PreDown не допускаются.'))),
        el('div', { class: 'spacer' }), dropZone((txt) => { ta.value = txt; toast(T('Файл загружен: проверьте и примените')); }, T('Заменить конфиг этого туннеля файлом .conf')),
        el('div', { class: 'spacer' }), ta, res]);
      const chk = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Проверить и применить'));
      chk.addEventListener('click', () => {
        if (/^\s*vpn:\/\//.test(ta.value)) { m.close(); importDialog(reload, t.name, ta.value); return; }
        applyFlow({ text: ta.value }, chk);
      });
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть')), chk]);
    }
    async function edHist() {
      const box = el('div', null, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), T('загрузка…')));
      add(body, [el('p', { class: 'muted small' }, T('Каждое изменение конфига сохраняется (до 15 версий, права 600). Можно сравнить с текущим и вернуть.')), box]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть'))]);
      try {
        const r = await api('/api/tunnel/revisions?name=' + encodeURIComponent(t.name));
        setHist(r.revisions.length);
        replace(box, r.revisions.length ? el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
          el('thead', null, el('tr', null, el('th', null, T('Версия')), el('th', null, T('Что')), el('th', null, T('Сервер')), el('th', null, ''), el('th', null, ''))),
          el('tbody', null, r.revisions.map((v) => el('tr', null,
            el('td', { class: 'nowrap' }, fmtTime(v.time, true), v.current ? el('span', { class: 'badge ok' }, T('текущая')) : v.same ? el('span', { class: 'badge outline' }, T('как текущая')) : null),
            el('td', { class: 'muted' }, v.why || '—'),
            el('td', null, el('span', { class: 'mono small' }, v.summary.endpoint || '—'), ' ', el('span', { class: 'badge outline' }, v.summary.proto)),
            el('td', { class: 'r nowrap' }, el('button', { class: 'btn sm', onclick: async () => {
              try { const x = await api('/api/tunnel/revision?name=' + encodeURIComponent(t.name) + '&id=' + encodeURIComponent(v.id)); modal(T('Версия ') + fmtTime(v.time, true) + T(' → текущая'), diffView(x.text, x.current), [], { wide: true }); } catch (e) { err(e); }
            } }, T('Сравнить'))),
            el('td', { class: 'r nowrap' }, v.current || v.same ? null : el('button', { class: 'btn sm primary', onclick: async (e) => {
              if (!await confirmBox(T('Вернуть версию?'), T('Конфиг ') + t.name + T(' станет таким, как ') + fmtTime(v.time, true) + T('. Текущий сохранится в истории.'), T('Вернуть'))) return;
              try { const x = await api('/api/tunnel/revision/restore', { name: t.name, id: v.id }); (x.ok ? ok : err)(x.msg.split('\n')[0]); reload(); show('hist'); } catch (ex) { err(ex); }
            } }, T('Вернуть')))))))) : el('div', { class: 'empty' }, T('Версий пока нет: они появятся после первого изменения.')));
      } catch (e) { replace(box, e.message); }
    }
    async function edQuality() {
      const rtt = el('div', { class: 'chart-wrap sm' }), loss = el('div', { class: 'chart-wrap sm' });
      const sp = el('div');
      const spOut = el('div', { class: 'out hidden' });
      const size = el('select', { class: 'input' }, [5, 10, 25, 50].map((x) => el('option', { value: x, selected: x === 10 }, x + T(' МБ'))));
      size.style.width = 'auto';
      const run = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Замерить скорость'));
      add(body, [uptimeBar(S.hist, t.name), el('div', { class: 'spacer' }),
        el('div', { class: 'grid g-2e' }, el('div', null, el('h3', null, T('Задержка (RTT), мс')), rtt), el('div', null, el('h3', null, T('Потери, %')), loss)),
        el('div', { class: 'spacer' }), el('h3', null, T('Замеры скорости')), el('p', { class: 'small muted' }, T('Скачивание и отдача через этот туннель (speed.cloudflare.com). Трафик замера считается у провайдера VPN.')),
        el('div', { class: 'row' }, size, run), spOut, sp]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть'))]);
      const loadSp = async () => {
        const r = await api('/api/speed');
        const xs = r.history.filter((x) => x.iface === t.name).slice(0, 10);
        replace(sp, xs.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Когда')), el('th', null, T('Загрузка')), el('th', null, T('Отдача')), el('th', null, T('Задержка')))),
          el('tbody', null, xs.map((x) => el('tr', null, el('td', null, fmtTime(x.t, true)), el('td', null, x.down_bps ? fmtBits(x.down_bps) : '—'), el('td', null, x.up_bps ? fmtBits(x.up_bps) : '—'), el('td', null, x.ping_ms ? x.ping_ms + T(' мс') : '—'))))) : el('div', { class: 'empty' }, T('Замеров ещё не было')));
      };
      run.addEventListener('click', () => busy(run, async () => {
        spOut.classList.remove('hidden'); spOut.textContent = '';
        try { await runJob({ tool: 'speedtest', iface: t.name, mb: +size.value }, spOut); await loadSp(); } catch (e) { err(e); }
      }));
      try {
        if (!S.hist) S.hist = (await api('/api/history')).points;
        const pts = S.hist.filter((p) => p.tun && p.tun[t.name]);
        drawChart(rtt, [{ name: 'RTT', color: '--chart-rx', fill: true, points: pts.filter((p) => p.tun[t.name].rtt !== '').map((p) => [p.t, +p.tun[t.name].rtt]) }],
          { fmt: (v) => Math.round(v) + T(' мс'), empty: T('Нет данных: RTT меряется, когда включено переключение по качеству') });
        drawChart(loss, [{ name: T('Потери'), color: '--crit', fill: true, points: pts.filter((p) => p.tun[t.name].loss !== '').map((p) => [p.t, +p.tun[t.name].loss]) }],
          { fmt: (v) => Math.round(v) + '%', max: 100, empty: T('Нет данных') });
        await loadSp();
      } catch (e) { err(e); }
    }
    function edExport() {
      const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), T('Скачать ') + t.name + '.conf');
      go.addEventListener('click', () => busy(go, async () => {
        try {
          const x = await api('/api/tunnel/export', { name: t.name, current: pw.value });
          const a = el('a', { href: URL.createObjectURL(new Blob([x.text], { type: 'text/plain' })), download: x.filename });
          document.body.appendChild(a); a.click(); a.remove(); pw.value = '';
          ok(T('Файл скачан: храните его как пароль'));
        } catch (e) { err(e); }
      }));
      const extras = (S.ov ? S.ov.tunnels : []).filter((x) => x.role === 'extra').map((x) => x.name);
      const xi = extras.indexOf(t.name);
      const move = (dir) => async () => {
        const n = extras.slice(); n.splice(xi + dir, 0, n.splice(xi, 1)[0]);
        try { ok((await api('/api/tunnel/order', { extra: n })).msg); m.close(); reload(); } catch (ex) { err(ex); }
      };
      add(body, [
        el('h3', null, T('Скачать конфиг')),
        el('div', { class: 'alert warn' }, icon('key'), el('div', null, T('Файл содержит закрытый ключ роутера. Не отправляйте его в чаты. Одновременно использовать этот же конфиг на другом устройстве нельзя: сервер будет «перекидывать» сеанс между ними.'))),
        el('div', { class: 'spacer' }), el('div', { class: 'input-group' }, el('div', { class: 'field grow' }, el('label', null, T('Ваш пароль от панели')), pw)), go,
        xi >= 0 ? [el('div', { class: 'spacer' }), el('h3', null, T('Приоритет')), el('p', { class: 'muted small' }, T('Порядок: основной → запасной → дополнительные. Сейчас этот туннель №') + (xi + 1) + T(' из ') + extras.length + T(' дополнительных.')),
          el('div', { class: 'row' }, el('button', { class: 'btn', disabled: xi === 0, onclick: move(-1) }, icon('up', 'sm'), T('Выше')),
            el('button', { class: 'btn', disabled: xi === extras.length - 1, onclick: move(1) }, T('Ниже')))] : null,
        t.role === 'extra' ? [el('div', { class: 'spacer' }), el('h3', null, T('Удалить туннель')),
          el('p', { class: 'muted small' }, T('Туннель будет остановлен и убран из сторожа вместе с его правилами. Файл конфига и история версий останутся на роутере.')),
          el('button', { class: 'btn danger', onclick: async () => {
            const pw = await promptPw(T('Удалить ') + t.name + '?', T('Туннель будет остановлен и убран из сторожа.'));
            if (pw == null) return;
            try { ok((await api('/api/tunnel/remove', { name: t.name, current: pw })).msg); m.close(); reload(); } catch (ex) { err(ex); }
          } }, icon('trash', 'sm'), T('Удалить ') + t.name)]
          : el('p', { class: 'small muted' }, T('Основной и запасной туннели удаляются установщиком: install.sh → Компоненты → Туннели.'))]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть'))]);
    }
    show(cur);
  }

  // ---------- импорт: файл, текст, ссылка vpn://
  function importDialog(reload, target, preset) {
    const ta = el('textarea', { class: 'input', rows: 7, spellcheck: 'false', placeholder: T('[Interface]\nPrivateKey = …\n…\n\nили ссылка vpn://… из AmneziaVPN («Поделиться» → «Ключ»)') });
    if (preset) ta.value = preset;
    let fname = '';
    const res = el('div');
    const parse = el('button', { class: 'btn primary' }, icon('search', 'sm'), T('Разобрать'));
    const foot = [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть')), parse];
    const m = modal(target === 'new' ? T('Новый туннель') : T('Импорт конфига'), el('div', null,
      dropZone((txt, n) => { ta.value = txt; fname = n; parse.click(); }),
      el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, T('Или вставьте текст конфига или ссылку vpn://')), ta), res), foot, { wide: true, sticky: true });
    parse.addEventListener('click', () => busy(parse, async () => {
      let r;
      try { r = await api('/api/import/parse', { data: ta.value }); } catch (e) { replace(res, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); return; }
      const f = r.fields;
      const info = el('dl', { class: 'kv' },
        el('dt', null, T('Источник')), el('dd', null, r.source === 'vpn://' ? T('ссылка AmneziaVPN') : r.source === 'json' ? 'JSON AmneziaVPN' : (fname || T('текст конфига'))),
        el('dt', null, T('Протокол')), el('dd', null, el('span', { class: 'badge accent' }, r.proto)),
        el('dt', null, T('Сервер')), el('dd', null, el('span', { class: 'mono' }, f.Peer.Endpoint || '—')),
        el('dt', null, T('Адрес')), el('dd', null, el('span', { class: 'mono' }, f.Interface.Address || '—')),
        el('dt', null, 'MTU'), el('dd', null, f.Interface.MTU || T('по умолчанию')));
      const used = S.ov ? S.ov.tunnels : [];
      let sug = 'awgalt1';
      for (let i = 1; used.some((t) => t.name === sug); i++) sug = 'awgalt' + (i + 1);
      const nm = el('input', { class: 'input mono', value: sug, maxlength: 13, autocapitalize: 'off', spellcheck: 'false' });
      const lb = el('input', { class: 'input', maxlength: 40, placeholder: T('например: Нидерланды') });
      const tsel = el('select', { class: 'input' }, el('option', { value: 'new' }, T('Новый дополнительный туннель')),
        used.map((t) => el('option', { value: t.name, selected: target === t.name }, T('Заменить конфиг: ') + (t.label ? t.label + ' (' + t.name + ')' : t.name) + ' — ' + ROLE[t.role].toLowerCase())));
      const newBox = el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Имя интерфейса')), nm, el('span', { class: 'hint' }, T('awg + до 10 латинских букв/цифр'))),
        el('div', { class: 'field' }, el('label', null, T('Название')), lb));
      const sync = () => newBox.classList.toggle('hidden', tsel.value !== 'new');
      tsel.addEventListener('change', sync); sync();
      const out = el('div', { class: 'res hidden' });
      const apply = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Применить'));
      apply.addEventListener('click', () => busy(apply, async () => {
        if (tsel.value !== 'new' && !await confirmBox(T('Заменить конфиг ') + tsel.value + '?', T('Туннель будет пересоздан с новым конфигом. Прежний сохранится в истории версий; если новый не поднимется — вернётся прежний.'), T('Заменить'))) return;
        try {
          const x = await api('/api/import/apply', { token: r.token, target: tsel.value, name: nm.value.trim(), label: lb.value.trim() });
          out.textContent = x.msg; out.classList.remove('hidden');
          (x.ok ? ok : err)(x.ok ? T('Готово') : T('Применено с ошибкой — смотрите вывод'));
          reload();
        } catch (e) { out.textContent = e.message; out.classList.remove('hidden'); err(e); }
      }));
      replace(res, el('div', { class: 'spacer' }),
        r.errors.length ? el('div', { class: 'alert crit' }, icon('alert'), el('div', null, T('Конфиг не подходит:'), el('ul', null, r.errors.map((x) => el('li', null, x))))) : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Конфиг распознан. Ключи остаются на роутере и в браузер не возвращаются.'))),
        r.warnings.length ? el('div', { class: 'alert warn' }, icon('info'), el('div', null, r.warnings.join('; '))) : null,
        el('div', { class: 'spacer' }), info,
        r.ok ? [el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, T('Куда')), tsel), newBox, out] : null);
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

  // ===================================================================== РОУТЕР (железо)
  function gauge(pct, label, sub, tone) {
    pct = Math.max(0, Math.min(100, +pct || 0));
    const r = 34, c = 2 * Math.PI * r;
    const ring = sv('svg', { viewBox: '0 0 84 84', class: 'gauge', 'aria-hidden': 'true' },
      sv('circle', { cx: 42, cy: 42, r, class: 'gb' }),
      sv('circle', { cx: 42, cy: 42, r, class: 'gf ' + (tone || ''), 'stroke-dasharray': (c * pct / 100).toFixed(1) + ' ' + c.toFixed(1), transform: 'rotate(-90 42 42)' }));
    return el('div', { class: 'gw' }, el('div', { class: 'gr' }, ring, el('div', { class: 'gv' }, Math.round(pct) + '%')),
      el('div', { class: 'gl' }, el('b', null, label), el('span', { class: 'muted small' }, sub)));
  }
  const toneOf = (p, w, c) => (p >= c ? 'crit' : p >= w ? 'warn' : 'ok');
  PAGES.system = function (main) {
    const gauges = el('div', { class: 'grid g-gauge' });
    const checks = el('div', { class: 'checks' });
    const cpuC = el('div', { class: 'chart-wrap sm' }), memC = el('div', { class: 'chart-wrap sm' }), tC = el('div', { class: 'chart-wrap sm' }), ctC = el('div', { class: 'chart-wrap sm' });
    const disks = el('div'), procs = el('div'), info = el('div');
    add(main, [head(T('Роутер'), el('button', { class: 'btn', onclick: () => load() }, icon('refresh', 'sm'), T('Обновить')), rebootBtn()),
      gauges, el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Проверки железа'), checks, { icon: 'stetho' }),
        card(T('Сведения'), info, { icon: 'info' })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2e' },
        card(T('Процессор, % · 24 ч'), cpuC, { icon: 'cpu' }), card(T('Память, % · 24 ч'), memC, { icon: 'mem' }),
        card(T('Температура, °C · 24 ч'), tC, { icon: 'thermo' }), card(T('Таблица соединений, % · 24 ч'), ctC, { icon: 'layers' })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2e' }, card(T('Диски'), disks, { icon: 'disk', flush: true }), card(T('Процессы: больше всего памяти'), procs, { icon: 'cpu', flush: true }))]);
    let h = null;
    const draw = () => {
      if (!h) return;
      const pts = h.history || [];
      const ser = (k) => pts.filter((p) => p[k] != null).map((p) => [p.t, p[k]]);
      const pf = (v) => Math.round(v) + '%';
      drawChart(cpuC, [{ name: 'CPU', color: '--chart-rx', fill: true, points: ser('cpu') }], { fmt: pf, max: 100, empty: T('История копится раз в минуту') });
      drawChart(memC, [{ name: T('Память'), color: '--chart-tx', fill: true, points: ser('mem') }], { fmt: pf, max: 100, empty: T('История копится раз в минуту') });
      drawChart(tC, [{ name: '°C', color: '--warn', fill: true, points: ser('temp') }], { fmt: (v) => Math.round(v) + '°C', empty: T('Датчики температуры не найдены') });
      drawChart(ctC, [{ name: 'conntrack', color: '--ok', fill: true, points: ser('ct') }], { fmt: pf, max: 100, empty: T('История копится раз в минуту') });
    };
    S.redraw = draw;
    async function load() {
      h = await api('/api/health');
      const dd = h.disks[0] || {};
      replace(gauges,
        gauge(h.cpu, T('Процессор'), T('нагрузка ') + h.load.map((x) => x.toFixed(2)).join(' ') + ' · ' + h.cores + T(' ядра'), toneOf(h.cpu, 80, 95)),
        gauge(h.mem.used_pct, T('Память'), T('свободно ') + fmtMB(h.mem.avail_mb) + T(' из ') + fmtMB(h.mem.total_mb), toneOf(h.mem.used_pct, 88, 95)),
        gauge(dd.used_pct || 0, T('Диск /data'), T('свободно ') + fmtMB(dd.free_mb), toneOf(dd.used_pct || 0, 85, 95)),
        h.temps.length ? gauge(Math.min(100, h.temp_max), T('Температура'), Math.round(h.temp_max) + '°C · ' + T('датчиков: ') + h.temps.length, toneOf(h.temp_max, 85, 95)) : null,
        h.conntrack.max > 0 ? gauge(100 * h.conntrack.count / h.conntrack.max, T('Соединения'), h.conntrack.count + T(' из ') + h.conntrack.max, toneOf(100 * h.conntrack.count / h.conntrack.max, 80, 95)) : null);
      replace(checks, h.checks.map(checkRow));
      const kv = (rows) => el('dl', { class: 'kv' }, rows.map(([k, v]) => [el('dt', null, k), el('dd', null, v)]));
      replace(info, kv([[T('Модель'), h.model], [T('Ядро'), h.kernel_ver], [T('Без перезагрузки'), fmtDur(h.uptime)], [T('Процессов'), String(h.nproc)],
        [T('Своп'), h.mem.swap_total_mb ? h.mem.swap_used_mb + ' / ' + h.mem.swap_total_mb + T(' МБ') : T('нет')],
        [T('OOM за сутки'), h.kernel.oom < 0 ? '—' : String(h.kernel.oom)], [T('Ошибки ввода-вывода за сутки'), h.kernel.io < 0 ? '—' : String(h.kernel.io)]].concat(
        h.temps.map((t) => [t.name, Math.round(t.c) + '°C']))));
      replace(disks, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Раздел')), el('th', { class: 'r' }, T('Свободно')), el('th', null, T('Занято')))),
        el('tbody', null, h.disks.map((d) => el('tr', null, el('td', null, el('span', { class: 'mono' }, d.path)), el('td', { class: 'r nowrap' }, fmtMB(d.free_mb)),
          el('td', null, el('div', { class: 'mbar ' + toneOf(d.used_pct, 85, 95) }, (() => { const i = el('i'); i.style.width = d.used_pct + '%'; return i; })()), el('span', { class: 'small muted' }, d.used_pct + '%')))))));
      replace(procs, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Процесс')), el('th', { class: 'r' }, 'PID'), el('th', { class: 'r' }, T('Память')))),
        el('tbody', null, h.procs.map((p) => el('tr', { title: p.cmd }, el('td', null, el('b', null, p.name), el('div', { class: 'small muted ell' }, p.cmd)), el('td', { class: 'r mono' }, p.pid), el('td', { class: 'r nowrap' }, p.rss_mb + T(' МБ')))))));
      draw();
    }
    every(15000, load);
  };

  // ===================================================================== КЛИЕНТЫ
  function clientsTable(list, compact) {
    if (!list.length) return el('div', { class: 'empty' }, T('Сейчас через туннель никто не ходит (или conntrack недоступен)'));
    return el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
      el('thead', null, el('tr', null, el('th', null, T('Устройство')), el('th', null, 'IP'), compact ? null : el('th', null, 'MAC'), el('th', null, T('Туннель')),
        el('th', { class: 'r' }, T('Соединений')), compact ? null : el('th', { class: 'r' }, T('Трафик')), compact ? null : el('th', null, T('Куда чаще всего')))),
      el('tbody', null, list.map((c) => el('tr', null,
        el('td', null, el('span', { class: 'row' }, el('span', { class: 'cav' }, icon('laptop', 'sm')), el('b', null, c.name || T('без имени')))),
        el('td', null, el('span', { class: 'mono' }, c.ip)),
        compact ? null : el('td', null, el('span', { class: 'mono small muted' }, c.mac || '—')),
        el('td', null, el('span', { class: 'badge accent' }, c.tunnel)),
        el('td', { class: 'r' }, c.conns),
        compact ? null : el('td', { class: 'r nowrap' }, c.bytes ? fmtBytes(c.bytes) : '—'),
        compact ? null : el('td', { class: 'mono small muted' }, c.top.join(', ')))))));
  }
  PAGES.clients = function (main) {
    const box = el('div');
    const q = el('input', { class: 'input', placeholder: T('поиск по имени, IP, MAC'), spellcheck: 'false' });
    q.style.maxWidth = '260px'; q.style.height = '30px';
    const sum = el('span', { class: 'muted small' });
    let data = { clients: [] };
    const show = () => {
      const f = q.value.trim().toLowerCase();
      replace(box, clientsTable(data.clients.filter((c) => !f || (c.name + ' ' + c.ip + ' ' + c.mac).toLowerCase().includes(f)), false));
      replace(sum, data.clients.length + T(' устр. · ') + data.total + T(' соединений'));
    };
    q.addEventListener('input', show);
    add(main, [head(T('Клиенты в туннеле')),
      el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Устройства LAN, чьи соединения сейчас идут через туннели (по таблице conntrack: метка PBR '), el('code', null, '—'), T(' или адрес туннеля). Кто попадает в туннель, задаётся правилами PBR в UniFi и доменами в «Маршрутизации».'))),
      el('div', { class: 'spacer' }),
      el('section', { class: 'card' }, el('div', { class: 'hd' }, icon('users'), el('h2', null, T('Сейчас')), sum, q), box)]);
    every(5000, async () => {
      data = await api('/api/clients');
      const c = main.querySelector('.alert.info code'); if (c) c.textContent = data.mark || '—';
      show();
    });
  };

  // ===================================================================== формы настроек
  const SPEC = {
    RECOVER_SEC: { t: 'num', unit: T('с'), hint: T('Сколько основной канал должен проработать стабильно, прежде чем сторож вернётся на него.') },
    QUALITY: { t: 'bool', hint: T('Уходить с канала, если потери или задержка выше порога, а другой канал лучше.') },
    QUALITY_LOSS: { t: 'num', unit: '%', hint: T('Потери пакетов, при которых канал считается плохим.') },
    QUALITY_RTT: { t: 'num', unit: T('мс'), hint: T('Порог задержки; 0 — не учитывать.') },
    MIN_DWELL: { t: 'num', unit: T('с'), hint: T('Пауза после переключения, чтобы каналы не «прыгали».') },
    EXTRA_SUBNETS: { t: 'list', ph: '192.168.3.0/24', hint: T('Подсети VPN-сервера на роутере (WireGuard / L2TP / OpenVPN): их клиенты тоже идут через туннель.') },
    TUN_DOMAINS: { t: 'list', ph: 'youtube.com\ngooglevideo.com', hint: T('Сайты, которые открываются через туннель для всей LAN (или выбранных клиентов) без PBR. Поддомены включаются. Клиенты должны спрашивать DNS у роутера.') },
    TUN_CLIENTS: { t: 'list', ph: '192.168.1.50\n192.168.1.0/28', hint: T('Для кого действуют домены через туннель. Пусто — вся LAN.') },
    DIRECT_DOMAINS: { t: 'list', ph: 'gosuslugi.ru\nsberbank.ru', hint: T('Устройства под PBR откроют эти сайты напрямую, мимо туннеля.') },
    DIRECT_SUBNETS: { t: 'list', ph: '95.173.128.0/19', hint: T('Адреса и подсети, куда устройства под PBR ходят напрямую.') },
    LEAK_GUARD: { t: 'bool', hint: T('Запрет выхода трафика PBR-устройств в WAN мимо туннеля — вторая линия защиты после blackhole.') },
    LEAK_V6: { t: 'choice', opts: [['block', T('Блокировать')], ['route', T('Через туннель')], ['off', T('Не трогать')]], hint: T('IPv6 устройств под PBR: «Блокировать» (по умолчанию) — устройства идут по IPv4 через туннель; «Через туннель» — IPv6 тоже идёт через туннель, если сервер выдал туннелю IPv6-адрес (иначе отклоняется); «Не трогать» — IPv6 идёт мимо туннеля.') },
    LISTS_MODE: { t: 'choice', opts: [['off', T('Всё (как настроено в UniFi)')], ['blocked', T('Только заблокированное')], ['geoip', T('Всё, кроме выбранных стран')]], hint: T('Для устройств под PBR (и дополнительных маршрутов). «Только заблокированное» — через туннель идут только адреса из списков заблокированного, остальное напрямую. «Всё, кроме стран» — напрямую идут только адреса выбранных стран (умный дом с серверами в Китае, местные сервисы), остальное через туннель. Сужает то, что UniFi уже отправила в туннель: для «Всё, кроме стран» правило PBR устройства должно вести весь его трафик (назначение — Internet).') },
    GEO_COUNTRIES: { t: 'text', ph: 'ru cn by kz', hint: T('Коды стран через пробел; их адреса идут напрямую в режиме «Всё, кроме выбранных стран».') },
    LIST_URLS: { t: 'list', ph: 'https://antifilter.download/list/allyouneed.lst', hint: T('Списки заблокированного (по сети IPv4 на строку). Пусто — antifilter.download. Обновляются раз в сутки; не скачались — остаются прежние.') },
    DNS_INTERCEPT: { t: 'bool', hint: T('Устройства с «зашитым» DNS (8.8.8.8, 114.114.114.114 — телевизоры, умный дом) спрашивают DNS у роутера: домены через туннель, исключения и правила UniFi по доменам работают и для них. Чтобы сам роутер спрашивал DNS через туннель — включите «Весь DNS роутера через туннель». Фильтр контента UniFi не обходится.') },
    DNS_CLIENTS: { t: 'list', ph: '192.168.1.50\n192.168.1.64/28', hint: T('Чей DNS перехватывать. Пусто — вся LAN.') },
    DNS_BLOCK_DOT: { t: 'bool', hint: T('Отказ DNS-over-TLS (порт 853, «Частный DNS» Android) и DNS по IPv6 к чужим серверам — устройства переходят на обычный DNS через роутер. DNS-over-HTTPS в браузерах так не перехватить: его отключают в настройках браузера.') },
    UI_FIX: { t: 'bool', hint: T('Соединения самого роутера с облаком UniFi (unifi.ui.com) — через туннель. Нужно, если ui.com недоступен напрямую.') },
    UI_DOMAINS: { t: 'list', hint: T('Домены облака UniFi.') },
    UI_DNS: { t: 'text', hint: T('DNS-сервер для доменов UniFi (запрос уходит через туннель).') },
    DNS_ALL_TUNNEL: { t: 'bool', hint: T('Все DNS-запросы самого роутера — через туннель (защита от подмены DNS провайдером).') },
    METRICS_PORT: { t: 'num', hint: T('Порт /metrics для Prometheus. Пусто — выключено.') },
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
        const inp = el('input', { class: 'input', value: v, inputmode: sp.t === 'num' ? 'numeric' : 'text', placeholder: sp.unit || sp.ph || '' });
        c = sp.unit ? el('div', { class: 'input-group' }, inp, el('span', { class: 'muted row' }, sp.unit)) : inp;
        ctl[k] = () => inp.value.trim();
      }
      return el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, TM(data.labels[k] || k)), el('span', null, sp.hint), el('div', { class: 'small muted mono' }, k)),
        el('div', { class: 'ctl' + (sp.t === 'bool' ? ' auto' : '') }, c));
    });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Применить'));
    const res = el('div', { class: 'res hidden' });
    save.addEventListener('click', () => busy(save, async () => {
      const ch = {};
      for (const k of keys) if (ctl[k]() !== (data.values[k] || '')) ch[k] = ctl[k]();
      if (!Object.keys(ch).length) { toast(T('Изменений нет')); return; }
      try {
        const x = await api('/api/settings', { values: ch });
        Object.assign(data.values, ch);
        res.textContent = x.msg; res.classList.remove('hidden');
        ok(T('Сохранено'));
      } catch (e) { err(e); }
    }));
    return card(title, el('div', null, note || null, rows, res), { icon: ic, foot: save });
  }

  // ===================================================================== МАРШРУТИЗАЦИЯ
  PAGES.routing = async function (main) {
    add(main, head(T('Маршрутизация')));
    const body = el('div', { class: 'stack' }, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), T('загрузка…')));
    main.appendChild(body);
    let d, ov;
    try { [d, ov] = await Promise.all([settings(true), api('/api/overview')]); } catch (e) { replace(body, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); return; }
    updateChrome(ov);
    const p = d.pbr;
    const pbr = card('Policy-Based Routing UniFi', el('div', { class: 'grid g-2e' },
      el('dl', { class: 'kv' },
        el('dt', null, T('Профиль (интерфейс)')), el('dd', null, el('span', { class: 'mono' }, p.RAIL_IF || '—')),
        el('dt', null, T('Таблица')), el('dd', null, el('span', { class: 'mono' }, p.TABLE || '—')),
        el('dt', null, T('Метка (fwmark/mask)')), el('dd', null, el('span', { class: 'mono' }, p.MARK || '—')),
        el('dt', null, T('Приоритет ip rule')), el('dd', null, el('span', { class: 'mono' }, p.PRIO || '—')),
        el('dt', null, 'Kill switch (blackhole)'), el('dd', null, ov.pbr.killswitch ? el('span', { class: 'badge ok' }, T('на месте')) : el('span', { class: 'badge crit' }, T('нет'))),
        el('dt', null, T('Каналы по приоритету')), el('dd', null, [p.MAIN, p.BACKUP].concat((p.TUNNELS_EXTRA || '').split(' ')).filter(Boolean).join(' → '))),
      el('div', null, el('div', { class: 'small muted' }, T('Маршруты в таблице ') + (p.TABLE || '')),
        el('pre', { class: 'res' }, ov.pbr.routes.join('\n') || T('(пусто)')))),
    { icon: 'route', right: el('a', { class: 'btn sm', href: '#/tools' }, T('Проверить')) });
    replace(body,
      el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Какие устройства идут через туннель, задаётся в UniFi Network: Settings → Routing → Policy-Based Routes (профиль '), el('b', null, p.RAIL_IF || '—'), T('). Здесь — то, что работает поверх: домены, исключения, защита от утечек.'))),
      pbr,
      settingsForm(T('Домены через туннель'), 'globe', ['TUN_DOMAINS', 'TUN_CLIENTS'], d),
      settingsForm(T('Исключения: напрямую мимо туннеля'), 'link', ['DIRECT_DOMAINS', 'DIRECT_SUBNETS'], d),
      settingsForm(T('Списки и GeoIP'), 'layers', ['LISTS_MODE', 'GEO_COUNTRIES', 'LIST_URLS'], d, listsStatus()),
      settingsForm(T('Защита от утечек'), 'shield', ['LEAK_GUARD', 'LEAK_V6'], d),
      settingsForm(T('DNS устройств'), 'search', ['DNS_INTERCEPT', 'DNS_CLIENTS', 'DNS_BLOCK_DOT', 'DNS_ALL_TUNNEL'], d),
      settingsForm(T('VPN-сервер роутера'), 'users', ['EXTRA_SUBNETS'], d),
      settingsForm(T('Облако UniFi'), 'globe', ['UI_FIX', 'UI_DOMAINS', 'UI_DNS'], d));
  };

  // ===================================================================== ИНСТРУМЕНТЫ
  const TOOLS = [
    ['diagnose', T('Диагностика'), 'stetho', T('Дерево причин: WAN → туннели → PBR → NAT → IPv6 → службы. Итог — первая причина и команда исправления.')],
    ['selftest', T('Самопроверка'), 'okc', T('Проверка установки: файлы, службы, правила, маршруты, handshake.')],
    ['selftest-full', T('Проверка kill switch'), 'shield', T('Самопроверка с кратким отключением туннелей: трафик PBR не должен уйти в WAN.')],
    ['switch-test', T('Тест переключения'), 'switch', T('Имитация падения основного канала: сторож должен уйти на запасной (до 45 с).')],
    ['audit', T('Аудит'), 'search', T('Права на файлы, ключи, открытые порты, лишние правила.')],
    ['dedup', T('Очистка дубликатов'), 'layers', T('Убрать повторяющиеся правила iptables, если они накопились.')],
    ['mtu', T('Подбор MTU'), 'ruler', T('Найти наибольший MTU, который проходит через каждый туннель.')],
    ['guard-check', T('Проверка защиты'), 'shield', T('Правила защиты от утечек, наборы доменов и исключений.')],
    ['self-check', T('Трафик роутера'), 'router', T('Проверка awg-self: unifi.ui.com и DNS самого роутера.')],
    ['subnets-check', T('Подсети VPN'), 'users', T('Правила для клиентов VPN-сервера роутера.')],
    ['self-reconnect', T('Переподключить облако'), 'refresh', T('Сбросить соединения роутера с облаком UniFi, чтобы они пошли новым путём.')],
    ['report', T('Отчёт для помощи'), 'file', T('Обезличенный отчёт (ключи, токены и IP скрыты) — приложить к issue на GitHub.')],
  ];
  PAGES.tools = function (main) {
    const out = el('div', { class: 'out', 'aria-live': 'polite' }, el('div', { class: 'empty' }, T('Выберите инструмент — вывод появится здесь.')));
    const status = el('span', { class: 'muted small' });
    const dl = el('span');
    let lastTool = 'awg';
    const outCard = el('section', { class: 'card' }, el('div', { class: 'hd' }, icon('logs'), el('h2', null, T('Вывод')), dl, status, outTools(out, () => 'awg-' + lastTool)), out);
    let polling = null;
    async function runTool(payload, title) {
      if (polling) clearInterval(polling);
      replace(dl);
      clear(out); out.dataset.raw = '';
      lastTool = (payload.tool || payload.kind || 'tool').replace(/[^a-z0-9-]/gi, '');
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
            replace(status, el('span', { class: 'badge ' + (r.rc === 0 ? 'ok' : 'warn') }, r.rc === 0 ? T('готово') : T('код ') + r.rc));
            const m = text.match(/awg-report-\d{8}-\d{6}\.txt/);
            if (m) {
              const a = el('a', { class: 'btn sm primary', href: '/api/report/file?name=' + m[0], download: m[0] }, icon('download', 'sm'), T('Скачать отчёт'));
              replace(dl, a);
              if (payload.tool === 'report') a.click();     // отчёт сразу скачивается
            }
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
        if ((k === 'selftest-full' || k === 'switch-test') && !await confirmBox(name, k === 'switch-test' ? T('Основной канал будет «уронен» флагом на время теста. Трафик PBR ненадолго уйдёт на запасной канал.') : T('Туннели будут кратко отключены: трафик PBR остановится на несколько секунд.'), T('Запустить'))) return;
        runTool({ tool: k }, name);
      } }, icon('play', 'sm'), T('Запустить')))));
    const dom = el('input', { class: 'input', placeholder: 'youtube.com', autocapitalize: 'off', spellcheck: 'false' });
    const domGo = () => { if (dom.value.trim()) runTool({ tool: 'domain-check', domain: dom.value.trim() }, T('Проверка ') + dom.value.trim()); };
    dom.addEventListener('keydown', (e) => { if (e.key === 'Enter') domGo(); });
    const mtuSel = el('select', { class: 'input' });
    const spSel = el('select', { class: 'input' }), spSize = el('select', { class: 'input' }, [5, 10, 25, 50].map((x) => el('option', { value: x, selected: x === 10 }, x + T(' МБ'))));
    const pgSel = el('select', { class: 'input' }), pgHost = el('input', { class: 'input', value: '1.1.1.1', spellcheck: 'false', autocapitalize: 'off' });
    // ICMP часто режут провайдер или сервер туннеля: «авто» тогда меряет время TCP-подключения к :443
    const pgMode = el('select', { class: 'input', 'aria-label': T('Способ') }, el('option', { value: 'auto' }, T('авто')), el('option', { value: 'icmp' }, 'ICMP'), el('option', { value: 'tcp' }, 'TCP :443'));
    pgMode.style.width = 'auto';
    spSize.style.width = 'auto';
    const spHist = el('div');
    const loadSp = async () => {
      const r = await api('/api/speed');
      replace(spHist, r.history.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Когда')), el('th', null, T('Канал')), el('th', null, '↓'), el('th', null, '↑'), el('th', null, T('Задержка')))),
        el('tbody', null, r.history.slice(0, 8).map((x) => el('tr', null, el('td', { class: 'nowrap' }, fmtTime(x.t)), el('td', null, el('span', { class: 'mono' }, x.iface)),
          el('td', { class: 'nowrap' }, x.down_bps ? fmtBits(x.down_bps) : '—'), el('td', { class: 'nowrap' }, x.up_bps ? fmtBits(x.up_bps) : '—'), el('td', null, x.ping_ms ? x.ping_ms + T(' мс') : '—'))))) : el('div', { class: 'small muted' }, T('Замеров ещё не было')));
    };
    loadSp().catch(() => {});
    api('/api/overview').then((ov) => {
      updateChrome(ov);
      const opts = () => ov.tunnels.map((t) => el('option', { value: t.name }, t.label ? t.label + ' (' + t.name + ')' : t.name));
      replace(mtuSel, opts());
      replace(spSel, el('option', { value: 'all' }, T('все туннели и WAN')), opts(), el('option', { value: 'wan' }, T('WAN напрямую (') + (ov.wan.if || '?') + ')'));
      replace(pgSel, opts(), el('option', { value: 'wan' }, T('WAN напрямую')));
    }).catch(() => {});
    const watchDone = async () => { await new Promise((r) => setTimeout(r, 2000)); for (let i = 0; i < 300 && polling; i++) await new Promise((r) => setTimeout(r, 1000)); loadSp().catch(() => {}); };
    add(main, [
      head(T('Инструменты')),
      el('div', { class: 'grid g-2e' },
        card(T('Проверка домена'), el('div', null, el('p', { class: 'muted small' }, T('Куда пойдёт сайт, открывается ли он через туннель и напрямую, попал ли в наборы доменов.')),
          el('div', { class: 'input-group' }, dom, el('button', { class: 'btn primary', onclick: domGo }, icon('search', 'sm'), T('Проверить')))), { icon: 'globe' }),
        card(T('Подобрать и применить MTU'), el('div', null, el('p', { class: 'muted small' }, T('Найти MTU для туннеля и сразу записать его в конфиг (туннель перезапустится).')),
          el('div', { class: 'input-group' }, mtuSel, el('button', { class: 'btn', onclick: async () => {
            if (!await confirmBox(T('MTU для ') + mtuSel.value, T('Туннель будет перезапущен с новым MTU.'), T('Подобрать и применить'))) return;
            runTool({ tool: 'mtu-apply', name: mtuSel.value }, 'MTU ' + mtuSel.value);
          } }, icon('ruler', 'sm'), T('Применить')))), { icon: 'ruler' })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2e' },
        card(T('Скорость каналов'), el('div', null, el('p', { class: 'muted small' }, T('Загрузка и отдача через туннель и напрямую (speed.cloudflare.com). Сравните каналы между собой и с WAN.')),
          el('div', { class: 'input-group' }, spSel, spSize, el('button', { class: 'btn primary', onclick: () => { runTool({ tool: 'speedtest', iface: spSel.value, mb: +spSize.value }, T('Замер скорости')); watchDone(); } }, icon('activity', 'sm'), T('Замерить'))),
          el('div', { class: 'spacer' }), spHist), { icon: 'activity' }),
        card(T('Ping и трассировка'), el('div', null, el('p', { class: 'muted small' }, T('Проверить доступность адреса через выбранный туннель или напрямую.')),
          el('div', { class: 'input-group' }, pgHost, pgSel, pgMode),
          el('div', { class: 'spacer' }),
          el('div', { class: 'row' }, el('button', { class: 'btn', onclick: () => runTool({ ep: '/api/net', kind: 'ping', host: pgHost.value.trim(), iface: pgSel.value, mode: pgMode.value }, 'ping ' + pgHost.value) }, icon('activity', 'sm'), 'Ping'),
            el('button', { class: 'btn', onclick: () => runTool({ ep: '/api/net', kind: 'trace', host: pgHost.value.trim(), iface: pgSel.value }, T('трассировка ') + pgHost.value) }, icon('route', 'sm'), T('Трассировка')))), { icon: 'globe' })),
      el('div', { class: 'spacer' }),
      card(T('Сверка правил с эталоном (drift)'), el('div', null,
        el('p', { class: 'muted small' }, T('Эталон снимается после установки и обновления. Сверка покажет, какие правила iptables, ip rule, маршруты PBR и службы пропали или появились — и чьи они: набора или UniFi. «Вернуть правила набора» перезапускает только службы UDR-Amnezia; правила UniFi не трогаются никогда.')),
        el('div', { class: 'row wrap' },
          el('button', { class: 'btn primary', onclick: () => runTool({ tool: 'drift' }, T('Сверка')) }, icon('search', 'sm'), T('Сверить')),
          el('button', { class: 'btn', onclick: async () => { if (await confirmBox(T('Вернуть правила набора?'), T('Службы awg-failover, guard, self, subnets будут перезапущены (на секунды прерывается трафик PBR).'), T('Вернуть'))) runTool({ tool: 'drift-repair' }, T('Восстановление')); } }, icon('wrench', 'sm'), T('Вернуть правила набора')),
          el('button', { class: 'btn', onclick: async () => { if (await confirmBox(T('Принять текущее состояние?'), T('Текущие правила станут эталоном. Делайте это, когда всё работает (например, после изменения PBR в UniFi).'), T('Принять'))) runTool({ tool: 'drift-save' }, T('Новый эталон')); } }, icon('check', 'sm'), T('Принять текущее как эталон')))), { icon: 'layers' }),
      el('div', { class: 'spacer' }),
      tuneCard(),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-tools' }, tiles),
      el('div', { class: 'spacer' }), outCard]);
  };
  // вывод команд — в стиле страницы: строки OK/WARN/FAIL с значками, разделы заголовками, советы отдельно
  function paint(box, text) {
    clear(box);
    box.dataset.raw = text;
    let blank = false;
    for (let line of text.replace(/\x1b\[[0-9;]*m/g, '').split('\n')) {
      if (!line.trim()) { if (!blank && box.lastChild) box.appendChild(el('div', { class: 'osp' })); blank = true; continue; }
      blank = false;
      let m;
      const st = (lv, t) => box.appendChild(el('div', { class: 'ol ' + lv }, el('span', { class: 'oi' }, icon({ ok: 'check', warn: 'alert', crit: 'x', info: 'info' }[lv], 'sm')), el('span', { class: 'ot' }, TM(t))));
      if ((m = line.match(/^\s*(?:OK|ОК|✔|✓)\s+(.*)$/))) st('ok', m[1]);
      else if ((m = line.match(/^\s*(?:WARN|ВНИМАНИЕ|⚠|▲)\s+(.*)$/))) st('warn', m[1]);
      else if ((m = line.match(/^\s*(?:FAIL|ОШИБКА|✖|✗)\s+(.*)$/))) st('crit', m[1]);
      else if ((m = line.match(/^\s*(?:INFO|·)\s+(.*)$/))) st('info', m[1]);
      else if ((m = line.match(/^\s*={2,}\s*(.*?)\s*=*\s*$/)) || (m = line.match(/^(\d+\.\s+\S.*)$/)) || (m = line.match(/^--\s+(.*)$/))) box.appendChild(el('div', { class: 'oh' }, TM(m[1])));
      else if ((m = line.match(/^\s*(?:что делать|Что сделать|↳)\s*:?\s*(.*)$/i))) box.appendChild(el('div', { class: 'oadv' }, icon('chev', 'sm'), el('span', null, m[1])));
      else if (/^\s*(Итог|ИТОГ)/.test(line)) box.appendChild(el('div', { class: 'osum' }, TM(line.trim())));
      else box.appendChild(el('div', { class: 'op' }, line.replace(/^\s{0,6}/, '')));
    }
  }
  function dlText(name, text, type) {
    const a = el('a', { href: URL.createObjectURL(new Blob([text], { type: type || 'text/plain;charset=utf-8' })), download: name });
    document.body.appendChild(a); a.click(); a.remove();
  }
  function outTools(box, name) {
    return [el('button', { class: 'btn sm ghost icon', title: T('Копировать'), 'aria-label': T('Копировать'), onclick: async () => {
      try { await navigator.clipboard.writeText(box.dataset.raw || ''); ok(T('Скопировано')); } catch (e) { err(T('Браузер не дал скопировать: выделите текст вручную')); }
    } }, icon('copy', 'sm')),
    el('button', { class: 'btn sm ghost icon', title: T('Скачать'), 'aria-label': T('Скачать'), onclick: () => dlText((typeof name === 'function' ? name() : name) + '-' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '') + '.txt', box.dataset.raw || '') }, icon('download', 'sm'))];
  }

  // ===================================================================== ЖУРНАЛЫ
  const LOGS = [['events', T('События')], ['failover', T('Сторож')], ['journal', 'systemd'], ['notify', T('Уведомления')], ['bot', T('Бот')], ['install', T('Установка')], ['update', T('Обновление')], ['restore', T('Восстановление')], ['audit', T('Действия в панели')]];
  PAGES.logs = function (main, sub) {
    const cur = LOGS.some((l) => l[0] === sub) ? sub : 'events';
    add(main, [head(T('Журналы')), tabs(LOGS, cur, (id) => { location.hash = '#/logs/' + id; })]);
    if (cur === 'events') return eventsPage(main);
    const box = el('pre', { class: 'logbox' }, T('загрузка…'));
    const auto = el('input', { type: 'checkbox', checked: true });
    const n = el('select', { class: 'input' }, ['200', '500', '1000', '3000'].map((x) => el('option', { value: x }, x + T(' строк'))));
    n.style.width = 'auto'; n.style.height = '30px';
    const filt = el('input', { class: 'input', placeholder: T('фильтр'), spellcheck: 'false' });
    filt.style.height = '30px'; filt.style.maxWidth = '220px';
    let text = '';
    const show = () => {
      const f = filt.value.trim().toLowerCase();
      const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
      box.textContent = (f ? text.split('\n').filter((l) => l.toLowerCase().includes(f)).join('\n') : text) || T('(пусто)');
      if (atBottom) box.scrollTop = box.scrollHeight;
    };
    const load = async () => { text = (await api('/api/logs?kind=' + cur + '&n=' + n.value)).text; show(); };
    filt.addEventListener('input', show);
    n.addEventListener('change', load);
    main.appendChild(el('section', { class: 'card' },
      el('div', { class: 'hd' }, el('h2', null, LOGS.find((l) => l[0] === cur)[1]), filt, n,
        el('label', { class: 'switch small' }, auto, el('span', { class: 'knob' }), T('авто')),
        el('a', { class: 'btn sm', href: '/api/logs/file?kind=' + cur, download: '' }, icon('download', 'sm'), T('Скачать')),
        el('button', { class: 'btn sm icon', 'aria-label': T('Обновить'), onclick: load }, icon('refresh', 'sm'))), box));
    load().then(() => { box.scrollTop = box.scrollHeight; }).catch(err);
    every(5000, async () => { if (auto.checked) await load(); }, false);
  };
  async function eventsPage(main) {
    const stats = el('div', { class: 'grid g-kpi' });
    const list = el('div');
    const types = el('select', { class: 'input' }, el('option', { value: '' }, T('все типы')), Object.entries(EVT).map(([k, v]) => el('option', { value: k }, v[2])));
    types.style.width = 'auto'; types.style.height = '30px';
    const q = el('input', { class: 'input', placeholder: T('поиск'), spellcheck: 'false' });
    q.style.height = '30px'; q.style.maxWidth = '220px';
    let evs = [];
    const show = () => {
      const f = q.value.trim().toLowerCase();
      const xs = evs.filter((e) => (!types.value || e.type === types.value) && (!f || e.text.toLowerCase().includes(f)));
      replace(list, xs.length ? xs.slice(0, 500).map(evRow) : el('div', { class: 'empty' }, T('Нет событий')));
    };
    types.addEventListener('change', show);
    q.addEventListener('input', show);
    add(main, [stats, el('div', { class: 'spacer' }),
      el('section', { class: 'card' }, el('div', { class: 'hd' }, el('h2', null, T('События сторожа')), q, types,
        el('a', { class: 'btn sm', href: '/api/logs/file?kind=events', download: '' }, icon('download', 'sm'), T('Скачать'))), list)]);
    const st = (lbl, v, sub) => el('div', { class: 'card kpi' }, el('div', { class: 'lbl' }, lbl), el('div', { class: 'val' }, v), el('div', { class: 'sub' }, sub));
    const load = async () => {
      const r = await api('/api/events?n=3000');
      evs = r.events;
      replace(stats,
        st(T('На основном · 7 дн'), r.stats7.on_main_pct + '%', T('вне основного ') + fmtDur(r.stats7.off_main_sec)),
        st(T('На основном · 30 дн'), r.stats30.on_main_pct + '%', T('вне основного ') + fmtDur(r.stats30.off_main_sec)),
        st(T('Переключений · 7 дн'), r.stats7.switch, T('по качеству: ') + r.stats7.degrade + T(', вручную: ') + r.stats7.force),
        st(T('Оба канала лежали · 7 дн'), r.stats7.both, T('запусков сторожа: ') + r.stats7.start));
      show();
    };
    every(10000, load);
  }

  // ===================================================================== НАСТРОЙКИ
  const SET_TABS = [['failover', T('Переключение')], ['services', T('Службы')], ['telegram', 'Telegram'], ['ha', 'Home Assistant'], ['users', T('Пользователи и 2FA')], ['web', T('Панель и сертификат')], ['backups', T('Резервные копии')], ['routes', T('Маршруты')], ['vps', T('Свой VPS')], ['xui', '3x-ui'], ['system', T('Система и обновление')]];
  PAGES.settings = function (main, sub) {
    const cur = SET_TABS.some((t) => t[0] === sub) ? sub : 'failover';
    add(main, [head(T('Настройки')), tabs(SET_TABS, cur, (id) => { location.hash = '#/settings/' + id; })]);
    const body = el('div', { class: 'stack' });
    main.appendChild(body);
    ({ failover: setFailover, services: setServices, telegram: setTelegram, ha: setHa, users: setUsers, web: setWeb, backups: setBackups, routes: setRoutes, vps: setVps, xui: setXui, system: setSystem })[cur](body);
  };
  async function setFailover(body) {
    try {
      const d = await settings(true);
      add(body, [
        settingsForm(T('Переключение каналов'), 'switch', ['RECOVER_SEC', 'QUALITY', 'QUALITY_LOSS', 'QUALITY_RTT', 'MIN_DWELL'], d,
          el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Сторож проверяет каналы каждые несколько секунд (HTTPS к 1.1.1.1, 8.8.8.8, 9.9.9.9). При падении активного — уходит на следующий по приоритету; на основной возвращается после стабильной работы.')))),
        settingsForm(T('Мониторинг'), 'activity', ['METRICS_PORT'], d)]);
    } catch (e) { err(e); }
  }
  async function setServices(body) {
    const tb = el('tbody');
    const load = async () => {
      const r = await api('/api/services');
      replace(tb, Object.entries(r.services).map(([u, s]) => {
        const act = (a, label, cls) => el('button', { class: 'btn sm ' + (cls || ''), onclick: async (e) => {
          if (a === 'disable' && !await confirmBox(T('Выключить ') + u + '?', T('Служба будет остановлена и убрана из автозапуска, её правила — удалены.'), T('Выключить'), true)) return;
          await busy(e.currentTarget, async () => { try { const x = await api('/api/service', { name: u, action: a }); (x.ok ? ok : err)(x.msg); load(); } catch (ex) { err(ex); } });
        } }, label);
        return el('tr', null,
          el('td', null, el('span', { class: 'row' }, el('span', { class: 'dot ' + (s.active ? 'ok' : s.installed ? 'crit' : '') }), el('b', null, u))),
          el('td', { class: 'muted' }, TM(s.info)),
          el('td', null, s.active ? el('span', { class: 'badge ok' }, T('работает')) : s.installed ? el('span', { class: 'badge crit' }, T('стоит')) : el('span', { class: 'badge' }, T('выключена'))),
          el('td', { class: 'r nowrap' }, s.installed ? [act('restart', T('Перезапуск')), ' ', u !== 'awg-failover' ? act('disable', T('Выключить'), 'danger') : null] : (s.available ? act('enable', T('Включить'), 'primary') : el('span', { class: 'muted small' }, T('нет файла службы')))));
      }));
    };
    body.appendChild(card(T('Службы набора'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Служба')), el('th', null, T('Назначение')), el('th', null, T('Состояние')), el('th', { class: 'r' }, ''))), tb)),
      { icon: 'cpu', flush: true, right: el('a', { class: 'btn sm', href: '#/logs/journal' }, T('Журнал')) }));
    every(10000, load);
  }
  async function setTelegram(body) {
    let r;
    try { r = await api('/api/telegram'); } catch (e) { err(e); return; }
    const tok = el('input', { class: 'input mono', placeholder: r.configured ? r.token + T(' (оставьте пустым, чтобы не менять)') : '123456789:AA…', autocomplete: 'off', spellcheck: 'false' });
    const chat = el('input', { class: 'input mono', value: r.chat, placeholder: '123456789 987654321' });
    const viewers = el('input', { class: 'input mono', value: r.viewers || '', placeholder: T('пусто — никого') });
    const rt = el('input', { class: 'input mono', value: r.report_time.replace(/^(\d\d)(\d\d)$/, '$1:$2'), placeholder: '09:00' });
    const nw = el('input', { type: 'checkbox', checked: r.no_wan });
    const en = el('input', { type: 'checkbox', checked: r.notify || !r.configured });
    const bot = el('input', { type: 'checkbox', checked: r.bot });
    const res = el('div', { class: 'res hidden' });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/telegram', { token: tok.value.trim(), chat: chat.value.trim(), viewers: viewers.value.trim(), report_time: rt.value.trim(), no_wan: nw.checked, enable_notify: en.checked, enable_bot: bot.checked });
        res.textContent = x.msg; res.classList.remove('hidden'); ok(T('Сохранено')); tok.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('tg', 'sm'), T('Тестовое сообщение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/telegram/test', {}); (x.ok ? ok : err)(x.msg); } catch (e) { err(e); } }));
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    body.appendChild(card('Telegram', el('div', null,
      el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.configured ? 'ok' : '') }, r.configured ? T('настроен') : T('не настроен')),
        el('span', { class: 'badge ' + (r.notify ? 'ok' : '') }, T('уведомления: ') + (r.notify ? T('работают') : T('выкл'))),
        el('span', { class: 'badge ' + (r.bot ? 'ok' : '') }, T('бот: ') + (r.bot ? T('работает') : T('выкл')))),
      el('div', { class: 'spacer' }),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Токен бота')), tok, el('span', { class: 'hint' }, T('От @BotFather. В панели не показывается целиком.'))),
        el('div', { class: 'field' }, el('label', null, T('Администраторы (chat id)')), chat, el('span', { class: 'hint' }, T('Через пробел. Полный доступ: переключение, службы, отчёты. Свой id: напишите боту /id или @userinfobot.'))),
        el('div', { class: 'field' }, el('label', null, T('Только просмотр (chat id)')), viewers, el('span', { class: 'hint' }, T('Через пробел: видят состояние, события, роутер и получают уведомления, но ничего не меняют.'))),
        el('div', { class: 'field' }, el('label', null, T('Ежедневный отчёт')), rt, el('span', { class: 'hint' }, T('Время ЧЧ:ММ')))),
      sw(en, T('Уведомления'), T('Переключения каналов, падения, возвраты, ежедневный отчёт.')),
      sw(bot, T('Бот с кнопками'), T('Меню кнопками: состояние, каналы и переключение, события, проверки, роутер, клиенты, тишина уведомлений. Чужим чатам бот сообщает только их chat id.')),
      r.muted && r.muted.length ? el('div', { class: 'small muted' }, T('Уведомления временно выключены в чатах: ') + r.muted.join(', ')) : null,
      sw(nw, T('Не слать напрямую через WAN'), T('Если туннели лежат, уведомления не пойдут мимо VPN (тише, но можно не узнать о сбое).')),
      res), { icon: 'tg', foot: [test, save] }));
    const hc = await hooksCard();
    if (hc) body.appendChild(hc);
  }
  // вебхук и ntfy (#14): те же события, что в Telegram. Адрес вебхука, заголовок и токен ntfy в браузер не возвращаются.
  async function hooksCard() {
    let r;
    try { r = await api('/api/hooks'); } catch (e) { err(e); return null; }
    const keep = T('задан — оставьте пустым, чтобы не менять');
    const hook = el('input', { class: 'input mono', placeholder: r.hook_set ? r.hook + ' (' + keep + ')' : 'https://example.com/hook', spellcheck: 'false', autocomplete: 'off' });
    const hdr = el('input', { class: 'input mono', placeholder: r.header_set ? keep : 'Authorization: Bearer …', spellcheck: 'false', autocomplete: 'off' });
    const ntfy = el('input', { class: 'input mono', value: r.ntfy, placeholder: 'https://ntfy.sh/my-udr-topic', spellcheck: 'false' });
    const ntok = el('input', { class: 'input mono', type: 'password', placeholder: r.ntfy_token_set ? keep : T('если тема закрыта'), autocomplete: 'off' });
    const clr = (label, key) => r[key] ? el('label', { class: 'small muted' }, el('input', { type: 'checkbox', 'data-k': key }), ' ' + label) : null;
    const c1 = clr(T('убрать вебхук'), 'hook_set'), c2 = clr(T('убрать заголовок'), 'header_set'), c3 = clr(T('убрать токен'), 'ntfy_token_set');
    const on = (c) => !!(c && c.querySelector('input').checked);
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/hooks', { hook: hook.value.trim(), header: hdr.value.trim(), ntfy: ntfy.value.trim(), ntfy_token: ntok.value.trim(),
          hook_clear: on(c1), header_clear: on(c2), ntfy_token_clear: on(c3) });
        ok(x.msg.split('\n')[0]); hook.value = hdr.value = ntok.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Тестовое сообщение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/hooks/test', {}); (x.ok ? ok : err)(x.msg); } catch (e) { err(e); } }));
    return card(T('Вебхук и ntfy'), el('div', null,
      el('p', { class: 'muted small' }, T('Те же события, что в Telegram: переключения, падения, возвраты, отчёт, перезагрузка, прошивка, сбой автокопии. Отправляются обычным маршрутом роутера — подойдут адреса в LAN (Home Assistant, свой ntfy).')),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Вебхук (POST, JSON)')), hook, c1, el('span', { class: 'hint' }, T('Тело: {"source","host","level","time","text"}; level — critical, warning, ok или info.'))),
        el('div', { class: 'field' }, el('label', null, T('Заголовок вебхука')), hdr, c2, el('span', { class: 'hint' }, T('Необязательно, например для авторизации.'))),
        el('div', { class: 'field' }, el('label', null, T('ntfy: адрес темы')), ntfy, el('span', { class: 'hint' }, T('ntfy.sh или свой сервер; приоритет по важности события.'))),
        el('div', { class: 'field' }, el('label', null, T('ntfy: токен')), ntok, c3))), { icon: 'bell', foot: [test, save] });
  }
  // журнал действия на VPS (awg-vps-job): обновлять, пока идёт; итог — по «[код N]» в конце
  async function followVpsJob(box) {
    box.classList.remove('hidden');
    for (let i = 0; i < 400; i++) {
      let x;
      try { x = await api('/api/vps/job'); } catch (e) { await new Promise((ok2) => setTimeout(ok2, 3000)); continue; }
      paint(box, x.text); box.scrollTop = box.scrollHeight;
      if (!x.running) {
        const good = /\[код 0\]/.test(x.text);
        (good ? ok : err)(good ? T('Готово') : T('Не удалось — подробности в журнале ниже'));
        return good;
      }
      await new Promise((ok2) => setTimeout(ok2, 3000));
    }
    return false;
  }
  // свой VPS (#13): состояние сервера, обновление AmneziaWG, смена ключей и обфускации на обеих сторонах с откатом
  async function setVps(body) {
    let r;
    try { r = await api('/api/vps?vps=' + encodeURIComponent(S.vpsSel || 'main')); } catch (e) { S.vpsSel = 'main'; err(e); return; }
    const vid = r.vps;
    const rerender = (v) => { S.vpsSel = v; clear(body); setVps(body); };
    // несколько своих VPS (#32): выбор сервера, новый, убрать
    const pickV = el('select', { class: 'input' }, r.profiles.map((p) => el('option', { value: p.id, selected: p.id === vid },
      (p.label || (p.id === 'main' ? T('основной') : p.id)) + (p.host ? ' — ' + p.host : ''))));
    pickV.addEventListener('change', () => rerender(pickV.value));
    const addV = el('button', { class: 'btn' }, icon('plus', 'sm'), T('Добавить VPS'));
    addV.addEventListener('click', () => {
      const lb = el('input', { class: 'input', maxlength: 40, placeholder: T('например, Швеция') });
      const hs = el('input', { class: 'input mono', placeholder: '203.0.113.10', spellcheck: 'false' });
      const ps = el('input', { class: 'input mono', value: '22', inputmode: 'numeric' });
      const us = el('input', { class: 'input mono', value: 'root', spellcheck: 'false' });
      const sv = el('button', { class: 'btn primary' }, T('Добавить'));
      const m = modal(T('Ещё один свой VPS'), el('div', null, el('p', { class: 'muted small' }, T('Ключ роутера общий для всех VPS. После добавления выберите VPS в списке и нажмите «Добавить ключ роутера» или «Подключить и настроить».')),
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Название')), lb),
          el('div', { class: 'field' }, el('label', null, T('Адрес VPS')), hs),
          el('div', { class: 'field' }, el('label', null, T('Порт SSH')), ps),
          el('div', { class: 'field' }, el('label', null, T('Пользователь')), us))), [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), sv]);
      sv.addEventListener('click', () => busy(sv, async () => {
        try { const x = await api('/api/vps', { new: true, label: lb.value.trim(), host: hs.value.trim(), port: ps.value.trim(), user: us.value.trim() }); ok(x.msg); m.close(); rerender(x.vps); } catch (e) { err(e); }
      }));
    });
    const delV = el('button', { class: 'btn danger' }, T('Убрать из списка'));
    delV.addEventListener('click', async () => {
      if (!await confirmBox(T('Убрать VPS ') + (r.label || vid) + '?', T('Роутер забудет адрес этого VPS. Сервер, его туннели и ключ роутера на нём не трогаются.'), T('Убрать'), true)) return;
      try { ok((await api('/api/vps/del', { vps: vid })).msg); rerender('main'); } catch (e) { err(e); }
    });
    const vlabel = el('input', { class: 'input', value: r.label || '', maxlength: 40, placeholder: vid === 'main' ? T('основной') : '' });
    const host = el('input', { class: 'input mono', value: r.host, placeholder: r.host_default || '203.0.113.10', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', value: r.port, inputmode: 'numeric' });
    const user = el('input', { class: 'input mono', value: r.user, spellcheck: 'false' });
    const out = el('div', { class: 'out hidden' });
    const show = (text) => { paint(out, text); out.classList.remove('hidden'); };
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => { try { ok((await api('/api/vps', { vps: vid, label: vlabel.value.trim(), host: host.value.trim(), port: port.value.trim(), user: user.value.trim() })).msg); } catch (e) { err(e); } }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Проверить подключение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/vps/test', { vps: vid }); (x.ok ? ok : err)(x.ok ? T('VPS доступен') : T('VPS недоступен')); show(x.msg); } catch (e) { err(e); } }));
    const st = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Состояние сервера'));
    st.addEventListener('click', () => busy(st, async () => { try { const x = await api('/api/vps/status', { vps: vid }); show(x.text); } catch (e) { err(e); } }));
    const ver = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Проверить версии'));
    ver.addEventListener('click', () => busy(ver, async () => { try { const x = await api('/api/vps/versions', { vps: vid }); show(x.text); if (x.update) toast(T('На VPS есть что обновить')); } catch (e) { err(e); } }));
    const log = el('div', { class: 'out' + (r.log ? '' : ' hidden') });
    if (r.log) paint(log, r.log);
    const btns = [];
    async function follow() {
      btns.forEach((b) => { b.disabled = true; });
      await followVpsJob(log);
      btns.forEach((b) => { b.disabled = false; });
    }
    const lab = (n) => { const t = S.ov && S.ov.tunnels.find((x) => x.name === n); return t && t.label ? t.label + ' (' + n + ')' : n; };
    const tun = el('select', { class: 'input' }, r.tunnels.map((t) => el('option', { value: t }, lab(t))));
    const job = (action, title, text) => {
      const b = el('button', { class: 'btn' + (action === 'update' ? '' : ' danger') }, title);
      b.addEventListener('click', async () => {
        const pw = await promptPw(title + '?', text);
        if (pw == null) return;
        try { ok((await api('/api/vps/run', { vps: vid, action, tunnel: tun.value, current: pw })).msg); follow(); } catch (e) { err(e); }
      });
      btns.push(b);
      return b;
    };
    // мастер (#28): от пароля VPS до работающего туннеля
    const vpw = el('input', { class: 'input', type: 'password', autocomplete: 'off', placeholder: r.key ? T('не нужен, если ключ роутера уже на VPS') : T('пароль root на VPS — один раз') });
    const tname = el('input', { class: 'input mono', value: 'awgvps', spellcheck: 'false' });
    const aport = el('input', { class: 'input mono', value: '51823', inputmode: 'numeric' });
    const wiz = el('button', { class: 'btn primary' }, icon('server', 'sm'), T('Подключить и настроить'));
    wiz.addEventListener('click', async () => {
      if (!host.value.trim() && !r.host_default) { err(T('укажите адрес VPS')); host.focus(); return; }
      const pw = await promptPw(T('Подключить VPS?'), T('Роутер войдёт на VPS (пароль VPS — только для первого входа, не сохраняется), положит туда свой ключ, соберёт AmneziaWG из исходников amnezia-vpn (3–7 минут), создаст сервер и добавит туннель. Нужны Ubuntu или Debian и root. Существующие туннели не трогаются.'));
      if (pw == null) return;
      try {
        ok((await api('/api/vps/run', { vps: vid, label: vlabel.value.trim(), action: 'setup', host: host.value.trim(), port: port.value.trim(), user: user.value.trim(), vps_password: vpw.value,
          name: tname.value.trim(), awg_port: aport.value.trim(), current: pw })).msg);
        vpw.value = '';
        await follow();
        rerender(vid);
      } catch (e) { err(e); }
    });
    btns.push(wiz);
    const akey = el('button', { class: 'btn' }, icon('key', 'sm'), T('Добавить ключ роутера'));
    akey.addEventListener('click', async () => {
      if (!vpw.value) { err(T('введите пароль VPS')); vpw.focus(); return; }
      const pw = await promptPw(T('Добавить ключ роутера на VPS?'), T('Для VPS, где сервер уже настроен: роутер войдёт по паролю один раз и добавит свой ключ в ~/.ssh/authorized_keys. Дальше обновление, состояние, ключи и обфускация — без пароля. Сервер не меняется.'));
      if (pw == null) return;
      try {
        ok((await api('/api/vps/run', { vps: vid, label: vlabel.value.trim(), action: 'addkey', host: host.value.trim(), port: port.value.trim(), user: user.value.trim(), vps_password: vpw.value, current: pw })).msg);
        vpw.value = '';
        await follow();
      } catch (e) { err(e); }
    });
    btns.push(akey);
    const upd = job('update', T('Обновить AmneziaWG на VPS'), T('Последние релизы amnezia-vpn собираются на VPS из исходников (3–7 минут), сервер перезапускается. Если туннели к VPS не получат handshake — вернутся прежние файлы.'));
    const rk = job('rotate-keys', T('Сменить ключи'), T('Новые ключи сервера и роутера одновременно. Туннель будет недоступен 10–30 секунд (kill switch держит трафик). Не заработает — обе стороны откатятся.'));
    const ob = job('obfs', T('Новые параметры обфускации'), T('Новые Jc, Jmin, Jmax, S1, S2, H1–H4 на VPS и роутере одновременно — если провайдер начал узнавать трафик. Туннель будет недоступен 10–30 секунд; не заработает — откат.'));
    const noTun = !r.tunnels.length;
    if (noTun) { rk.disabled = true; ob.disabled = true; }
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Подключение к VPS'), el('div', null,
          el('p', { class: 'muted small' }, T('Роутер входит на ваш VPS по SSH своим ключом, без пароля. Новый VPS: укажите адрес и пароль root один раз и нажмите «Подключить и настроить» — роутер сам добавит ключ, соберёт AmneziaWG, создаст сервер и туннель.')),
          el('div', { class: 'row wrap' }, r.profiles.length > 1 ? pickV : null, addV, vid !== 'main' ? delV : null,
            el('span', { class: 'badge ' + (r.key ? 'ok' : 'warn') }, r.key ? T('ключ роутера есть') : T('ключа роутера нет'))),
          el('div', { class: 'form-grid' },
            el('div', { class: 'field' }, el('label', null, T('Название')), vlabel),
            el('div', { class: 'field' }, el('label', null, T('Адрес VPS')), host, el('span', { class: 'hint' }, r.host_default ? T('Пусто — ваш VPS из настройки: ') + r.host_default : T('IP или имя сервера'))),
            el('div', { class: 'field' }, el('label', null, T('Порт SSH')), port),
            el('div', { class: 'field' }, el('label', null, T('Пользователь')), user),
            el('div', { class: 'field' }, el('label', null, T('Пароль VPS')), vpw),
            el('div', { class: 'field' }, el('label', null, T('Имя нового туннеля')), tname),
            el('div', { class: 'field' }, el('label', null, T('Порт AmneziaWG (UDP)')), aport, el('span', { class: 'hint' }, T('Откройте его в файрволе хостера')))),
          r.pub ? el('details', { class: 'fgroup' }, el('summary', null, T('Открытый ключ роутера (для ~/.ssh/authorized_keys на VPS)')), el('pre', { class: 'res' }, r.pub)) : null,
          out, log), { icon: 'server', foot: [test, save, akey, wiz] }),
        card(T('Сервер и AmneziaWG'), el('div', null,
          el('p', { class: 'muted small' }, T('Состояние — только чтение: служба awg-server, handshake роутера, NAT, файрвол, права на ключи, нагрузка и место. Обновление — только из официальных исходников amnezia-vpn.'))),
        { icon: 'activity', foot: [st, ver, upd] })),
      card(T('Ключи и обфускация'), el('div', null,
        el('p', { class: 'muted small' }, noTun ? T('Нет туннеля, у которого Endpoint — этот VPS и сервер — awg-server: менять можно только свой сервер, не сервер провайдера. Туннели через 3x-ui меняются на вкладке 3x-ui («Обновить из 3x-ui»).')
          : T('Меняется туннель к вашему VPS одновременно на обеих сторонах; перед изменением делаются копии, при неудаче всё откатывается само.')),
        noTun ? null : el('div', { class: 'field' }, el('label', null, T('Туннель')), tun)), { icon: 'key', foot: [rk, ob] })]);
    if (r.running) follow();
  }
  // Home Assistant (#5): MQTT discovery — HA сам находит устройство, датчики, выбор канала и кнопки
  async function setHa(body) {
    let r;
    try { r = await api('/api/ha'); } catch (e) { err(e); return; }
    const host = el('input', { class: 'input mono', value: r.host, placeholder: '192.168.1.10', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', value: r.port, inputmode: 'numeric' });
    const user = el('input', { class: 'input mono', value: r.user, autocomplete: 'off', spellcheck: 'false' });
    const pass = el('input', { class: 'input', type: 'password', autocomplete: 'new-password', placeholder: r.pass_set ? T('задан — оставьте пустым, чтобы не менять') : '' });
    const tls = el('select', { class: 'input' }, el('option', { value: 'no' }, T('без TLS (1883)')), el('option', { value: 'yes' }, T('TLS с проверкой сертификата (8883)')), el('option', { value: 'insecure' }, T('TLS без проверки (самоподписанный)')));
    tls.value = r.tls;
    const prefix = el('input', { class: 'input mono', value: r.prefix });
    const interval = el('input', { class: 'input mono', value: r.interval, inputmode: 'numeric' });
    const en = el('input', { type: 'checkbox', checked: r.enabled || !r.host });
    const rb = el('input', { type: 'checkbox', checked: r.allow_reboot });
    const logBox = el('pre', { class: 'res' + (r.log ? '' : ' hidden') }, r.log || '');
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/ha', { host: host.value.trim(), port: port.value.trim(), user: user.value.trim(), pass: pass.value, tls: tls.value,
          prefix: prefix.value.trim(), interval: interval.value.trim(), allow_reboot: rb.checked, enabled: en.checked });
        (x.ok ? ok : err)(x.msg); pass.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Проверить подключение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/ha/test', {}); (x.ok ? ok : err)(x.msg); logBox.textContent = x.msg; logBox.classList.remove('hidden'); } catch (e) { err(e); } }));
    body.appendChild(card('Home Assistant', el('div', null,
      el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.active ? 'ok' : '') }, r.active ? T('работает') : r.enabled ? T('не работает') : T('выкл'))),
      el('p', { class: 'muted small' }, T('Через MQTT discovery: в Home Assistant с интеграцией MQTT появится устройство «UDR-Amnezia» — активный канал, связь, handshake, RTT, потери и трафик туннелей, kill switch, процессор, память, температура; выбор канала (авто или туннель) и перезапуск туннелей.')),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Брокер MQTT')), host, el('span', { class: 'hint' }, T('Адрес Mosquitto или брокера Home Assistant в LAN'))),
        el('div', { class: 'field' }, el('label', null, T('Порт')), port),
        el('div', { class: 'field' }, el('label', null, T('Логин')), user),
        el('div', { class: 'field' }, el('label', null, T('Пароль')), pass),
        el('div', { class: 'field' }, el('label', null, 'TLS'), tls),
        el('div', { class: 'field' }, el('label', null, T('Префикс discovery')), prefix, el('span', { class: 'hint' }, T('Как в настройках MQTT в HA (обычно homeassistant)'))),
        el('div', { class: 'field' }, el('label', null, T('Период, с')), interval, el('span', { class: 'hint' }, T('Как часто отправлять состояние: 10–600')))),
      sw(en, T('Служба awg-ha'), T('Публикует состояние и принимает команды из Home Assistant.')),
      sw(rb, T('Кнопка «Перезагрузить роутер» в HA'), T('Выключено по умолчанию: любой, кто может писать в брокер MQTT, сможет перезагрузить роутер.')),
      logBox), { icon: 'activity', foot: [test, save] }));
  }
  async function setUsers(body) {
    let r;
    try { r = await api('/api/users'); } catch (e) { err(e); return; }
    const me = r.users.find((u) => u.me) || { name: S.user, totp: false };
    const list = el('tbody', null, r.users.map((u) => el('tr', null,
      el('td', null, el('b', null, u.name), u.me ? el('span', { class: 'badge accent' }, T('вы')) : null),
      el('td', null, u.totp ? el('span', { class: 'badge ok' }, '2FA') : el('span', { class: 'badge' }, T('без 2FA'))),
      el('td', { class: 'r' }, u.me ? null : el('button', { class: 'btn sm danger', onclick: async () => {
        const pw = await promptPw(T('Удалить ') + u.name + '?', T('Пользователь будет удалён, его сеансы закрыты.'));
        if (pw == null) return;
        try { await api('/api/user/delete', { user: u.name, current: pw }); ok(T('Удалён')); location.reload(); } catch (e) { err(e); }
      } }, T('Удалить'))))));
    const un = el('input', { class: 'input', value: S.user, autocapitalize: 'off', spellcheck: 'false', autocomplete: 'username' });
    const p1 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const p2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const cur = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      if (p1.value !== p2.value) { err(T('пароли не совпадают')); return; }
      try { const x = await api('/api/passwd', { user: un.value.trim(), password: p1.value, current: cur.value }); ok(x.msg); p1.value = p2.value = cur.value = ''; setTimeout(() => location.reload(), 800); } catch (e) { err(e); }
    }));
    const tf = el('div');
    const totpView = () => {
      if (me.totp) {
        const off = el('button', { class: 'btn danger' }, T('Выключить 2FA'));
        off.addEventListener('click', async () => {
          const pw = await promptPw(T('Выключить 2FA?'), T('Вход будет только по паролю.'));
          if (pw == null) return;
          try { await api('/api/totp/disable', { current: pw }); me.totp = false; ok(T('2FA выключена')); totpView(); } catch (e) { err(e); }
        });
        replace(tf, el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Второй фактор включён: при входе нужен код из приложения.'))), el('div', { class: 'spacer' }), off);
      } else {
        const on = el('button', { class: 'btn primary' }, icon('key', 'sm'), T('Включить 2FA'));
        on.addEventListener('click', async () => {
          let b;
          try { b = await api('/api/totp/begin', {}); } catch (e) { err(e); return; }
          const code = el('input', { class: 'input mono', inputmode: 'numeric', maxlength: 6, placeholder: '000000', autocomplete: 'one-time-code' });
          let qr = null;
          try { qr = qrSvg(b.uri); } catch (e) { qr = null; }
          const go = async () => {
            try { await api('/api/totp/enable', { secret: b.secret, code: code.value }); me.totp = true; m.close(); ok(T('2FA включена')); totpView(); } catch (e) { err(e); }
          };
          code.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
          const m = modal(T('Включить 2FA'), el('div', null,
            el('p', null, T('Отсканируйте код в Google Authenticator, Aegis, 1Password или другом приложении TOTP, затем введите 6 цифр.')),
            qr, el('div', { class: 'secret-box' }, b.secret.replace(/(.{4})/g, '$1 ').trim()),
            el('div', { class: 'small muted' }, T('Если камеры нет — введите ключ вручную (тип: по времени, 6 цифр, 30 с).')),
            el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, T('Код из приложения')), code),
            el('div', { class: 'small muted' }, T('Потеряли телефон — на роутере: '), el('code', null, 'python3 /data/awg/web/panel.py totp-off ' + S.user))),
          [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), el('button', { class: 'btn primary', onclick: go }, T('Включить'))], { sticky: true });
          setTimeout(() => code.focus(), 50);
        });
        replace(tf, el('p', { class: 'muted' }, T('Код из приложения на телефоне в дополнение к паролю. Рекомендуется, если панель открывают несколько человек или в LAN есть гостевые устройства.')), on);
      }
    };
    totpView();
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Пользователи'), el('table', { class: 'tbl' }, list), { icon: 'users', flush: true }),
        card(T('Двухфакторная защита (') + S.user + ')', tf, { icon: 'key' })),
      card(T('Пароль: сменить свой или добавить пользователя'), el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Имя пользователя')), un, el('span', { class: 'hint' }, T('Новое имя — новый пользователь'))),
        el('div', { class: 'field' }, el('label', null, T('Новый пароль')), p1, el('span', { class: 'hint' }, T('Не короче 10 символов'))),
        el('div', { class: 'field' }, el('label', null, T('Повторите')), p2),
        el('div', { class: 'field' }, el('label', null, T('Ваш текущий пароль')), cur)), { icon: 'lock', foot: save }),
      await sessionsCard(), await tokensCard()]);
  }
  // токены API (#6): для Home Assistant, скриптов, мониторинга. Сам токен показывается один раз.
  const tokHint = (p) => { p.style.padding = '0 16px'; return p; };   // через CSSOM: атрибут style запрещён CSP
  async function tokensCard() {
    const tb = el('tbody');
    const ROLE_T = { read: T('только чтение'), admin: T('управление') };
    const load = async () => {
      const r = await api('/api/tokens');
      replace(tb, r.tokens.length ? r.tokens.map((x) => el('tr', null,
        el('td', null, el('b', null, x.name), ' ', el('span', { class: 'badge ' + (x.role === 'admin' ? 'warn' : 'outline') }, ROLE_T[x.role] || x.role),
          x.expired ? el('span', { class: 'badge crit' }, T('истёк')) : null,
          el('div', { class: 'small muted' }, T('создал ') + x.user + ' · ' + fmtTime(x.created) + (x.expires ? T(' · до ') + fmtTime(x.expires) : T(' · бессрочно')))),
        el('td', { class: 'nowrap' }, x.last_used ? [fmtAge(Math.floor(Date.now() / 1000) - x.last_used), el('div', { class: 'small muted mono' }, x.last_ip)] : el('span', { class: 'muted' }, T('не использовался'))),
        el('td', { class: 'r' }, el('button', { class: 'btn sm danger', onclick: async () => {
          if (!await confirmBox(T('Отозвать токен?'), T('Всё, что пользуется токеном «') + x.name + T('», перестанет получать доступ.'), T('Отозвать'), true)) return;
          try { await api('/api/token/revoke', { id: x.id }); ok(T('Токен отозван')); load(); } catch (e) { err(e); }
        } }, T('Отозвать'))))) : el('tr', null, el('td', { class: 'muted' }, T('Токенов нет'))));
    };
    load().catch(err);
    const add = el('button', { class: 'btn sm primary', onclick: () => {
      const nm = el('input', { class: 'input', maxlength: 40, placeholder: 'home-assistant' });
      const role = el('select', { class: 'input' }, el('option', { value: 'read' }, T('только чтение')), el('option', { value: 'admin' }, T('управление (переключение каналов, службы, инструменты)')));
      const days = el('select', { class: 'input' }, [[0, T('бессрочно')], [30, T('30 дней')], [90, T('90 дней')], [365, T('1 год')]].map(([v, t]) => el('option', { value: v }, t)));
      const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = el('button', { class: 'btn primary' }, T('Создать'));
      const m = modal(T('Новый токен API'), el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Название')), nm, el('span', { class: 'hint' }, T('Кто будет пользоваться: home-assistant, grafana…'))),
        el('div', { class: 'field' }, el('label', null, T('Права')), role, el('span', { class: 'hint' }, T('Пароли, сеансы, токены, ключи туннелей, перезагрузка и настройки панели недоступны токену никогда.'))),
        el('div', { class: 'field' }, el('label', null, T('Срок')), days),
        el('div', { class: 'field' }, el('label', null, T('Ваш текущий пароль')), pw)), [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), go]);
      go.addEventListener('click', () => busy(go, async () => {
        try {
          const x = await api('/api/token/create', { name: nm.value.trim(), role: role.value, days: +days.value, current: pw.value });
          m.close(); load();
          const box = el('input', { class: 'input mono', readonly: 'readonly', value: x.token });
          const cp = el('button', { class: 'btn primary', onclick: async () => { try { await navigator.clipboard.writeText(x.token); ok(T('Скопировано')); } catch (e) { box.select(); } } }, icon('copy', 'sm'), T('Копировать'));
          modal(T('Токен создан'), el('div', { class: 'stack' },
            el('div', { class: 'alert warn' }, icon('key'), el('div', null, T('Скопируйте токен сейчас: повторно он не показывается. Храните как пароль.'))), box,
            el('p', { class: 'small muted' }, T('Пример: '), el('code', null, 'curl -k -H "Authorization: Bearer ' + x.token.slice(0, 8) + '…" https://' + location.host + '/api/overview'))),
          [cp], { sticky: true });
          setTimeout(() => box.select(), 50);
        } catch (e) { err(e); }
      }));
    } }, icon('plus', 'sm'), T('Создать токен'));
    return card(T('Токены API'), el('div', null, tokHint(el('p', { class: 'muted small' }, T('Для Home Assistant, скриптов и мониторинга: заголовок Authorization: Bearer <токен>. Доступ только из локальной сети.'))),
      el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb))), { icon: 'key', flush: true, right: add });
  }
  async function sessionsCard() {
    const tb = el('tbody');
    const idle = el('input', { class: 'input mono', inputmode: 'numeric' });
    const mx = el('input', { class: 'input mono', inputmode: 'numeric' });
    const load = async () => {
      const r = await api('/api/sessions');
      if (document.activeElement !== idle && document.activeElement !== mx) { idle.value = r.idle; mx.value = r.max; }
      replace(tb, r.sessions.map((x) => el('tr', null,
        el('td', null, el('b', null, x.user), x.me ? el('span', { class: 'badge accent' }, T('этот')) : null, el('div', { class: 'small muted' }, (x.ua || '').replace(/\(.*?\)/g, '').slice(0, 60))),
        el('td', null, el('span', { class: 'mono' }, x.ip)),
        el('td', { class: 'nowrap' }, T('вход ') + fmtTime(x.born), el('div', { class: 'small muted' }, T('активность ') + fmtAge(Math.floor(Date.now() / 1000) - x.seen))),
        el('td', { class: 'r' }, x.me ? null : el('button', { class: 'btn sm danger', onclick: async () => { try { await api('/api/session/revoke', { id: x.id }); load(); } catch (e) { err(e); } } }, T('Завершить'))))));
    };
    load().catch(err);
    const all = el('button', { class: 'btn sm', onclick: async () => { try { await api('/api/session/revoke', { id: 'others' }); ok(T('Остальные сеансы завершены')); load(); } catch (e) { err(e); } } }, T('Завершить остальные'));
    // время жизни сеансов (#21)
    const lsave = el('button', { class: 'btn sm' }, T('Сохранить'));
    lsave.addEventListener('click', async () => {
      const pw = await promptPw(T('Время жизни сеансов'), T('Сеансы, вышедшие за новые пределы, закроются (и этот тоже, если он старше).'));
      if (pw == null) return;
      try { ok((await api('/api/sessions/config', { idle: idle.value.trim(), max: mx.value.trim(), current: pw })).msg); load(); } catch (e) { err(e); }
    });
    idle.style.width = mx.style.width = '6em';
    const lim = el('div', { class: 'row wrap small' }, T('Выход без активности через'), idle, T('мин; не дольше'), mx, T('ч с момента входа'), lsave);
    lim.style.padding = '8px 16px';
    return card(T('Активные сеансы'), el('div', null, lim, el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb))), { icon: 'key', flush: true, right: all });
  }
  async function setBackups(body) {
    const tb = el('tbody');
    const load = async () => {
      const r = await api('/api/backups');
      replace(tb, r.backups.length ? r.backups.map((b) => el('tr', null,
        el('td', null, el('span', { class: 'mono' }, b.name)),
        el('td', null, fmtTime(b.time, true)),
        el('td', null, fmtBytes(b.size)),
        el('td', null, b.enc ? el('span', { class: 'badge ok' }, T('зашифрована')) : el('span', { class: 'badge warn' }, T('без пароля'))),
        el('td', { class: 'r nowrap' }, el('button', { class: 'btn sm', onclick: () => {
          const pw = el('input', { class: 'input', type: 'password', autocomplete: 'off' });
          const out = el('div', { class: 'res hidden' });
          const go = el('button', { class: 'btn primary' }, T('Проверить'));
          go.addEventListener('click', () => busy(go, async () => { try { const x = await api('/api/backup/verify', { name: b.name, password: pw.value }); out.textContent = x.msg; out.classList.remove('hidden'); (x.ok ? ok : err)(x.ok ? T('Копия читается') : T('Копия не прошла проверку')); } catch (e) { err(e); } }));
          const vm = modal(T('Проверить ') + b.name, el('div', null, el('p', { class: 'muted small' }, T('Копия расшифровывается во временный файл и проверяется целостность архива; на роутере ничего не меняется.')),
            b.enc ? el('div', { class: 'field' }, el('label', null, T('Пароль копии')), pw) : null, out), [el('button', { class: 'btn', onclick: () => vm.close() }, T('Закрыть')), go]);
        } }, icon('okc', 'sm'), T('Проверить')), ' ',
          el('a', { class: 'btn sm', href: '/api/backup/file?name=' + encodeURIComponent(b.name), download: b.name }, icon('download', 'sm'), T('Скачать')), ' ',
          el('button', { class: 'btn sm danger icon', 'aria-label': T('Удалить'), onclick: async () => {
            if (!await confirmBox(T('Удалить копию?'), b.name, T('Удалить'), true)) return;
            try { await api('/api/backup/delete', { name: b.name }); load(); } catch (e) { err(e); }
          } }, icon('trash', 'sm'))))) : el('tr', null, el('td', { class: 'empty', colspan: 5 }, T('Копий пока нет'))));
    };
    const p1 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const p2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const mk = el('button', { class: 'btn primary' }, icon('archive', 'sm'), T('Создать копию'));
    const res = el('div', { class: 'res hidden' });
    mk.addEventListener('click', () => busy(mk, async () => {
      if (p1.value !== p2.value) { err(T('пароли не совпадают')); return; }
      try { const x = await api('/api/backup/create', { password: p1.value }); res.textContent = x.msg; res.classList.remove('hidden'); (x.ok ? ok : err)(x.ok ? T('Копия создана') : T('Ошибка')); p1.value = p2.value = ''; load(); } catch (e) { err(e); }
    }));
    add(body, [
      card(T('Новая копия'), el('div', null, el('p', { class: 'muted' }, T('В копию входят конфиги туннелей с ключами, awg.env, Telegram и пользователи панели. Она шифруется паролем — храните его отдельно. Восстановление: install.sh → Резервная копия.')),
        el('div', { class: 'form-grid' }, el('div', { class: 'field' }, el('label', null, T('Пароль копии')), p1), el('div', { class: 'field' }, el('label', null, T('Повторите')), p2)), res), { icon: 'archive', foot: mk }),
      await autoBackupCard(load),
      card(T('Копии на роутере'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Файл')), el('th', null, T('Создана')), el('th', null, T('Размер')), el('th', null, ''), el('th', null, ''))), tb)), { icon: 'archive', flush: true })]);
    load().catch(err);
  }
  // автокопия вне роутера (#12): по расписанию, шифрованная, на свой VPS (scp ключом роутера) и/или документом в Telegram
  async function autoBackupCard(reloadList) {
    let r;
    try { r = await api('/api/backup/auto'); } catch (e) { err(e); return null; }
    const sched = el('select', { class: 'input' }, el('option', { value: 'no' }, T('выключена')), el('option', { value: 'daily' }, T('ежедневно, ночью')), el('option', { value: 'weekly' }, T('еженедельно, в воскресенье ночью')));
    sched.value = r.auto;
    const keep = el('input', { class: 'input mono', value: r.keep, inputmode: 'numeric' });
    const pass = el('input', { class: 'input', type: 'password', autocomplete: 'new-password', placeholder: r.pass_set ? T('задан — оставьте пустым, чтобы не менять') : T('не короче 8 символов') });
    const pass2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const vps = el('input', { type: 'checkbox', checked: r.vps });
    const host = el('input', { class: 'input mono', value: r.vps_host, placeholder: r.vps_host_default || 'vps.example.com', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', value: r.vps_port, inputmode: 'numeric' });
    const user = el('input', { class: 'input mono', value: r.vps_user, spellcheck: 'false' });
    const dir = el('input', { class: 'input mono', value: r.vps_dir, spellcheck: 'false' });
    const vkeep = el('input', { class: 'input mono', value: r.vps_keep, inputmode: 'numeric' });
    const tg = el('input', { type: 'checkbox', checked: r.tg, disabled: !r.tg_ready && !r.tg });
    const out = el('pre', { class: 'res hidden' });
    const hist = el('tbody');
    const paintHist = (h) => replace(hist, h.length ? h.map((x) => el('tr', null,
      el('td', { class: 'nowrap' }, fmtTime(x.time, true)),
      el('td', null, el('span', { class: 'badge ' + (x.ok ? 'ok' : 'crit') }, x.ok ? T('успешно') : T('ошибка'))),
      el('td', { class: 'small' }, x.msg))) : el('tr', null, el('td', { class: 'empty', colspan: 3 }, T('Автокопия ещё не запускалась'))));
    paintHist(r.history);
    const vpsBox = el('div', { class: 'form-grid' + (r.vps ? '' : ' hidden') },
      el('div', { class: 'field' }, el('label', null, T('Адрес VPS')), host, el('span', { class: 'hint' }, r.vps_host_default ? T('Пусто — ваш VPS из настройки: ') + r.vps_host_default : T('IP или имя сервера'))),
      el('div', { class: 'field' }, el('label', null, T('Порт SSH')), port),
      el('div', { class: 'field' }, el('label', null, T('Пользователь')), user),
      el('div', { class: 'field' }, el('label', null, T('Папка на VPS')), dir),
      el('div', { class: 'field' }, el('label', null, T('Хранить на VPS, копий')), vkeep));
    vps.addEventListener('change', () => vpsBox.classList.toggle('hidden', !vps.checked));
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      if (pass.value !== pass2.value) { err(T('пароли не совпадают')); return; }
      try {
        const x = await api('/api/backup/auto', { auto: sched.value, keep: keep.value.trim(), pass: pass.value, vps: vps.checked, vps_host: host.value.trim(), vps_port: port.value.trim(),
          vps_user: user.value.trim(), vps_dir: dir.value.trim(), vps_keep: vkeep.value.trim(), tg: tg.checked });
        (x.ok ? ok : err)(x.msg); if (pass.value) r.pass_set = true; pass.value = pass2.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Проверить VPS'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/backup/auto/test', {}); (x.ok ? ok : err)(x.ok ? T('VPS доступен') : T('VPS недоступен')); out.textContent = x.msg; out.classList.remove('hidden'); } catch (e) { err(e); } }));
    const now = el('button', { class: 'btn' }, icon('archive', 'sm'), T('Сделать сейчас'));
    now.addEventListener('click', () => busy(now, async () => {
      try {
        ok((await api('/api/backup/auto/run', {})).msg);
        const before = r.history.length ? r.history[0].time : 0;
        for (let i = 0; i < 45; i++) {
          await new Promise((ok2) => setTimeout(ok2, 2000));
          const x = await api('/api/backup/auto');
          if (x.history.length && x.history[0].time !== before && !x.running) { r.history = x.history; paintHist(x.history); (x.history[0].ok ? ok : err)(x.history[0].ok ? T('Автокопия готова') : T('Автокопия не удалась')); reloadList().catch(err); return; }
        }
      } catch (e) { err(e); }
    }));
    return card(T('Автокопия вне роутера'), el('div', null,
      el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.timer ? 'ok' : '') }, r.timer ? T('по расписанию') : T('расписание выключено')),
        el('span', { class: 'badge ' + (r.pass_set ? 'ok' : 'warn') }, r.pass_set ? T('пароль задан') : T('пароль не задан'))),
      el('p', { class: 'muted small' }, T('Копия шифруется паролем автокопии, после создания проверяется расшифровкой и отправляется на ваш VPS и/или в Telegram администраторам. Пароль хранится на роутере (файл 600) — запишите его отдельно: без него копию не открыть, а при потере роутера он пропадёт вместе с ним.')),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Расписание')), sched, el('span', { class: 'hint' }, T('Около 04:20–05:00; пропущенный запуск выполнится после включения роутера'))),
        el('div', { class: 'field' }, el('label', null, T('Хранить на роутере, копий')), keep),
        el('div', { class: 'field' }, el('label', null, T('Пароль автокопии')), pass),
        el('div', { class: 'field' }, el('label', null, T('Повторите')), pass2)),
      sw(vps, T('На свой VPS'), r.key ? T('По SSH ключом роутера (создаётся установщиком при настройке VPS). Сумма файла сверяется на сервере.') : T('Ключа роутера нет: запустите install.sh → VPS или добавьте ключ вручную.')),
      vpsBox,
      sw(tg, T('В Telegram'), r.tg_ready ? T('Файлом администраторам бота (TG_CHAT); «только просмотр» копии не получают.') : T('Сначала настройте Telegram.')),
      out,
      el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Запуск')), el('th', null, ''), el('th', null, T('Итог')))), hist))),
    { icon: 'archive', foot: [now, test, save] });
  }
  async function setSystem(body) {
    let r;
    try { r = await api('/api/system'); } catch (e) { err(e); return; }
    const upd = el('div');
    const log = el('div', { class: 'out hidden' });
    const chk = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Проверить обновления'));
    // канал обновлений (#8): stable — релизы с проверкой SHA256, beta — ветка main, своя ветка — для проверки до слияния
    const chanLabel = (u) => (u.channel === 'stable' ? T('канал stable') + (u.kind === 'tag' ? ', ' + T('релиз ') + u.ref : ', ' + T('релизов нет — ветка main'))
      : u.channel === 'beta' ? T('канал beta, ветка main') : T('ветка ') + u.branch);
    const chSel = el('select', { class: 'input', 'aria-label': T('Канал обновлений') },
      el('option', { value: 'stable' }, T('stable — проверенные релизы')), el('option', { value: 'beta' }, T('beta — ветка main')));
    chSel.style.width = 'auto';
    if (r.channel === 'branch') chSel.appendChild(el('option', { value: 'branch' }, T('ветка ') + r.branch));
    chSel.value = r.channel || 'stable';
    chSel.addEventListener('change', async () => {
      if (chSel.value === 'branch') return;
      try { ok((await api('/api/update/channel', { channel: chSel.value })).msg); replace(upd); } catch (e) { err(e); }
    });
    async function followUpdate() {
      log.classList.remove('hidden');
      let lost = 0;
      for (let i = 0; i < 600; i++) {
        await new Promise((ok2) => setTimeout(ok2, 2000));
        try {
          const x = await api('/api/update/log');
          paint(log, x.text); log.scrollTop = log.scrollHeight;
          if (lost) { lost = 0; toast(T('Панель снова на связи')); }
          if (!x.running && i > 2) {
            const good = /\[код 0\]/.test(x.text);
            replace(upd, el('div', { class: 'alert ' + (good ? 'ok' : 'crit') }, icon(good ? 'okc' : 'alert'), el('div', null,
              good ? T('Обновление завершено: версия ') + x.version + T('. Страница перезагрузится.') : T('Обновление завершилось с ошибкой (при сбое выполнен откат). Журнал — ниже и в «Журналах → Обновление».'))));
            if (good) setTimeout(() => location.reload(), 4000);
            return;
          }
        } catch (e) {
          lost++;
          if (lost === 1) replace(upd, el('div', { class: 'alert info' }, el('span', { class: 'spinner sm' }), el('div', null, T('Панель перезапускается после обновления — жду, когда она вернётся…'))));
        }
      }
    }
    chk.addEventListener('click', () => busy(chk, async () => {
      try {
        const u = await api('/api/update/check', {});
        if (u.running) { replace(upd, el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Обновление уже идёт.')))); followUpdate(); return; }
        const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), T('Обновить до ') + u.latest);
        go.addEventListener('click', async () => {
          if (!await confirmBox(T('Обновить до ') + u.latest + '?', T('Перед обновлением делается копия скриптов. Службы перезапустятся (несколько секунд без трафика PBR). Если после обновления сторож, маршрут или панель не заработают — автоматически вернётся прежняя версия.'), T('Обновить'))) return;
          try { ok((await api('/api/update/run', {})).msg); go.disabled = true; followUpdate(); } catch (e) { err(e); }
        });
        replace(upd, u.latest ? (u.update ? el('div', null, el('div', { class: 'alert info' }, icon('download'), el('div', null, T('Доступна версия '), el('b', null, u.latest), T(' (у вас ') + u.current + ', ' + chanLabel(u) + ').')),
          u.notes ? el('details', { class: 'fgroup' }, el('summary', null, T('Что нового')), el('pre', { class: 'res' }, u.notes)) : null,
          el('div', { class: 'spacer' }), go, el('div', { class: 'small muted' }, T('Или по SSH: '), el('code', null, u.cmd)))
          : u.older ? el('div', null, el('div', { class: 'alert info' }, icon('info'), el('div', null, T('У вас ') + u.current + T(' — новее, чем в выбранном канале (') + chanLabel(u) + ', ' + u.latest + T('). Обновлять нечего; откат на старую версию — только вручную по SSH: '), el('code', null, u.cmd))))
          : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Установлена последняя версия ') + u.current + ' (' + chanLabel(u) + ').')))
          : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('Не удалось узнать последнюю версию в ') + u.repo + T(' (GitHub недоступен с роутера?)'))));
      } catch (e) { err(e); }
    }));
    // бинарники AmneziaWG против последних официальных релизов amnezia-vpn (#11); обновление из панели (#29)
    const bup = el('div');
    const blog = el('div', { class: 'out hidden' });
    const binsUpdateBtn = () => {
      const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), T('Обновить на роутере'));
      go.addEventListener('click', async () => {
        const pw = await promptPw(T('Обновить AmneziaWG на роутере?'), T('Последние релизы amnezia-vpn собираются на вашем VPS (3–7 минут), затем туннели пересоздаются на новых файлах (несколько секунд без трафика PBR). Если handshake не появится — вернутся прежние файлы.'));
        if (pw == null) return;
        try { ok((await api('/api/vps/run', { action: 'router-bins', current: pw })).msg); go.disabled = true; await followVpsJob(blog); go.disabled = false; } catch (e) { err(e); }
      });
      return el('div', { class: 'row' }, go);
    };
    const bchk = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Проверить AmneziaWG'));
    bchk.addEventListener('click', () => busy(bchk, async () => {
      try {
        const b = await api('/api/bins/check', { force: true });
        const row = (x) => el('li', null, el('b', null, x.name), ': ' + (x.installed || T('версия не определяется')) + ' → ',
          x.state === 'unknown' ? T('релиз не узнать') : x.state === 'ok' ? T('последняя ') + x.latest : el('b', null, x.latest), ' ',
          el('span', { class: 'muted small' }, '(' + x.repo + ')'));
        const list = el('ul', { class: 'small blist' }, b.items.map(row));
        replace(bup, b.items.some((x) => x.state === 'unknown')
          ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('Не удалось узнать последние релизы на github.com/amnezia-vpn (GitHub недоступен с роутера?)'), list))
          : b.update
            ? el('div', { class: 'alert info' }, icon('download'), el('div', null, T('Есть новые официальные релизы AmneziaWG.'), list,
              el('div', { class: 'small muted' }, T('Обновление собирает файлы из исходников amnezia-vpn на вашем VPS и проверяет handshake; если туннели не поднимутся — вернутся прежние. По SSH: '), el('code', null, b.cmd)),
              b.vps_ready ? binsUpdateBtn() : el('div', { class: 'small' }, T('Для обновления из панели подключите свой VPS: «Настройки → Свой VPS».'))))
            : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Бинарники AmneziaWG актуальны.'), list)));
      } catch (e) { err(e); }
    }));
    const kv = (rows) => el('dl', { class: 'kv' }, rows.map(([k, v]) => [el('dt', null, k), el('dd', null, v)]));
    const exp = el('button', { class: 'btn' }, icon('download', 'sm'), T('Экспорт настроек'));
    exp.addEventListener('click', async () => {
      try {
        const x = await api('/api/settings/export');
        const a = el('a', { href: URL.createObjectURL(new Blob([JSON.stringify(x, null, 1)], { type: 'application/json' })), download: 'udr-amnezia-settings.json' });
        document.body.appendChild(a); a.click(); a.remove();
      } catch (e) { err(e); }
    });
    const imp = el('button', { class: 'btn' }, icon('upload', 'sm'), T('Импорт настроек'));
    imp.addEventListener('click', () => {
      const m = modal(T('Импорт настроек'), el('div', null, el('p', { class: 'muted small' }, T('Файл udr-amnezia-settings.json с другого роутера или сохранённый ранее: домены, исключения, защита, параметры переключения, названия туннелей. Ключей и паролей в нём нет.')),
        dropZone(async (txt) => {
          let data;
          try { data = JSON.parse(txt); } catch (e) { err(T('это не JSON')); return; }
          const pw = await promptPw(T('Импортировать настройки?'), T('Текущие настройки маршрутизации и переключения будут заменены значениями из файла.'));
          if (pw == null) return;
          try { const x = await api('/api/settings/import', { data, current: pw }); ok(x.msg.split('\n')[0]); m.close(); } catch (e) { err(e); }
        }, 'udr-amnezia-settings.json')), []);
    });
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Версии и обновление'), el('div', null, kv([[T('Набор'), r.version || '?'], [T('Установщик'), r.installer], [T('Панель'), r.panel], ['awg', r.awg], ['amneziawg-go', r.amneziawg_go], ['Python', r.python], [T('Свободно в /data'), r.data_free_mb + T(' МБ')], [T('Канал обновлений'), chSel]]),
          el('div', { class: 'spacer' }), upd, bup, blog, log), { icon: 'info', foot: [chk, bchk] }),
        card(T('Перенос настроек'), el('div', null, el('p', { class: 'muted small' }, T('Настройки без секретов в файл JSON: перенести на другой роутер или сохранить перед экспериментами. Конфиги туннелей переносятся отдельно (Туннели → Настроить → Экспорт) или резервной копией.'))),
          { icon: 'archive', foot: [exp, imp] }))]);
  }
  async function setWeb(body) {
    let r;
    try { r = await api('/api/web'); } catch (e) { err(e); return; }
    const port = el('input', { class: 'input mono', value: r.port, inputmode: 'numeric' });
    const allow = el('input', { class: 'input mono', value: r.allow });
    const hosts = el('input', { class: 'input mono', value: r.hosts, placeholder: 'udr.example.com' });
    const cm = el('select', { class: 'input' }, [['auto', T('Автоматически: сертификат UniFi, если он настоящий, иначе свой')], ['unifi', T('Сертификат UniFi (как у веб-интерфейса роутера)')], ['self', T('Свой самоподписанный')]]
      .map(([v, t]) => el('option', { value: v, selected: r.cert_mode === v }, t)));
    const ci = r.cert || {};
    const certKv = el('dl', { class: 'kv' },
      el('dt', null, T('Используется')), el('dd', null, el('span', { class: 'badge ' + (r.cert_used === 'unifi' || r.cert_used === 'file' ? 'ok' : 'warn') }, { self: T('самоподписанный'), unifi: T('сертификат UniFi'), file: T('файл из web.conf') }[r.cert_used] || T('нет (HTTP)'))),
      el('dt', null, T('Имя')), el('dd', null, ci.subject || '—'),
      el('dt', null, T('Издатель')), el('dd', null, ci.issuer || '—'),
      el('dt', null, T('Действует до')), el('dd', null, ci.expires ? fmtTime(ci.expires, true) + (ci.expires - Date.now() / 1000 < 14 * 86400 ? ' ⚠' : '') : '—'),
      el('dt', null, T('Имена в сертификате')), el('dd', null, (ci.names || []).join(', ') || '—'));
    const found = r.unifi_certs.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Найден сертификат UniFi')), el('th', null, T('Издатель')), el('th', null, T('До')))),
      el('tbody', null, r.unifi_certs.map((c) => el('tr', null, el('td', null, el('b', null, c.subject || '?'), el('div', { class: 'small muted mono' }, c.path)), el('td', null, c.issuer || '—', c.self_signed ? el('span', { class: 'badge warn' }, T('самоподписанный')) : null), el('td', { class: 'nowrap' }, c.expires ? fmtTime(c.expires, true) : '—')))))
      : el('div', { class: 'small muted' }, T('Сертификатов UniFi не найдено в /data/unifi-core/config.'));
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить и перезапустить панель'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/web', { port: port.value.trim(), allow: allow.value.trim(), hosts: hosts.value.trim(), cert_mode: cm.value });
        ok(x.msg);
        setTimeout(() => { location.href = x.url; }, 5000);
      } catch (e) { err(e); }
    }));
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Доступ'), el('div', null,
          el('div', { class: 'field' }, el('label', null, T('Порт')), port, el('span', { class: 'hint' }, T('Сейчас панель на ') + r.lan + ':' + r.port + T('. Порты UniFi (443, 8443, 8080…) заняты.'))),
          el('div', { class: 'field' }, el('label', null, T('Разрешённые сети')), allow, el('span', { class: 'hint' }, T('Только частные сети через пробел. Для доступа извне используйте VPN-сервер роутера.'))),
          el('div', { class: 'field' }, el('label', null, T('Имена для входа (кроме IP)')), hosts, el('span', { class: 'hint' }, T('Имена из сертификата добавляются сами.')))), { icon: 'lock' }),
        card(T('Сертификат HTTPS'), el('div', null,
          el('div', { class: 'field' }, el('label', null, T('Источник')), cm, el('span', { class: 'hint' }, T('Сертификат UniFi обновляется роутером; панель перечитывает его сама в течение минуты, перезапуск не нужен.'))),
          r.cert_warn ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, r.cert_warn)) : null,
          certKv, el('div', { class: 'spacer' }), found), { icon: 'shield' })),
      el('div', { class: 'row end' }, save)]);
  }

  // 3x-ui (#30, #32): несколько панелей; туннель AmneziaWG 3.1 — создать, подключить к клиенту, привязать работающий
  const XUI_KIND = { created: 'создан роутером', imported: 'клиент из 3x-ui', linked: 'привязан' };
  function askNamePw(title, text, def) {   // имя нового туннеля + текущий пароль → {name, pw} или null
    return new Promise((res) => {
      let done = false;
      const nm = el('input', { class: 'input mono', value: def || 'awgxui', spellcheck: 'false' });
      const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = () => { done = true; m.close(); res({ name: nm.value.trim(), pw: pw.value }); };
      pw.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
      const m = modal(title, el('div', null, el('p', null, text),
        el('div', { class: 'field' }, el('label', null, T('Имя туннеля')), nm),
        el('div', { class: 'field' }, el('label', null, T('Пароль от этой веб-панели (тот же, что при входе)')), pw)), [
        el('button', { class: 'btn', onclick: () => { done = true; m.close(); res(null); } }, T('Отмена')),
        el('button', { class: 'btn primary', onclick: go }, T('Подключить')),
      ], { onclose: () => { if (!done) res(null); } });
    });
  }
  async function setXui(body) {
    let r;
    try { r = await api('/api/xui'); } catch (e) { err(e); return; }
    let sel = (r.panels.find((p) => p.id === S.xuiPanel) || r.panels[0] || {}).id || '';
    const rerender = () => { S.xuiPanel = sel; clear(body); setXui(body); };
    // ---- панели
    const pick = el('select', { class: 'input' }, r.panels.map((p) => el('option', { value: p.id, selected: p.id === sel }, (p.label || p.id) + ' — ' + p.url)));
    pick.addEventListener('change', () => { sel = pick.value; rerender(); });
    const cur = r.panels.find((p) => p.id === sel);
    const form = (p) => {
      p = p || { id: '', label: '', url: '', token_set: false, insecure: false, host: '', host_default: '' };
      const label = el('input', { class: 'input', value: p.label, placeholder: T('например, Финляндия'), maxlength: 40 });
      const url = el('input', { class: 'input mono', value: p.url, placeholder: 'https://vps.example.com:2053/secretpath', spellcheck: 'false' });
      const tok = el('input', { class: 'input mono', type: 'password', autocomplete: 'off', placeholder: p.token_set ? T('задан — оставьте пустым, чтобы не менять') : T('в 3x-ui: «Учетная запись → Токен API»') });
      const host = el('input', { class: 'input mono', value: p.host, placeholder: p.host_default || 'vps.example.com', spellcheck: 'false' });
      const insec = el('input', { type: 'checkbox', checked: p.insecure });
      const sw = el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, T('Без проверки сертификата')), el('span', null, T('Для самоподписанного сертификата панели 3x-ui.'))),
        el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, insec, el('span', { class: 'knob' }))));
      const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), p.id ? T('Сохранить') : T('Добавить панель'));
      save.addEventListener('click', () => busy(save, async () => {
        try {
          const x = await api('/api/xui', { id: p.id, label: label.value.trim(), url: url.value.trim(), token: tok.value.trim(), host: host.value.trim(), insecure: insec.checked });
          ok(x.msg); sel = x.id; rerender();
        } catch (e) { err(e); }
      }));
      return { save, node: el('div', null,
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Название')), label),
          el('div', { class: 'field' }, el('label', null, T('Адрес панели')), url, el('span', { class: 'hint' }, T('Как в браузере, вместе с секретным путём (webBasePath), без /panel'))),
          el('div', { class: 'field' }, el('label', null, T('API-токен')), tok),
          el('div', { class: 'field' }, el('label', null, T('Адрес сервера для туннеля')), host, el('span', { class: 'hint' }, T('Пусто — как в ссылках 3x-ui: узел или адрес панели')))),
        sw) };
    };
    const out = el('div', { class: 'res hidden' });
    const say = (t, good) => { out.textContent = t; out.classList.remove('hidden'); out.classList.toggle('bad', !good); };
    const pf = form(cur);
    const test = el('button', { class: 'btn', disabled: !cur }, icon('activity', 'sm'), T('Проверить подключение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/xui/test', { id: sel }); ok(T('3x-ui отвечает')); say(x.msg, true); } catch (e) { err(e); say(String(e.message || e), false); } }));
    const addP = el('button', { class: 'btn' }, icon('plus', 'sm'), T('Ещё панель'));
    addP.addEventListener('click', () => {
      const f = form(null);
      const m = modal(T('Новая панель 3x-ui'), f.node, [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), f.save]);
    });
    const delP = el('button', { class: 'btn danger', disabled: !cur }, T('Убрать панель'));
    delP.addEventListener('click', async () => {
      if (!await confirmBox(T('Убрать панель ') + (cur.label || cur.id) + '?', T('Роутер забудет адрес и токен этой панели. В самой 3x-ui ничего не изменится.'), T('Убрать'), true)) return;
      try { ok((await api('/api/xui/panel/remove', { id: sel })).msg); sel = ''; rerender(); } catch (e) { err(e); }
    });
    // ---- туннели через 3x-ui
    const tb = el('tbody');
    const paintTunnels = (list) => replace(tb, list.length ? list.map((t) => el('tr', null,
      el('td', null, el('b', { class: 'mono' }, t.name), el('div', { class: 'small muted' }, (t.panel_label || t.panel) + T(' · подключение №') + t.inbound + (t.email ? ' · ' + t.email : ''))),
      el('td', null, el('span', { class: 'badge' + (t.kind === 'linked' ? ' ok' : '') }, T(XUI_KIND[t.kind] || t.kind))),
      el('td', { class: 'r nowrap' },
        el('button', { class: 'btn sm', title: T('Перенести на роутер параметры подключения из 3x-ui (обфускацию, ключ сервера, порт); ключ роутера не меняется'), onclick: async (e) => {
          const pw = await promptPw(T('Обновить ') + t.name + T(' из 3x-ui?'), T('Если в 3x-ui поменяли параметры обфускации, ключ сервера или порт этого подключения — роутер возьмёт новые. Туннель перезапустится; не поднимется — вернётся прежний конфиг (он же в «Истории»).'));
          if (pw == null) return;
          await busy(e.currentTarget, async () => { try { const x = await api('/api/xui/sync', { name: t.name, current: pw }); (x.ok ? ok : err)(TM(x.msg)); } catch (ex) { err(ex); } });
        } }, T('Обновить из 3x-ui')), ' ',
        el('button', { class: 'btn sm danger', onclick: async () => {
          const txt = t.kind === 'linked' ? T('Роутер забудет связь туннеля с 3x-ui. Сам туннель и подключение в 3x-ui не меняются.')
            : t.kind === 'imported' ? T('Туннель уберётся из сторожа. Клиент в 3x-ui останется.')
              : T('Туннель уберётся из сторожа, подключение «UDR-Amnezia ') + t.name + T('» удалится в 3x-ui.');
          const pw = await promptPw((t.kind === 'linked' ? T('Отвязать ') : T('Убрать туннель ')) + t.name + '?', txt);
          if (pw == null) return;
          try { ok(TM((await api('/api/xui/remove', { name: t.name, current: pw, delete_inbound: true })).msg)); loadT(); loadIb(); } catch (e) { err(e); }
        } }, t.kind === 'linked' ? T('Отвязать') : T('Убрать'))))) : el('tr', null, el('td', { class: 'empty', colspan: 3 }, T('Туннелей через 3x-ui пока нет'))));
    const loadT = async () => { try { paintTunnels((await api('/api/xui')).tunnels); } catch (e) { err(e); } };
    paintTunnels(r.tunnels);
    // ---- подключения AmneziaWG выбранной панели
    const ibBox = el('div', { class: 'stack' }, el('div', { class: 'muted small' }, cur ? T('Загрузка…') : T('Сначала добавьте панель')));
    const loadIb = async () => {
      if (!cur) return;
      let x;
      try { x = await api('/api/xui/inbounds?panel=' + encodeURIComponent(sel)); } catch (e) { replace(ibBox, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, String(e.message || e)))); return; }
      if (!x.inbounds.length) { replace(ibBox, el('div', { class: 'muted small' }, T('В этой панели подключений AmneziaWG нет — создайте туннель ниже'))); return; }
      replace(ibBox, x.inbounds.map((ib) => {
        const linkBtn = ib.match && !ib.tunnels.includes(ib.match) ? el('button', { class: 'btn sm primary', onclick: async (e) => {
          await busy(e.currentTarget, async () => { try { ok(TM((await api('/api/xui/link', { panel: sel, inbound: ib.id, name: ib.match })).msg)); loadT(); loadIb(); } catch (ex) { err(ex); } });
        } }, T('Привязать ') + ib.match) : null;
        return el('div', { class: 'fgroup' },
          el('div', { class: 'row wrap' }, el('b', null, '№' + ib.id + ' «' + ib.remark + '»'), el('span', { class: 'mono small' }, (ib.host || '?') + ':' + ib.port),
            el('span', { class: 'badge ' + (ib.enable ? 'ok' : '') }, ib.enable ? T('вкл') : T('выкл')),
            ib.match ? el('span', { class: 'badge ok' }, T('туннель роутера ') + ib.match) : null,
            ib.tunnels.length ? el('span', { class: 'badge' }, T('связан: ') + ib.tunnels.join(', ')) : null, linkBtn),
          el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('tbody', null, ib.clients.map((c) => el('tr', null,
            el('td', null, el('span', { class: 'mono' }, c.email), c.comment ? el('div', { class: 'small muted' }, c.comment) : null),
            el('td', { class: 'mono small' }, c.address),
            el('td', { class: 'small muted nowrap' }, '↓ ' + fmtBytes(c.down) + ' ↑ ' + fmtBytes(c.up)),
            el('td', { class: 'r nowrap' }, c.router ? el('span', { class: 'badge ok' }, T('это роутер'))
              : c.has_key && c.enable ? el('button', { class: 'btn sm', onclick: async () => {
                if (!r.go_ok) { err(T('нужен amneziawg-go v3.x на роутере')); return; }
                const a = await askNamePw(T('Подключить клиента ') + c.email + '?', T('Роутер возьмёт из 3x-ui ключ этого клиента и параметры подключения и добавит дополнительный туннель. Если этим клиентом уже пользуется другое устройство, они будут мешать друг другу — лучше отдельный клиент.'), 'awgxui');
                if (!a) return;
                try { const y = await api('/api/xui/import', { panel: sel, inbound: ib.id, email: c.email, name: a.name, current: a.pw }); (y.ok ? ok : err)(TM(y.msg)); loadT(); loadIb(); } catch (ex) { err(ex); }
              } }, T('Подключить')) : el('span', { class: 'muted small' }, c.enable ? T('ключ не в 3x-ui') : T('выключен')))))))));
      }));
    };
    if (cur) loadIb();
    const reloadIb = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Обновить список'));
    reloadIb.addEventListener('click', () => busy(reloadIb, loadIb));
    // ---- новый туннель
    const name = el('input', { class: 'input mono', value: 'awgxui', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', inputmode: 'numeric', placeholder: T('свободный — выберется сам') });
    const mk = el('button', { class: 'btn primary', disabled: !r.go_ok || !cur }, icon('plus', 'sm'), T('Создать туннель'));
    mk.addEventListener('click', async () => {
      const pw = await promptPw(T('Создать туннель через 3x-ui?'), T('В 3x-ui появится подключение AmneziaWG 3.1 «UDR-Amnezia …» с одним клиентом — роутером (его закрытый ключ остаётся на роутере). Туннель добавится дополнительным; сторож будет использовать его по порядку приоритета.'));
      if (pw == null) return;
      await busy(mk, async () => {
        try { const x = await api('/api/xui/create', { panel: sel, name: name.value.trim(), port: port.value.trim(), current: pw }); (x.ok ? ok : err)(TM(x.msg)); say(TM(x.msg), x.ok); loadT(); loadIb(); } catch (e) { err(e); say(String(e.message || e), false); }
      });
    });
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Панели 3x-ui'), el('div', null,
          el('p', { class: 'muted small' }, T('3x-ui ≥ 3.8.5 умеет AmneziaWG 3.1. Нужен API-токен с областью admin: в 3x-ui «Учетная запись → Токен API». Токены хранятся на роутере (файл 600) и в браузер не возвращаются. Панелей может быть несколько.')),
          r.panels.length > 1 ? el('div', { class: 'field' }, el('label', null, T('Панель')), pick) : null,
          pf.node, out), { icon: 'server', foot: [test, pf.save, addP, cur ? delP : null] }),
        card(T('Новый туннель AmneziaWG 3.1'), el('div', null,
          r.go_ok ? null : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('На роутере amneziawg-go ') + (r.go || '?') + T(': для AmneziaWG 3.1 нужен v3.x. Обновите: «Система и обновление → Проверить AmneziaWG → Обновить на роутере».'))),
          el('p', { class: 'muted small' }, T('Роутер создаст в выбранной панели отдельное подключение со своим клиентом.')),
          el('div', { class: 'form-grid' },
            el('div', { class: 'field' }, el('label', null, T('Имя туннеля')), name),
            el('div', { class: 'field' }, el('label', null, T('Порт UDP в 3x-ui')), port, el('span', { class: 'hint' }, T('Откройте его в файрволе сервера'))))), { icon: 'tunnel', foot: mk })),
      card(T('Подключения AmneziaWG в панели'), el('div', null,
        el('p', { class: 'muted small' }, T('Туннель роутера, который уже ведёт на подключение (совпали ключ сервера и порт), можно привязать — тогда «Обновить из 3x-ui» переносит на роутер параметры, изменённые в 3x-ui. Клиента, ключ которого хранит 3x-ui, можно подключить новым туннелем.')),
        ibBox), { icon: 'globe', foot: reloadIb }),
      card(T('Туннели через 3x-ui'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb)), { icon: 'tunnel', flush: true })]);
  }
  // маршруты (#22): разные туннели для разных устройств и доменов — свой профиль PBR UniFi, своя цепочка туннелей
  function chainPicker(all, cur, lab) {   // цепочка туннелей по приоритету: нажать туннель — добавить в конец, нажать в цепочке — убрать
    const chain = (cur || []).slice();
    const box = el('div', { class: 'stack' });
    const paint = () => {
      replace(box,
        el('div', { class: 'row wrap' }, el('span', { class: 'small muted' }, T('Порядок:')), chain.length ? chain.map((t, i) => el('button', { class: 'btn sm primary', title: T('Убрать из цепочки'),
          onclick: () => { chain.splice(i, 1); paint(); } }, (i + 1) + '. ' + lab(t), icon('x', 'sm'))) : el('span', { class: 'small muted' }, T('выберите туннели ниже'))),
        el('div', { class: 'row wrap' }, el('span', { class: 'small muted' }, T('Добавить:')), all.filter((t) => !chain.includes(t)).map((t) => el('button', { class: 'btn sm',
          onclick: () => { chain.push(t); paint(); } }, icon('plus', 'sm'), lab(t)))));
    };
    paint();
    return { node: box, value: () => chain.slice() };
  }
  async function setRoutes(body) {
    let r;
    try { r = await api('/api/routes'); } catch (e) { err(e); return; }
    const lab = (t) => (r.labels && r.labels[t] ? r.labels[t] + ' (' + t + ')' : t);
    const reload = () => { clear(body); setRoutes(body); };
    const tb = el('tbody', null, r.routes.map((x) => {
      const main = x.id === 'main';
      const sw = main ? null : el('select', { class: 'input sm', onchange: async (e) => {
        try { ok(TM((await api('/api/route/switch', { id: x.id, tunnel: e.target.value })).msg)); setTimeout(reload, 2500); } catch (ex) { err(ex); }
      } }, el('option', { value: 'auto', selected: !x.forced }, T('Авто')), x.tunnels.map((t) => el('option', { value: t, selected: x.forced === t }, lab(t))));
      const edit = main ? null : el('button', { class: 'btn sm', onclick: () => {
        const cp = chainPicker(r.tunnels, x.tunnels, lab);
        const lb = el('input', { class: 'input', value: x.label || '', maxlength: 40 });
        const only = el('input', { type: 'checkbox', checked: x.only });
        const save = el('button', { class: 'btn primary' }, T('Сохранить'));
        const m = modal(T('Маршрут ') + x.id, el('div', { class: 'stack' },
          el('div', { class: 'field' }, el('label', null, T('Название')), lb),
          el('div', { class: 'field' }, el('label', null, T('Туннели по приоритету')), cp.node),
          el('label', { class: 'row' }, only, T('Эти туннели — только для этого маршрута (основной их не использует)'))), [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), save]);
        save.addEventListener('click', async () => {
          const pw = await promptPw(T('Сохранить маршрут ') + x.id + '?', T('Сторож маршрута перезапустится: трафик этого профиля на секунды уйдёт в blackhole (не в WAN).'));
          if (pw == null) return;
          try { ok(TM((await api('/api/route/save', { id: x.id, tunnels: cp.value(), label: lb.value.trim(), only: only.checked, current: pw })).msg)); m.close(); reload(); } catch (e) { err(e); }
        });
      } }, T('Изменить'));
      const del = main ? null : el('button', { class: 'btn sm danger', onclick: async () => {
        const pw = await promptPw(T('Убрать маршрут ') + x.id + '?', T('Трафик профиля ') + x.rail + T(' пойдёт как без набора — в сам профиль VPN Client UniFi. Туннели остаются.'));
        if (pw == null) return;
        try { ok(TM((await api('/api/route/remove', { id: x.id, current: pw })).msg)); reload(); } catch (e) { err(e); }
      } }, T('Убрать'));
      return el('tr', null,
        el('td', null, el('b', null, main ? T('Основной') : (x.label || x.id)), el('div', { class: 'small muted mono' }, (main ? '' : x.id + ' · ') + (x.rail || '?') + T(' · таблица ') + (x.table || '?'))),
        el('td', null, el('div', { class: 'row wrap' }, x.tunnels.map((t, i) => el('span', { class: 'badge' + (t === x.active ? ' ok' : '') }, (i + 1) + '. ' + lab(t))))),
        el('td', null, el('span', { class: 'badge ' + (x.service === 'active' ? 'ok' : 'crit') }, x.service === 'active' ? T('сторож работает') : T('сторож не запущен')),
          x.forced ? el('div', { class: 'small muted' }, T('выбран вручную: ') + x.forced) : null),
        el('td', { class: 'r nowrap' }, main ? el('a', { class: 'btn sm', href: '#/tunnels' }, T('Туннели')) : [sw, ' ', edit, ' ', del]));
    }));
    const free = r.rails.filter((x) => !x.used);
    const rail = el('select', { class: 'input' }, free.map((x) => el('option', { value: x.rail }, x.rail + T(' (таблица ') + x.table + ')')));
    const rid = el('input', { class: 'input mono', placeholder: 'us', maxlength: 12, spellcheck: 'false' });
    const lb = el('input', { class: 'input', placeholder: T('например, США для ТВ'), maxlength: 40 });
    const cp = chainPicker(r.tunnels, [], lab);
    const only = el('input', { type: 'checkbox' });
    const mk = el('button', { class: 'btn primary', disabled: !free.length }, icon('plus', 'sm'), T('Создать маршрут'));
    mk.addEventListener('click', async () => {
      if (!cp.value().length) { err(T('выберите туннели маршрута по порядку')); return; }
      const pw = await promptPw(T('Создать маршрут?'), T('Устройства и домены, которые в UniFi направлены на профиль ') + rail.value + T(', пойдут через выбранные туннели со своим сторожем и kill switch.'));
      if (pw == null) return;
      await busy(mk, async () => {
        try { ok(TM((await api('/api/route/save', { new: true, id: rid.value.trim(), rail: rail.value, tunnels: cp.value(), label: lb.value.trim(), only: only.checked, current: pw })).msg)); reload(); } catch (e) { err(e); }
      });
    });
    add(body, [
      el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Какие устройства и домены куда идут, задаётся в UniFi: Settings → Routing → Policy-Based Routes, правило на нужный профиль VPN Client. Здесь каждому профилю назначается своя цепочка туннелей AmneziaWG со своим переключением и kill switch. Профиль для нового маршрута — ещё один VPN Client в UniFi (как для основного) и хотя бы одно правило PBR на него.'))),
      card(T('Маршруты'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
        el('thead', null, el('tr', null, el('th', null, T('Маршрут')), el('th', null, T('Туннели (активный выделен)')), el('th', null, T('Состояние')), el('th', { class: 'r' }, ''))), tb)),
      { icon: 'layers', flush: true }),
      card(T('Новый маршрут'), el('div', { class: 'stack' },
        free.length ? null : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('Свободных профилей VPN Client с правилами PBR нет. Создайте в UniFi ещё один VPN Client и правило Policy-Based Route на него, затем обновите страницу.'))),
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Профиль VPN Client UniFi')), rail),
          el('div', { class: 'field' }, el('label', null, T('ID')), rid, el('span', { class: 'hint' }, T('латиница, до 12 знаков'))),
          el('div', { class: 'field' }, el('label', null, T('Название')), lb)),
        el('div', { class: 'field' }, el('label', null, T('Туннели по приоритету')), cp.node),
        el('label', { class: 'row' }, only, T('Эти туннели — только для этого маршрута (основной их не использует)'))), { icon: 'plus', foot: mk })]);
  }
  // автоподбор обфускации (#33): перебор наборов, проверка, оценка; «Применить» — только по кнопке
  function tuneCard() {
    const box = el('div', { class: 'stack' }, el('div', { class: 'muted small' }, T('Загрузка…')));
    let polling = false;
    const load = async () => {
      let r;
      try { r = await api('/api/tune'); } catch (e) { replace(box, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, String(e.message || e)))); return; }
      const lab = (t) => { const x = S.ov && S.ov.tunnels.find((y) => y.name === t.name); return (x && x.label ? x.label + ' (' + t.name + ')' : t.name) + (t.active ? T(' — активный') : ''); };
      const first = (r.tunnels.find((t) => !t.active) || {}).name;
      const sel = el('select', { class: 'input' }, r.tunnels.map((t) => el('option', { value: t.name, selected: t.name === first }, lab(t))));
      const mode = el('select', { class: 'input' });
      const cnt = el('input', { class: 'input mono', value: '5', inputmode: 'numeric' });
      const act = el('input', { type: 'checkbox' });
      const fillMode = () => {
        const t = r.tunnels.find((x) => x.name === sel.value) || {};
        replace(mode, el('option', { value: 'client' }, T('Только роутер (Jc, Jmin, Jmax) — любой туннель')),
          t.server ? el('option', { value: 'server', selected: true }, T('Роутер и свой VPS (Jc…H4) — согласованно')) : null);
      };
      sel.addEventListener('change', fillMode); fillMode();
      const log = el('div', { class: 'out' + (r.log ? '' : ' hidden') });
      if (r.log) paint(log, r.log);
      const go = el('button', { class: 'btn primary', disabled: r.running }, icon('activity', 'sm'), r.running ? T('Подбор идёт…') : T('Подобрать'));
      go.addEventListener('click', async () => {
        const pw = await promptPw(T('Подобрать параметры для ') + sel.value + '?', T('Туннель по очереди пробует наборы: на каждый — до полутора минут без связи по этому туннелю, замер скорости — 5 МБ трафика. В конце возвращается исходный набор. Лучший ставится только по кнопке «Применить».'));
        if (pw == null) return;
        try { ok(TM((await api('/api/tune/run', { tunnel: sel.value, mode: mode.value, count: cnt.value.trim(), active: act.checked, current: pw })).msg)); follow(); } catch (e) { err(e); }
      });
      const rows = r.rows.map((x) => el('tr', { class: x.n === r.best ? 'hl' : '' },
        el('td', { class: 'mono' }, x.n === 0 ? T('сейчас') : '№' + x.n),
        el('td', null, x.ok ? el('span', { class: 'badge ok' }, T('работает')) : el('span', { class: 'badge crit' }, T('нет связи'))),
        el('td', { class: 'mono small' }, x.ok ? x.loss + '% · ' + x.rtt + T(' мс · ') + x.mbps + T(' Мбит/с') : '—'),
        el('td', null, el('b', null, String(x.score)), x.n === r.best ? el('span', { class: 'badge ok' }, T('лучший')) : null),
        el('td', { class: 'mono small' }, x.params),
        el('td', { class: 'r' }, x.ok && x.n !== 0 ? el('button', { class: 'btn sm' + (x.n === r.best ? ' primary' : ''), disabled: r.running, onclick: async () => {
          const pw = await promptPw(T('Поставить набор №') + x.n + T(' на ') + r.head.tunnel + '?', r.head.mode === 'server' ? T('Параметры поменяются на VPS и роутере одновременно; не заработает — обе стороны вернутся.') : T('Меняется только конфиг роутера (прежний — в «Истории» туннеля).'));
          if (pw == null) return;
          try { const y = await api('/api/tune/apply', { n: x.n, current: pw }); (y.ok ? ok : err)(TM(y.msg)); if (y.job) follow(); else load(); } catch (e) { err(e); }
        } }, T('Применить')) : null)));
      replace(box,
        el('p', { class: 'muted small' }, T('Если провайдер начал узнавать или замедлять AmneziaWG: роутер перебирает наборы параметров обфускации, проверяет каждый (handshake, интернет, потери, задержка, скорость) и ставит оценку. «Только роутер» меняет параметры мусорных пакетов, которые сервер не сверяет, — подходит и для туннеля провайдера, и для 3x-ui. «Роутер и свой VPS» меняет и S1, S2, H1–H4 на вашем сервере.')),
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Туннель')), sel),
          el('div', { class: 'field' }, el('label', null, T('Что менять')), mode),
          el('div', { class: 'field' }, el('label', null, T('Новых наборов')), cnt, el('span', { class: 'hint' }, T('1–12; первым меряется текущий')))),
        el('label', { class: 'row' }, act, T('Разрешить на активном канале (трафик устройств на время подбора пойдёт с перерывами)')),
        el('div', { class: 'row' }, go),
        r.rows.length ? el('div', null, el('div', { class: 'small muted' }, T('Последний подбор: ') + r.head.tunnel + ' · ' + (r.head.mode === 'server' ? T('роутер и VPS') : T('только роутер')) + ' · ' + fmtTime(r.head.ts, true)),
          el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Набор')), el('th', null, T('Связь')),
            el('th', null, T('Потери · задержка · скорость')), el('th', null, T('Оценка')), el('th', null, T('Параметры')), el('th', null, ''))), el('tbody', null, rows)))) : null,
        log);
      if (r.running && !polling) follow();
    };
    async function follow() {
      if (polling) return;
      polling = true;
      for (let i = 0; i < 600; i++) {
        await new Promise((ok2) => setTimeout(ok2, 3000));
        let x;
        try { x = await api('/api/tune'); } catch (e) { continue; }
        if (!x.running) break;
        const lg = box.querySelector('.out');
        if (lg) { lg.classList.remove('hidden'); paint(lg, x.log); lg.scrollTop = lg.scrollHeight; }
      }
      polling = false;
      load();
    }
    load();
    return card(T('Подбор параметров обфускации'), box, { icon: 'shield' });
  }
  // списки и GeoIP (#38): состояние наборов и кнопка «Обновить списки» над формой настроек
  function listsStatus() {
    const box = el('div', { class: 'stack' });
    let polling = false;
    const load = async () => {
      let r;
      try { r = await api('/api/lists'); } catch (e) { replace(box, el('div', { class: 'muted small' }, String(e.message || e))); return; }
      const st = r.status || {}, sets = st.sets || {};
      if (st.mode === 'off' || !st.mode) { replace(box, el('p', { class: 'muted small' }, T('Сейчас выключено: устройства под PBR идут через туннель целиком. Выберите режим и нажмите «Применить» — списки скачаются сами.'))); return; }
      const k = st.mode === 'geoip' ? 'geo' : 'blocked', x = sets[k] || {};
      const what = st.mode === 'geoip' ? T('Адресов стран ') + (st.countries || '').toUpperCase().trim() + ': ' : T('Сетей в списке заблокированного: ');
      const badge = !r.guard ? el('span', { class: 'badge crit' }, T('служба awg-guard не запущена'))
        : x.set > 0 ? el('span', { class: 'badge ok' }, T('работает'))
          : el('span', { class: 'badge warn' }, T('набор пуст — пока всё идёт через туннель'));
      const go = el('button', { class: 'btn sm', disabled: r.running }, icon('refresh', 'sm'), r.running ? T('Обновляется…') : T('Обновить списки'));
      go.addEventListener('click', () => busy(go, async () => {
        try { ok(TM((await api('/api/lists/update', {})).msg)); follow(); } catch (e) { err(e); }
      }));
      const log = el('div', { class: 'out' + (r.log && r.running ? '' : ' hidden') });
      if (r.log) paint(log, r.log);
      const showLog = el('button', { class: 'btn sm ghost' + (r.log ? '' : ' hidden') }, T('Журнал'));
      showLog.addEventListener('click', () => log.classList.toggle('hidden'));
      replace(box,
        el('div', { class: 'row' }, badge, el('span', { class: 'small' }, what, el('b', null, String(x.set || 0))),
          el('span', { class: 'small muted' }, T('обновлено: ') + (x.age >= 0 ? fmtAge(x.age) : T('никогда'))),
          x.stale && x.age >= 0 ? el('span', { class: 'badge warn' }, T('собрано для прежних настроек')) : null, go, showLog),
        log);
      if (r.running && !polling) follow();
    };
    async function follow() {
      if (polling) return;
      polling = true;
      for (let i = 0; i < 100; i++) {
        await new Promise((ok2) => setTimeout(ok2, 3000));
        let x;
        try { x = await api('/api/lists'); } catch (e) { continue; }
        const lg = box.querySelector('.out');
        if (lg) { lg.classList.remove('hidden'); paint(lg, x.log); }
        if (!x.running) break;
      }
      polling = false;
      load();
    }
    load();
    return box;
  }
  // ===================================================================== QR-код (байтовый режим, уровень M, версии 1–10)
  function qrMatrix(text) {
    const data = Array.from(new TextEncoder().encode(text));
    const ECC = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26], BLK = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
    const rawMods = (v) => { let r = (16 * v + 128) * v + 64; if (v >= 2) { const n = Math.floor(v / 7) + 2; r -= (25 * n - 10) * n - 55; if (v >= 7) r -= 36; } return r; };
    let ver = 1, cap = 0;
    for (; ver <= 10; ver++) { cap = Math.floor(rawMods(ver) / 8) - ECC[ver] * BLK[ver]; if (4 + (ver < 10 ? 8 : 16) + data.length * 8 <= cap * 8) break; }
    if (ver > 10) throw new Error(T('слишком длинно для QR'));
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
    return sv('svg', { class: 'qr', viewBox: '0 0 ' + (N + 2 * q) + ' ' + (N + 2 * q), 'shape-rendering': 'crispEdges', role: 'img', 'aria-label': T('QR-код для приложения') },
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
      if (r.ok) { S.csrf = j.csrf; S.user = j.user; S.version = j.version; checkVersion(j.version); start(); } else showLogin(j.setup);
    } catch (e) {
      replace($('#app'), el('div', { class: 'login-wrap' }, el('div', { class: 'login' }, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, T('Панель не отвечает: ') + e.message)))));
    }
  }());
}());
