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
      const m = modal(title, el('div', null, text ? el('p', null, text) : null, el('div', { class: 'field' }, el('label', null, T('Текущий пароль')), inp)), [
        el('button', { class: 'btn', onclick: () => { done = true; m.close(); res(null); } }, T('Отмена')),
        el('button', { class: 'btn primary', onclick: go }, T('Подтвердить')),
      ], { onclose: () => { if (!done) res(null); } });
    });
  }
